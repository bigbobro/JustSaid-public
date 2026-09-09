#!/usr/bin/env python3
"""Verify and materialize JustSaid's sanitized public candidate.

The default command scans one candidate directory.  The ``--export`` mode is
used by ``export-public-repo.sh`` and deliberately has a small, explicit
allowlist.  It never follows symlinks, reads ignored files, pushes, or edits
the canonical checkout.

All findings are redacted: callers get a path, line, stable code, and a short
digest, never the matched value.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Sequence


MANIFEST_NAME = "PUBLIC_EXPORT_MANIFEST.json"
POLICY_PATH = "docs/publication/PUBLIC_SCOPE.md"
PUBLIC_PACKAGE_TEMPLATE = "docs/publication/Package.public.swift"

# These are intentionally explicit.  A newly added top-level directory is not
# public by default and therefore cannot silently enter a candidate.
PUBLIC_FILES = (
    ".gitattributes",
    ".gitignore",
    "Package.resolved",
    "LICENSE",
    POLICY_PATH,
    PUBLIC_PACKAGE_TEMPLATE,
    "docs/publication/README.public.md",
    "docs/publication/CHANGELOG.public.md",
    "Scripts/export-public-repo.sh",
    "Scripts/verify-public-tree.py",
    "Scripts/verify-ci-cost-policy.py",
    "Scripts/verify-concurrency-policy.py",
    ".github/workflows/pr-validation.yml",
    ".github/workflows/public-policy.yml",
    ".github/workflows/public-runner-smoke.yml",
    "Support/LocalModelAssets.json",
    "Support/ThirdPartyNotices.txt",
    "Support/ThirdPartyLicenses/FunASR-MODEL-LICENSE.txt",
    "Support/ThirdPartyLicenses/Qwen3-ASR-MODEL-LICENSE.txt",
    "Support/ThirdPartyLicenses/Silero-VAD-LICENSE.txt",
)

PUBLIC_TEMPLATE_MAP = {
    PUBLIC_PACKAGE_TEMPLATE: "Package.swift",
    "docs/publication/README.public.md": "README.md",
    "docs/publication/CHANGELOG.public.md": "CHANGELOG.md",
}

# The canonical private tree still stores model-license inputs with internal
# distribution material.  The first export rewrites only those reviewed
# license files into public Support paths.  Subsequent exports use the public
# paths directly, making the candidate self-contained without publishing the
# rest of Distribution/.
PUBLIC_SOURCE_ALIASES = {
    "Support/ThirdPartyLicenses/FunASR-MODEL-LICENSE.txt":
        "Distribution/InternalBeta/LICENSES/FunASR-MODEL-LICENSE.txt",
    "Support/ThirdPartyLicenses/Qwen3-ASR-MODEL-LICENSE.txt":
        "Distribution/InternalBeta/LICENSES/Qwen3-ASR-MODEL-LICENSE.txt",
    "Support/ThirdPartyLicenses/Silero-VAD-LICENSE.txt":
        "Distribution/InternalBeta/LICENSES/Silero-VAD-LICENSE.txt",
}

# Verification targets are test fixtures, not publication surface.  No
# verification directory is exported and no verification target may appear in
# the public Package template.
VERIFICATION_ROOT = "Verification"

SOURCE_MODE_PRIVATE_CANONICAL = "private_canonical"
SOURCE_MODE_SANITIZED_PUBLIC = "sanitized_public"

# Every PackageDescription spelling that declares a target.  A target form
# missing from this tuple would be invisible to both the Verification/ filter
# and the parity comparison, so the tuple -- not the two forms the manifest
# happens to use today -- is what makes the published claim checkable.  The
# same spellings occur nested as references (``.target(name:)`` in a
# ``dependencies:`` list, ``.plugin(name:package:)`` in ``plugins:``);
# _manifest_targets() skips anything inside a declaration it already parsed.
TARGET_DECLARATION_KINDS = (
    "target",
    "executableTarget",
    "testTarget",
    "binaryTarget",
    "systemLibrary",
    "macro",
    "plugin",
)

PUBLIC_PREFIXES = ("Sources",)

PRIVATE_PATH_PREFIXES = (
    "research/",
    "example/",
    ".trellis/",
    "Distribution/",
    ".github/task-artifacts/",
    ".github/task1-trigger",
    ".github/workflows/uihierarchy-",
    VERIFICATION_ROOT + "/",
)

SENSITIVE_SUFFIXES = (
    ".pem",
    ".key",
    ".p12",
    ".mobileprovision",
    ".cer",
    ".crt",
    ".dmg",
    ".app",
    ".xcarchive",
    ".xcresult",
    ".diag",
    ".log",
    ".trace",
    ".sqlite",
    ".sqlite3",
    ".db",
    ".zip",
    ".tar",
    ".gz",
)

SYNTHETIC_VALUES = {
    "api_key_sentinel",
    "api-key-sentinel",
    "stub-token",
    "stub_token",
    "test-token",
    "test_token",
    "redacted",
    "<redacted>",
    "placeholder",
    "changeme",
}


def _regex_fragments() -> tuple[re.Pattern[str], ...]:
    # Construct a few marker strings from fragments so this verifier does not
    # trip over its own source when it scans the exported candidate.
    auth_marker = "auth" + "code="
    private_header = "-" * 5 + "BEGIN "
    private_header_end = " PRIVATE KEY" + "-" * 5
    return (
        re.compile(
            r"(?i)(?:https?://[^\s\"'<>]*feishu[^\s\"'<>]*[?&]"
            + re.escape(auth_marker)
            + r"[^\s\"'<>]+|[?&]"
            + re.escape(auth_marker)
            + r"[^\s\"'<>]+)"
        ),
        re.compile(
            re.escape(private_header) + r"[A-Z0-9 ]+" + re.escape(private_header_end)
        ),
    )


AUTHCODE_RE, PRIVATE_KEY_RE = _regex_fragments()
MACHINE_PATH_RE = re.compile(r"/(?:Users|home)/[^/\s]+(?:/|$)")


def _provenance_fragments() -> tuple[re.Pattern[str], ...]:
    """Content rules for real user data that was copied into the tree.

    Every literal is assembled from fragments for the same reason the
    credential markers above are: this file is itself exported and scanned,
    and a rule that matches its own definition would make the gate unusable.

    The rules key on *shape* and on *co-occurrence*, never on a bare
    vocabulary word.  An audit of the tree found ordinary engineering
    annotations that must keep passing: 6 uses of the "verified on real
    hardware" note and 3 of the "real meeting" note live in Sources/ as
    behavioural commentary, and a "real drift" note describes an observed
    behaviour.  None of them asserts that data was copied in, so none of them
    is a marker on its own; the drift note is caught anyway, because the line
    that carries it also carries a concrete session-directory name.

      copy_verb        - a verb that only makes sense about content lifted out
                         of somewhere else.  Chinese and English forms both.
                         The English ones are all multi-word on purpose: the
                         export surface uses their component words in ordinary
                         prose (a model prompt asking for an exact quotation, a
                         "copy" of a value, a round-trip asserted byte for
                         byte), so a single word would flag all of it.  English
                         matching is case-insensitive; a whole phrase must
                         still be present.
      real_stock       - a claim that the content came out of the running
                         product's own records rather than being authored as a
                         fixture.  Chinese and English forms both.
      subject          - what the copy is *of*; a verb alone is not evidence.
      artifact         - the meeting record filenames this product writes.
      session_slug     - one session directory's name: date + subject + index.
                         A shape, not a word, so it stands on its own.
      user_data_entry  - a concrete entry inside the home-relative store this
                         product writes into.  The store's own top-level names
                         are documented product facts and do not match; only
                         paths that reach *inside* one of its directories do.
    """
    subject_word = "\u4f1a" + "\u8bae"
    copy_verb = (
        "\u539f\u6837" + "\u62f7\u8d1d",
        "\u62f7\u8d1d" + "\u81ea",
        "\u590d\u5236" + "\u81ea",
    )
    # English equivalents of the same admission.  Each one needs either the
    # preposition that names where the content came from or the adverb that
    # says the copy was exact, so a bare component word stays green.
    copy_verb_english = (
        "cop" + r"ied\s+verbatim",
        r"verbatim\s+cop" + r"y\s+of",
        "cop" + r"ied\s+(?:straight\s+)?(?:from|out\s+of)",
        "past" + r"ed\s+(?:straight\s+)?(?:from|out\s+of)",
        "lift" + r"ed\s+(?:straight\s+)?(?:from|out\s+of)",
        # Only when it is attached to a copy noun: an assertion that a
        # round-trip is byte for byte is a test, not a provenance note.
        r"byte[\s-]for[\s-]byte\s+(?:cop(?:y|ies|ied)|dup(?:licate|e))",
    )
    real_stock = "\u771f\u5b9e" + "\u5b58\u91cf"
    # English equivalents.  Same shape as the Chinese one: an origin claim, not
    # a vocabulary word.  "real" or "live" on its own never matches - the
    # qualifier has to be attached to one of the nouns that names a body of
    # recorded product data.
    real_stock_english = (
        r"(?:taken|pulled|grabbed|exported|read)\s+(?:straight\s+)?"
        r"(?:from|out\s+of)\s+(?:the\s+|a\s+|an\s+|my\s+|our\s+)?"
        r"(?:live|real|actual|production|on-disk)",
        r"(?:live|real|actual|production|on-disk)[\s-](?:store|stock|corpus)",
        r"(?:real|actual|live|production)\s+(?:user\s+)?"
        r"(?:data|history|meetings?|recordings?|sessions?|transcripts?)\b",
        r"user'?s?\s+(?:own\s+)?(?:meetings?|recordings?|transcripts?)\b",
    )
    artifact = (
        "minutes" + r"\.json",
        "transcript-live" + r"\.jsonl",
        "meeting" + r"\.json",
    )
    subject = (subject_word, "meeting", "transcript", *artifact)
    data_root = "~/" + "JustSaid"
    # A path segment stops at whitespace and at the quoting or prose
    # punctuation that surrounds a path in a comment; without that the CJK
    # sentence following a directory reference would be swallowed as a name.
    segment = r"[^\s/`\"'<>()\[\]{},;:\u2014\u3002\uff0c\u3001\uff1b\uff1a\uff08\uff09\u300c\u300d\u300e\u300f\u300a\u300b\uff1f\uff01\u2026\u00b7]+"
    # The English alternatives are patterns, not literals, so they are joined
    # unescaped.  Case-insensitive: an English provenance note is as likely to
    # start a sentence as to sit mid-line.  The subject side is folded too, so
    # a capitalised subject still answers "copied *what*".
    return (
        re.compile(
            "(?i)"
            + "|".join((*(re.escape(verb) for verb in copy_verb), *copy_verb_english))
        ),
        re.compile("(?i)" + "|".join(subject)),
        re.compile(
            "(?i)" + "|".join((re.escape(real_stock), *real_stock_english))
        ),
        re.compile("|".join(artifact)),
        re.compile(r"\d{4}-\d{2}-\d{2}-" + subject_word + r"-\d+"),
        re.compile(re.escape(data_root) + "/" + segment + "/" + segment),
    )


(
    COPY_VERB_RE,
    COPY_SUBJECT_RE,
    REAL_STOCK_RE,
    DATA_ARTIFACT_RE,
    SESSION_SLUG_RE,
    USER_DATA_ENTRY_RE,
) = _provenance_fragments()

EMAIL_RE = re.compile(
    r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"
)
PRIVATE_HOST_RE = re.compile(
    r"(?i)\b(?:[a-z0-9-]+\.(?:corp|internal|intranet|lan|local)|"
    r"10\.(?:\d{1,3}\.){2}\d{1,3}|"
    r"192\.168\.(?:\d{1,3}\.)?\d{1,3}|"
    r"172\.(?:1[6-9]|2\d|3[0-1])\.(?:\d{1,3}\.)\d{1,3})\b"
)

KEY_FORMAT_RES = (
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
)

# Require a quoted value (or a long token without punctuation) to avoid
# treating ordinary source expressions such as ``secretKey: configuration``
# as credentials.
ASSIGNMENT_RE = re.compile(
    r"(?i)\b(?:api[_-]?key|client[_-]?secret|access[_-]?token|"
    r"refresh[_-]?token|webhook[_-]?secret|password|secret[_-]?key|"
    r"bearer)\b\s*(?:=|:)\s*(?:"
    r'"(?P<double>[^"\r\n]{12,})"'
    r"|'(?P<single>[^'\r\n]{12,})'"
    r"|(?P<bare>[A-Za-z0-9_+/=-]{20,}))"
)


def _run_git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout


def _is_git_work_tree(repo: Path) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--is-inside-work-tree"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0 and result.stdout.strip() == "true"


def _tracked_paths(repo: Path) -> set[str]:
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z"],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return {
        item.decode("utf-8", errors="surrogateescape")
        for item in result.stdout.split(b"\0")
        if item
    }


def _is_dirty(repo: Path) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain=v1", "--untracked-files=all"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git status failed")
    return bool(result.stdout)


def _policy_revision(repo: Path) -> str:
    text = (repo / POLICY_PATH).read_text(encoding="utf-8")
    match = re.search(r"(?m)^> Policy revision:\s*(\S+)\s*$", text)
    if not match:
        raise RuntimeError(f"{POLICY_PATH} is missing a Policy revision")
    return match.group(1)


def _swift_signature(text: str) -> dict[str, object]:
    name_match = re.search(r"\bname:\s*\"([^\"]+)\"", text)
    if not name_match:
        raise RuntimeError("Package manifest has no package name")
    dependencies = sorted(
        (url, revision)
        for url, revision in re.findall(
            r"\.package\(\s*url:\s*\"([^\"]+)\"\s*,\s*revision:\s*\"([^\"]+)\"",
            text,
            flags=re.DOTALL,
        )
    )
    mode_match = re.search(
        r"swiftLanguageModes:\s*\[\s*\.([A-Za-z0-9]+)\s*\]", text
    )
    if not mode_match:
        raise RuntimeError("Package manifest has no explicit Swift language mode")
    products = sorted(
        (product, targets)
        for product, targets in re.findall(
            r"\.executable\(name:\s*\"([^\"]+)\"\s*,\s*targets:\s*\[([^\]]*)\]",
            text,
        )
    )
    return {
        "name": name_match.group(1),
        "dependencies": dependencies,
        "swift_language_mode": mode_match.group(1),
        "products": products,
    }


@dataclass(frozen=True)
class ManifestTarget:
    """One parsed ``.target``/``.executableTarget`` declaration.

    ``arguments`` holds every remaining labelled argument of the declaration
    -- ``dependencies``, ``linkerSettings``, ``swiftSettings``, ``cSettings``,
    ``resources``, ``exclude``, ``plugins`` and anything a future manifest
    adds -- normalised and sorted by label.  Comparing it is what makes the
    published parity claim ("the canonical graph minus Verification targets")
    enforceable rather than aspirational.
    """

    kind: str
    name: str
    path: str | None
    arguments: tuple[tuple[str, str], ...]

    def declaration_digest(self) -> str:
        payload = json.dumps(
            [self.kind, self.path, [list(pair) for pair in self.arguments]],
            ensure_ascii=False,
            sort_keys=True,
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def _normalised_call_arguments(body: str) -> tuple[str, ...]:
    """Split a Swift call body into top-level arguments, normalised.

    Outside string literals every whitespace run collapses to a single space,
    spaces adjacent to a bracket, a comma or an argument-label colon are
    dropped, and a comma directly before a closing bracket is dropped -- so
    reformatting the manifest cannot change the comparison, while any semantic
    edit still can.  Whitespace inside a literal is preserved verbatim.
    """
    arguments: list[str] = []
    current: list[str] = []
    depth = 0
    index = 0
    in_string = False
    escaped = False
    length = len(body)

    def drop_pending_space() -> None:
        if current and current[-1] == " ":
            current.pop()

    while index < length:
        character = body[index]
        if in_string:
            current.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
            current.append(character)
            index += 1
            continue
        if character.isspace():
            if current and current[-1] not in (" ", "[", "(", ":"):
                current.append(" ")
            index += 1
            continue
        if character == ",":
            following = index + 1
            while following < length and body[following].isspace():
                following += 1
            drop_pending_space()
            if following < length and body[following] in "])":
                index += 1
                continue
            if depth == 0:
                arguments.append("".join(current).strip())
                current = []
                index += 1
                continue
            current.append(",")
            current.append(" ")
            index += 1
            continue
        if character in "([":
            drop_pending_space()
            depth += 1
        elif character in ")]":
            drop_pending_space()
            depth -= 1
        elif character == ":":
            # An argument label's colon, at any nesting depth: spacing around
            # it is formatting, not meaning.
            drop_pending_space()
        current.append(character)
        index += 1
    if in_string:
        raise RuntimeError("unterminated string in Package target declaration")
    tail = "".join(current).strip()
    if tail:
        arguments.append(tail)
    return tuple(argument for argument in arguments if argument)


def _string_literal(value: str) -> str:
    match = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', value)
    if match is None:
        raise RuntimeError("Package target argument is not a plain string literal")
    return match.group(1)


def _manifest_targets(text: str) -> dict[str, ManifestTarget]:
    targets: dict[str, ManifestTarget] = {}
    start_pattern = re.compile(
        r"\.(" + "|".join(TARGET_DECLARATION_KINDS) + r")\s*\("
    )
    consumed_until = 0
    for start_match in start_pattern.finditer(text):
        if start_match.start() < consumed_until:
            # Inside a declaration already parsed, these spellings are
            # references rather than declarations: `.target(name:)` in a
            # `dependencies:` list, `.plugin(name:package:)` in `plugins:`.
            continue
        kind = start_match.group(1)
        open_paren = text.find("(", start_match.start())
        depth = 0
        in_string = False
        escaped = False
        end = None
        for index in range(open_paren, len(text)):
            character = text[index]
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
                continue
            if character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        if end is None:
            raise RuntimeError("unbalanced target declaration in Package manifest")
        consumed_until = end
        labelled: dict[str, str] = {}
        for argument in _normalised_call_arguments(text[open_paren + 1:end - 1]):
            label, separator, value = argument.partition(":")
            label = label.strip()
            if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", label):
                raise RuntimeError(
                    "Package target declaration has an unlabelled argument"
                )
            if label in labelled:
                raise RuntimeError(
                    f"duplicate argument in Package target declaration: {label}"
                )
            labelled[label] = value.strip()
        if "name" not in labelled:
            raise RuntimeError("Package target declaration has no name")
        name = _string_literal(labelled["name"])
        path = _string_literal(labelled["path"]) if "path" in labelled else None
        if name in targets:
            raise RuntimeError(f"duplicate Package target: {name}")
        targets[name] = ManifestTarget(
            kind=kind,
            name=name,
            path=path,
            arguments=tuple(
                sorted(
                    (label, value)
                    for label, value in labelled.items()
                    if label not in ("name", "path")
                )
            ),
        )
    return targets


def _verification_target_names(targets: dict[str, ManifestTarget]) -> set[str]:
    """Targets whose sources live under the unpublished verification tree."""
    return {
        name
        for name, target in targets.items()
        if target.path is not None
        and (
            target.path == VERIFICATION_ROOT
            or target.path.startswith(VERIFICATION_ROOT + "/")
        )
    }


def _classify_manifest_source_mode(
    canonical_targets: dict[str, ManifestTarget],
    public_targets: dict[str, ManifestTarget],
) -> str:
    """Detect PRIVATE_CANONICAL vs SANITIZED_PUBLIC; fail closed otherwise.

    The discriminator is structural rather than a hand-maintained target-name
    list: the public template must be exactly the canonical target graph with
    every ``Verification/``-pathed target removed.  A template that still
    declares one is rejected, because the exported tree has no such sources.
    Every surviving target is then compared whole -- kind, path and every
    other labelled argument of its declaration -- so a dropped dependency or
    an edited linker setting is a rejection, not a silent divergence.
    """
    if _verification_target_names(public_targets):
        raise RuntimeError("public Package template declares a verification target")
    verification_targets = _verification_target_names(canonical_targets)
    expected_public_targets = {
        name: target
        for name, target in canonical_targets.items()
        if name not in verification_targets
    }
    if {name: target.path for name, target in public_targets.items()} != {
        name: target.path for name, target in expected_public_targets.items()
    }:
        raise RuntimeError("public Package target name/path parity mismatch")
    for name in sorted(expected_public_targets):
        canonical_target = expected_public_targets[name]
        public_target = public_targets[name]
        if canonical_target.kind != public_target.kind:
            raise RuntimeError(
                f"public Package target declaration mismatch in {name}: kind"
            )
        canonical_arguments = dict(canonical_target.arguments)
        public_arguments = dict(public_target.arguments)
        differing = sorted(
            label
            for label in set(canonical_arguments) | set(public_arguments)
            if canonical_arguments.get(label) != public_arguments.get(label)
        )
        if differing:
            raise RuntimeError(
                "public Package target declaration mismatch in "
                f"{name}: {', '.join(differing)}"
            )
    return (
        SOURCE_MODE_PRIVATE_CANONICAL
        if verification_targets
        else SOURCE_MODE_SANITIZED_PUBLIC
    )


def _validate_manifest_template(
    repo: Path,
) -> tuple[str, dict[str, object], dict[str, object]]:
    canonical_path = repo / "Package.swift"
    template_path = repo / PUBLIC_PACKAGE_TEMPLATE
    if not canonical_path.is_file() or not template_path.is_file():
        raise RuntimeError("canonical Package.swift or public manifest template is missing")
    canonical = _swift_signature(canonical_path.read_text(encoding="utf-8"))
    public = _swift_signature(template_path.read_text(encoding="utf-8"))
    for key in ("name", "dependencies", "swift_language_mode", "products"):
        if canonical[key] != public[key]:
            raise RuntimeError(f"public Package.swift parity mismatch in {key}")
    if public["name"] != "JustSaid":
        raise RuntimeError("public manifest package name is not JustSaid")
    canonical_targets = _manifest_targets(canonical_path.read_text(encoding="utf-8"))
    public_targets = _manifest_targets(template_path.read_text(encoding="utf-8"))
    source_mode = _classify_manifest_source_mode(canonical_targets, public_targets)
    canonical["canonical_target_count"] = len(canonical_targets)
    canonical["expected_public_target_count"] = len(public_targets)
    canonical["source_mode"] = source_mode
    public["source_mode"] = source_mode
    public["targets"] = [
        {
            "name": name,
            "path": target.path,
            "kind": target.kind,
            # Digest of everything else the parity check compares: the
            # declaration's remaining labelled arguments, normalised.
            "declaration_digest": target.declaration_digest(),
        }
        for name, target in sorted(public_targets.items())
    ]
    return source_mode, canonical, public


def _safe_source_file(source: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise RuntimeError(f"allowlisted source is not a regular file: {source}")


def _resolve_source(repo: Path, public_relative: str) -> str:
    direct = repo / public_relative
    if direct.is_file() and not direct.is_symlink():
        return public_relative
    alias = PUBLIC_SOURCE_ALIASES.get(public_relative)
    if alias is not None:
        alias_path = repo / alias
        if alias_path.is_file() and not alias_path.is_symlink():
            return alias
    raise RuntimeError(f"allowlisted source is missing: {public_relative}")


def _filesystem_public_paths(repo: Path) -> set[str]:
    paths: set[str] = set()
    for prefix in PUBLIC_PREFIXES:
        root = repo / prefix
        if not root.exists():
            continue
        if root.is_symlink() or not root.is_dir():
            raise RuntimeError(f"public prefix is not a regular directory: {prefix}")
        for path in root.rglob("*"):
            if path.is_symlink():
                raise RuntimeError(f"symlink inside public prefix: {prefix}")
            if path.is_file():
                paths.add(path.relative_to(repo).as_posix())
    return paths


def _filesystem_source_identity(
    repo: Path, selected: Sequence[tuple[str, str]]
) -> str:
    digest = hashlib.sha256()
    for source_relative, destination_relative in sorted(selected):
        digest.update(destination_relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256((repo / source_relative).read_bytes()).digest())
    return "filesystem-" + digest.hexdigest()


def _selected_source_paths(repo: Path, tracked: set[str], require_clean: bool) -> list[tuple[str, str]]:
    """Return (source-relative, candidate-relative) paths in stable order."""
    selected: set[tuple[str, str]] = set()

    def add_source(public_relative: str, destination: str | None = None) -> None:
        source_relative = _resolve_source(repo, public_relative)
        source = repo / source_relative
        _safe_source_file(source)
        if require_clean and source_relative not in tracked:
            raise RuntimeError(f"allowlisted file is not tracked: {source_relative}")
        selected.add((source_relative, destination or public_relative))

    for relative in PUBLIC_FILES:
        add_source(relative)
    for source_relative, destination in PUBLIC_TEMPLATE_MAP.items():
        add_source(source_relative, destination)

    # Directory entries are selected from `git ls-files`, not from ignored or
    # untracked files. This is the key allowlist-first boundary.
    for relative in sorted(tracked):
        if any(relative == prefix or relative.startswith(prefix + "/") for prefix in PUBLIC_PREFIXES):
            source = repo / relative
            _safe_source_file(source)
            selected.add((relative, relative))

    return sorted(selected, key=lambda item: (item[1], item[0]))


def _copy_selected(
    repo: Path,
    staging: Path,
    selected: Sequence[tuple[str, str]],
) -> list[str]:
    copied: list[str] = []
    for source_relative, destination_relative in selected:
        source = repo / source_relative
        destination = staging / destination_relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        _safe_source_file(source)
        shutil.copy2(source, destination)
        copied.append(destination_relative)
    return sorted(set(copied))


def _digest(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()[:12]


def _synthetic_value(value: str) -> bool:
    normalized = value.strip().strip("\"'` ,;)]}").lower()
    return (
        normalized in SYNTHETIC_VALUES
        or normalized.startswith(("stub-", "stub_"))
        or normalized.endswith(("_stub", "-stub", "_sentinel", "-sentinel"))
    )


# Swift/Python/shell comment shapes, not Markdown: "*" and "#" are a
# bullet and a heading there, so adjacent Markdown lines can be joined
# into one context.  That is deliberate slack in the safe direction --
# it can only widen what a co-occurrence rule sees, never narrow it.
_COMMENT_OPENERS = ("//", "#", "*", "/*")


def _comment_contexts(lines: Sequence[str]) -> list[str]:
    """Per-line text that co-occurrence rules see.

    A provenance note is usually split across a doc-comment block: the record
    is named on one line and the fact that it was copied on the next.  Runs of
    adjacent comment lines are therefore evaluated as one unit.  Non-comment
    lines see only themselves, so unrelated prose is never joined.
    """
    contexts: list[str] = [""] * len(lines)
    start: int | None = None
    for index in range(len(lines) + 1):
        stripped = lines[index].strip() if index < len(lines) else ""
        is_comment = index < len(lines) and stripped.startswith(_COMMENT_OPENERS)
        if is_comment:
            if start is None:
                start = index
            continue
        if start is not None:
            block = "\n".join(lines[start:index])
            for position in range(start, index):
                contexts[position] = block
            start = None
        if index < len(lines):
            contexts[index] = lines[index]
    return contexts


def _line_findings(
    path: str,
    line_number: int,
    line: str,
    context: str | None = None,
) -> list[dict[str, object]]:
    findings: list[dict[str, object]] = []
    if context is None:
        context = line

    def add(code: str, marker: str = "") -> None:
        findings.append(
            {
                "path": path,
                "line": line_number,
                "finding_code": code,
                "digest": _digest(marker or code),
            }
        )

    if MACHINE_PATH_RE.search(line):
        add("MACHINE_ABSOLUTE_PATH", MACHINE_PATH_RE.search(line).group(0))
    if AUTHCODE_RE.search(line):
        add("FEISHU_ACCESS_BEARING_URL", "authcode")
    if PRIVATE_KEY_RE.search(line):
        add("PRIVATE_KEY_HEADER", "private-key")
    if PRIVATE_HOST_RE.search(line):
        add("PRIVATE_HOST_OR_IP", PRIVATE_HOST_RE.search(line).group(0))

    for pattern in KEY_FORMAT_RES:
        match = pattern.search(line)
        if match:
            add("CREDENTIAL_FORMAT", match.group(0))

    assignment = ASSIGNMENT_RE.search(line)
    if assignment:
        value = next(
            (group for group in assignment.groups() if group is not None), ""
        )
        if not _synthetic_value(value):
            add("CREDENTIAL_ASSIGNMENT", value)

    for match in EMAIL_RE.finditer(line):
        domain = match.group(0).rsplit("@", 1)[-1].lower()
        if domain not in {"example.com", "example.org", "example.net", "example.invalid"}:
            add("PERSONAL_OR_INTERNAL_EMAIL", match.group(0))

    # Sibling of MACHINE_ABSOLUTE_PATH: that rule only sees an expanded home
    # directory, and the tilde form of the same reference walked straight past
    # it.  Only a path reaching inside one of the store's directories counts.
    user_data_entry = USER_DATA_ENTRY_RE.search(line)
    if user_data_entry:
        add("HOME_RELATIVE_USER_DATA_PATH", user_data_entry.group(0))

    # A concrete session-directory name is a shape, not a word: it identifies
    # one real recording session, so it stands alone.
    session_slug = SESSION_SLUG_RE.search(line)
    if session_slug:
        add("REAL_DATA_PROVENANCE", session_slug.group(0))
    # A copy verb, or a claim that the content came out of the running
    # product's own records, is evidence only together with what was taken.
    # Three pairings, and neither half of any of them fires alone: a copy verb
    # with its subject; a copy verb with the origin claim standing in for the
    # subject, which is how a note names a body of recorded usage instead of
    # one record; an origin claim with a record filename.  Same rule in
    # either language.
    elif COPY_VERB_RE.search(context) and COPY_SUBJECT_RE.search(context):
        add("REAL_DATA_PROVENANCE", "copied-record")
    elif COPY_VERB_RE.search(context) and REAL_STOCK_RE.search(context):
        add("REAL_DATA_PROVENANCE", "copied-live-stock")
    elif REAL_STOCK_RE.search(context) and DATA_ARTIFACT_RE.search(context):
        add("REAL_DATA_PROVENANCE", "live-store-record")

    return findings


def _path_findings(relative: str) -> list[dict[str, object]]:
    normalized = relative.replace(os.sep, "/")
    findings: list[dict[str, object]] = []
    if normalized == ".git" or normalized.startswith(".git/"):
        findings.append(
            {"path": normalized, "line": None, "finding_code": "GIT_METADATA", "digest": _digest(normalized)}
        )
    if any(normalized.startswith(prefix) for prefix in PRIVATE_PATH_PREFIXES):
        findings.append(
            {"path": normalized, "line": None, "finding_code": "PRIVATE_PATH", "digest": _digest(normalized)}
        )
    lower = normalized.lower()
    if lower.startswith(".build/") or "/.build/" in lower or lower.startswith("build/"):
        findings.append(
            {"path": normalized, "line": None, "finding_code": "BUILD_ARTIFACT", "digest": _digest(normalized)}
        )
    if any(lower.endswith(suffix) for suffix in SENSITIVE_SUFFIXES):
        findings.append(
            {"path": normalized, "line": None, "finding_code": "SENSITIVE_ARTIFACT_EXTENSION", "digest": _digest(normalized)}
        )
    if normalized.startswith(".github/workflows/") and PurePosixPath(normalized).name.startswith("uihierarchy-"):
        findings.append(
            {"path": normalized, "line": None, "finding_code": "TASK1_CONSTRUCTION_WORKFLOW", "digest": _digest(normalized)}
        )
    return findings


def scan_tree(root: Path) -> list[dict[str, object]]:
    if not root.exists() or not root.is_dir() or root.is_symlink():
        raise RuntimeError(f"candidate is not a directory: {root}")
    findings: list[dict[str, object]] = []
    for directory, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        directory_names.sort()
        file_names.sort()
        # A symlinked directory is not traversed and is itself a finding.
        kept_directories: list[str] = []
        for name in directory_names:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                findings.extend(_path_findings(relative))
                findings.append(
                    {"path": relative, "line": None, "finding_code": "SYMLINK", "digest": _digest(relative)}
                )
            else:
                findings.extend(_path_findings(relative + "/"))
                kept_directories.append(name)
        directory_names[:] = kept_directories

        for name in file_names:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            findings.extend(_path_findings(relative))
            if path.is_symlink():
                findings.append(
                    {"path": relative, "line": None, "finding_code": "SYMLINK", "digest": _digest(relative)}
                )
                continue
            try:
                data = path.read_bytes()
            except OSError:
                findings.append(
                    {"path": relative, "line": None, "finding_code": "UNREADABLE_FILE", "digest": _digest(relative)}
                )
                continue
            if b"\0" in data:
                findings.append(
                    {"path": relative, "line": None, "finding_code": "UNREVIEWED_BINARY", "digest": _digest(relative)}
                )
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                findings.append(
                    {"path": relative, "line": None, "finding_code": "NON_UTF8_FILE", "digest": _digest(relative)}
                )
                continue
            lines = text.splitlines()
            contexts = _comment_contexts(lines)
            for line_number, line in enumerate(lines, start=1):
                findings.extend(
                    _line_findings(
                        relative,
                        line_number,
                        line,
                        contexts[line_number - 1],
                    )
                )

    return sorted(
        findings,
        key=lambda finding: (
            str(finding.get("path", "")),
            int(finding["line"]) if finding.get("line") is not None else 0,
            str(finding.get("finding_code", "")),
            str(finding.get("digest", "")),
        ),
    )


def _write_manifest(
    candidate: Path,
    source_sha: str,
    source_status: str,
    source_mode: str,
    policy_revision: str,
    copied_paths: Sequence[str],
    canonical_signature: dict[str, object],
    public_signature: dict[str, object],
) -> None:
    files = []
    for relative in sorted(set(copied_paths)):
        path = candidate / relative
        files.append(
            {
                "path": relative,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )
    if source_mode == SOURCE_MODE_PRIVATE_CANONICAL:
        transformation = "public-template-filters-all-verification-targets"
    elif source_mode == SOURCE_MODE_SANITIZED_PUBLIC:
        transformation = "identity-already-sanitized-public-manifest"
    else:
        raise RuntimeError("manifest source mode is ambiguous")
    manifest = {
        "format": 2,
        "source_sha": source_sha,
        "source_status": source_status,
        "source_mode": source_mode,
        "policy_revision": policy_revision,
        "manifest_path_excluded_from_file_hashes": MANIFEST_NAME,
        "package_manifest": {
            "canonical_signature": canonical_signature,
            "public_signature": public_signature,
            "transformation": transformation,
        },
        "files": files,
    }
    (candidate / MANIFEST_NAME).write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _is_inside_directory(path: Path, directory: Path) -> bool:
    return path == directory or directory in path.parents


def _validate_export_output(repo: Path, output: Path) -> None:
    """Reject outputs whose physical destination is inside ``repo``.

    ``repo`` must already be a resolved directory. Existing ancestor
    symlinks are followed; a missing final component is allowed. The
    caller-specified output path itself may not be a symlink, even when
    its target would otherwise be outside the repository.
    """
    if not output.is_absolute():
        raise RuntimeError("output must be an absolute path")
    if output.is_symlink():
        raise RuntimeError("output must not be a symlink")
    resolved_output = output.resolve(strict=False)
    if _is_inside_directory(resolved_output, repo):
        raise RuntimeError("output must be outside the canonical repository")


def export_candidate(repo: Path, output: Path, require_clean: bool) -> int:
    repo = repo.resolve()
    if not repo.is_dir():
        raise RuntimeError(f"repository is not a directory: {repo}")
    _validate_export_output(repo, output)
    if output.exists() and not output.is_dir():
        raise RuntimeError("output exists and is not a directory")
    if output.exists() and any(output.iterdir()):
        raise RuntimeError("refusing to overwrite a non-empty output directory")
    output.parent.mkdir(parents=True, exist_ok=True)

    git_work_tree = _is_git_work_tree(repo)
    if git_work_tree:
        tracked = _tracked_paths(repo)
        dirty = _is_dirty(repo)
        if require_clean and dirty:
            raise RuntimeError("--require-clean refused a dirty canonical working tree")
        source_sha = _run_git(repo, "rev-parse", "HEAD").strip()
        source_status = "dirty" if dirty else "clean"
    else:
        if require_clean:
            raise RuntimeError("--require-clean requires a Git working tree")
        tracked = _filesystem_public_paths(repo)
        source_sha = ""
        source_status = "filesystem"
    source_mode, canonical_signature, public_signature = _validate_manifest_template(repo)
    policy_revision = _policy_revision(repo)
    selected = _selected_source_paths(repo, tracked, require_clean)
    if not git_work_tree:
        source_sha = _filesystem_source_identity(repo, selected)

    staging: Path | None = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=str(output.parent))
    )
    try:
        copied = _copy_selected(repo, staging, selected)
        _write_manifest(
            staging,
            source_sha,
            source_status,
            source_mode,
            policy_revision,
            copied,
            canonical_signature,
            public_signature,
        )
        findings = scan_tree(staging)
        if findings:
            _print_findings(findings, False)
            print(f"PUBLIC_CANDIDATE_FAIL: {len(findings)} finding(s)", file=sys.stderr)
            raise RuntimeError("public candidate scan failed")
        if output.exists():
            # It was checked empty above; remove only that explicitly named
            # empty directory before presenting the verified staging tree.
            output.rmdir()
        os.replace(staging, output)
        staging = None
    finally:
        if staging is not None and staging.exists() and staging.is_dir():
            shutil.rmtree(staging)

    mode = {
        "clean": "clean committed tree",
        "dirty": "dirty working tree",
        "filesystem": "sanitized filesystem tree",
    }[source_status]
    print(
        f"PUBLIC_EXPORT_PASS: {output} ({len(copied)} files; {mode}; "
        f"source_mode {source_mode}; source {source_sha[:12]})"
    )
    return 0


def _print_findings(findings: Sequence[dict[str, object]], as_json: bool) -> None:
    if as_json:
        print(json.dumps(list(findings), ensure_ascii=False, indent=2, sort_keys=True))
        return
    for finding in findings:
        line = finding.get("line")
        location = f"{finding['path']}:{line}" if line is not None else str(finding["path"])
        print(f"{location}: {finding['finding_code']} ({finding['digest']})")


def run_self_test() -> int:
    """Discriminative scanner fixtures generated at runtime.

    Sensitive strings are concatenated so this source file does not itself
    become a candidate finding.
    """
    root = Path(tempfile.mkdtemp(prefix="justsaid-public-self-test-"))
    try:
        users = "Us" + "ers"
        (root / "machine.txt").write_text(
            f"/{users}/example-user/audio.m4a\n", encoding="utf-8"
        )

        auth = "auth" + "code"
        host = "fei" + "shu" + ".example.invalid"
        (root / "feishu.txt").write_text(
            f"https://{host}/open?{auth}=dummy-value-not-a-secret\n",
            encoding="utf-8",
        )

        header = "-" * 5 + "BEGIN RSA" + " PRIVATE KEY" + "-" * 5
        (root / "key.txt").write_text(header + "\n", encoding="utf-8")

        private_note = root / "research" / "acceptance" / "note.md"
        private_note.parent.mkdir(parents=True, exist_ok=True)
        private_note.write_text("synthetic private-path marker\n", encoding="utf-8")

        workflow = root / ".github" / "workflows" / "uihierarchy-temp.yml"
        workflow.parent.mkdir(parents=True, exist_ok=True)
        workflow.write_text("name: temporary\n", encoding="utf-8")

        (root / "secret.pem").write_text("not-a-real-certificate\n", encoding="utf-8")

        git_head = root / ".git" / "HEAD"
        git_head.parent.mkdir(parents=True, exist_ok=True)
        git_head.write_text("ref: refs/heads/main\n", encoding="utf-8")

        (root / "assignment.swift").write_text(
            'password: "' + "not-a-real-" + "credential-value" + '"\n',
            encoding="utf-8",
        )

        token_prefix = "gh" + "p_"
        (root / "token-format.txt").write_text(
            token_prefix + ("A" * 36) + "\n", encoding="utf-8"
        )

        (root / "synthetic.swift").write_text(
            'api_key: "LIVE_SECRET_STUB"\n'
            "var token: String\n"
            "contact: nobody@example.com\n"
            "secretKey: configuration\n",
            encoding="utf-8",
        )

        # A provenance note split across one doc-comment block: the record is
        # named on the first line, the copy verb stands alone on the second.
        data_root = "~/" + "JustSaid"
        record_path = (
            data_root + "/meetings/1999-01-02-\u4f1a\u8bae-7/" + "minutes" + ".json"
        )
        (root / "provenance-block.swift").write_text(
            "/// \u771f\u5b9e\u5b58\u91cf v1 sidecar: " + record_path + "\n"
            "/// 1999-01-03 \u539f\u6837\u62f7\u8d1d, read-only decode fixture.\n",
            encoding="utf-8",
        )

        # The same note written in English, split the same way and carrying no
        # session-directory name or store path, so the only thing that can
        # catch it is the co-occurrence across the two comment lines.  The
        # subject is capitalised on purpose: it is what asserts that the
        # subject side folds case.
        (root / "provenance-english.swift").write_text(
            "/// Decode fixture for the Meeting " + "minutes" + " sidecar.\n"
            "/// " + "Cop" + "ied verbatim, do not regenerate.\n",
            encoding="utf-8",
        )

        # An English origin claim paired with a record filename, on one line.
        (root / "provenance-english-store.swift").write_text(
            "/// Regression snapshot " + "ta" + "ken from the live store: "
            + "minutes" + ".json.\n",
            encoding="utf-8",
        )

        # English annotations that must keep passing: a copy verb whose object
        # is a document rather than a record, the product's own real-time
        # wording, a byte-for-byte round-trip assertion with no copy noun
        # attached, a bare record filename, and a bare subject word.  Blank
        # lines keep each note in its own comment block.
        (root / "benign-english.swift").write_text(
            "/// " + "Cop" + "ied from the design doc, nothing came from a user.\n"
            "\n"
            "/// " + "Real" + "-time audio is chunked before the encoder runs.\n"
            "\n"
            "/// Byte" + "-for-byte round-trip is asserted by the decoder test.\n"
            "\n"
            'let sidecar = "' + "meeting" + '.json"\n'
            "\n"
            "/// The " + "transcript" + " view is rebuilt on every layout pass.\n",
            encoding="utf-8",
        )

        # Engineering annotations that must keep passing: a real-hardware note,
        # a real-meeting behavioural note, the store's own documented top-level
        # names, a bare directory reference followed by prose, and a record
        # filename with nothing claiming it was copied in.  Blank lines keep
        # each note in its own comment block.
        (root / "benign-annotations.swift").write_text(
            "/// \u771f\u673a\u5b9e\u6d4b: window reopen is a no-op here.\n"
            "/// 2026 \u771f\u5b9e\u4f1a\u8bae behaviour note, no data copied.\n"
            "\n"
            "/// dictionary lives at " + data_root + "/\u8bcd\u5178.txt\n"
            "/// never enumerates `" + data_root + "/meetings/`"
            "\u2014\u8bca\u65ad\u5305\u767d\u540d\u5355\u5236\n"
            "\n"
            "let sidecar = \"" + "minutes" + ".json\"\n"
            "\n"
            "/// \u539f\u6837\u62f7\u8d1d of the layout tokens from the spec.\n",
            encoding="utf-8",
        )

        findings = scan_tree(root)
        by_path: dict[str, set[str]] = {}
        by_line: dict[tuple[str, int | None], set[str]] = {}
        for finding in findings:
            by_path.setdefault(str(finding["path"]), set()).add(
                str(finding["finding_code"])
            )
            line = finding.get("line")
            by_line.setdefault(
                (str(finding["path"]), None if line is None else int(line)), set()
            ).add(str(finding["finding_code"]))

        def require(relative: str, expected: set[str]) -> None:
            got = by_path.get(relative, set())
            if got != expected:
                raise RuntimeError(
                    f"self-test mismatch for {relative}: "
                    f"expected {sorted(expected)} got {sorted(got)}"
                )

        require("machine.txt", {"MACHINE_ABSOLUTE_PATH"})
        require("feishu.txt", {"FEISHU_ACCESS_BEARING_URL"})
        require("key.txt", {"PRIVATE_KEY_HEADER"})
        require("research/acceptance/note.md", {"PRIVATE_PATH"})
        require(
            ".github/workflows/uihierarchy-temp.yml",
            {"PRIVATE_PATH", "TASK1_CONSTRUCTION_WORKFLOW"},
        )
        require("secret.pem", {"SENSITIVE_ARTIFACT_EXTENSION"})
        require(".git/HEAD", {"GIT_METADATA"})
        require("assignment.swift", {"CREDENTIAL_ASSIGNMENT"})
        require("token-format.txt", {"CREDENTIAL_FORMAT"})
        require("synthetic.swift", set())

        def require_line(relative: str, line: int, expected: set[str]) -> None:
            got = by_line.get((relative, line), set())
            if got != expected:
                raise RuntimeError(
                    f"self-test mismatch for {relative}:{line}: "
                    f"expected {sorted(expected)} got {sorted(got)}"
                )

        # The record line carries both the tilde-path finding and the
        # provenance finding; the copy verb on the next line is evidence only
        # because its comment block names what was copied.
        require_line(
            "provenance-block.swift",
            1,
            {"HOME_RELATIVE_USER_DATA_PATH", "REAL_DATA_PROVENANCE"},
        )
        require_line("provenance-block.swift", 2, {"REAL_DATA_PROVENANCE"})
        # The English note carries neither a slug nor a store path, so both
        # lines are findings only because the comment block joins the subject
        # on the first line to the copy verb on the second.
        require_line("provenance-english.swift", 1, {"REAL_DATA_PROVENANCE"})
        require_line("provenance-english.swift", 2, {"REAL_DATA_PROVENANCE"})
        require_line("provenance-english-store.swift", 1, {"REAL_DATA_PROVENANCE"})
        require("benign-annotations.swift", set())
        require("benign-english.swift", set())
        _run_containment_self_test()
        _run_manifest_mode_self_test()
        print("PUBLIC_SELF_TEST_PASS")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


def _expect_export_output_error(repo: Path, output: Path, fragment: str) -> None:
    try:
        _validate_export_output(repo, output)
    except RuntimeError as error:
        if fragment not in str(error):
            raise RuntimeError(
                f"containment error mismatch: expected {fragment!r} in {error}"
            ) from error
        return
    raise RuntimeError(f"expected containment rejection ({fragment})")


def _run_containment_self_test() -> None:
    """Regression for ancestor-symlink and ``..`` export containment."""
    sandbox = Path(tempfile.mkdtemp(prefix="justsaid-public-containment-"))
    try:
        repo = (sandbox / "repo").resolve()
        repo.mkdir()
        (repo / "marker").write_text("canonical\n", encoding="utf-8")
        outside = sandbox / "outside"
        outside.mkdir()

        _expect_export_output_error(
            repo, repo / "public-output", "outside the canonical repository"
        )

        parent_link = sandbox / "link-into-repo"
        parent_link.symlink_to(repo)
        _expect_export_output_error(
            repo,
            parent_link / "public-output",
            "outside the canonical repository",
        )

        _expect_export_output_error(
            repo,
            repo / ".." / repo.name / "public-output",
            "outside the canonical repository",
        )

        _validate_export_output(repo, outside / "public-output")

        real_dir = outside / "real-dir"
        real_dir.mkdir()
        output_link = outside / "public-output-link"
        output_link.symlink_to(real_dir)
        _expect_export_output_error(repo, output_link, "must not be a symlink")
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _expect_mode_error(
    canonical_targets: dict[str, ManifestTarget],
    public_targets: dict[str, ManifestTarget],
    fragment: str,
) -> None:
    try:
        _classify_manifest_source_mode(canonical_targets, public_targets)
    except RuntimeError as error:
        if fragment not in str(error):
            raise RuntimeError(
                f"source-mode error mismatch: expected {fragment!r} in {error}"
            ) from error
        return
    raise RuntimeError(f"expected source-mode rejection ({fragment})")


_SELF_TEST_CANONICAL_MANIFEST = """\
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "FixturePackage",
  targets: [
    .target(
      name: "CoreFixture",
      dependencies: [
        .product(name: "pkg", package: "pkg")
      ],
      linkerSettings: [
        .linkedFramework("AudioToolbox"),
        .linkedFramework("Security"),
      ]
    ),
    .executableTarget(
      name: "AppFixture",
      dependencies: ["CoreFixture"]
    ),
    .executableTarget(
      name: "FixtureVerification",
      dependencies: ["CoreFixture"],
      path: "__VERIFICATION__/Fixture"
    ),
  ]
)
""".replace("__VERIFICATION__", VERIFICATION_ROOT)

# Same graph minus the verification target, reformatted: one-line argument
# lists, no trailing commas.  Normalisation must accept this and still reject
# every semantic edit below.
_SELF_TEST_PUBLIC_MANIFEST = """\
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "FixturePackage",
  targets: [
    .target(name: "CoreFixture",
            dependencies: [.product(name: "pkg", package: "pkg")],
            linkerSettings: [.linkedFramework("AudioToolbox"),
                             .linkedFramework("Security")]),
    .executableTarget(name: "AppFixture", dependencies: ["CoreFixture"]),
  ]
)
"""


def _expect_declaration_mismatch(canonical_text: str, public_text: str) -> None:
    _expect_mode_error(
        _manifest_targets(canonical_text),
        _manifest_targets(public_text),
        "public Package target declaration mismatch in",
    )


def _run_manifest_declaration_self_test() -> None:
    """Every surviving target is compared whole, not just by name and path."""
    canonical = _SELF_TEST_CANONICAL_MANIFEST
    baseline_mode = _classify_manifest_source_mode(
        _manifest_targets(canonical), _manifest_targets(_SELF_TEST_PUBLIC_MANIFEST)
    )
    if baseline_mode != SOURCE_MODE_PRIVATE_CANONICAL:
        raise RuntimeError(
            "reformatted-but-equivalent public template was rejected: "
            f"{baseline_mode}"
        )

    # Spacing around an argument label's colon is formatting at every nesting
    # depth, not only for a declaration's own top-level labels.
    respaced = (
        _SELF_TEST_PUBLIC_MANIFEST.replace("name: ", "name:")
        .replace("package: ", "package:")
        .replace("dependencies: ", "dependencies:  ")
        .replace("linkerSettings: ", "linkerSettings:")
    )
    if respaced == _SELF_TEST_PUBLIC_MANIFEST:
        raise RuntimeError("colon-spacing fixture did not change the template")
    respaced_mode = _classify_manifest_source_mode(
        _manifest_targets(canonical), _manifest_targets(respaced)
    )
    if respaced_mode != SOURCE_MODE_PRIVATE_CANONICAL:
        raise RuntimeError(
            f"colon-respaced public template was rejected: {respaced_mode}"
        )

    # A dropped dependency on a surviving target.
    _expect_declaration_mismatch(
        canonical,
        _SELF_TEST_PUBLIC_MANIFEST.replace(
            '.executableTarget(name: "AppFixture", dependencies: ["CoreFixture"])',
            '.executableTarget(name: "AppFixture", dependencies: [])',
        ),
    )
    # An extra dependency on a surviving target.
    _expect_declaration_mismatch(
        canonical,
        _SELF_TEST_PUBLIC_MANIFEST.replace(
            'dependencies: ["CoreFixture"])',
            'dependencies: ["CoreFixture", "Extra"])',
        ),
    )
    # An edited linker setting on a surviving target.
    _expect_declaration_mismatch(
        canonical,
        _SELF_TEST_PUBLIC_MANIFEST.replace(
            '.linkedFramework("Security")', '.linkedFramework("Speech")'
        ),
    )
    # A dropped linker setting on a surviving target.
    _expect_declaration_mismatch(
        canonical,
        _SELF_TEST_PUBLIC_MANIFEST.replace(
            ',\n                             .linkedFramework("Security")', ""
        ),
    )
    # A settings block the canonical graph does not declare.
    _expect_declaration_mismatch(
        canonical,
        _SELF_TEST_PUBLIC_MANIFEST.replace(
            '.executableTarget(name: "AppFixture", dependencies: ["CoreFixture"])',
            '.executableTarget(name: "AppFixture", dependencies: ["CoreFixture"], '
            'swiftSettings: [.unsafeFlags(["-Onone"])])',
        ),
    )
    # Target kind is part of the graph too.
    _expect_declaration_mismatch(
        canonical,
        _SELF_TEST_PUBLIC_MANIFEST.replace(
            '.executableTarget(name: "AppFixture"', '.target(name: "AppFixture"'
        ),
    )


_SELF_TEST_TARGET_KIND_MANIFEST = """\
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "FixturePackage",
  targets: [
    .target(name: "CoreFixture"),
    .executableTarget(
      name: "AppFixture",
      dependencies: [.target(name: "CoreFixture")],
      plugins: [.plugin(name: "LintPlugin", package: "lint")]
    ),
    .testTarget(
      name: "FixtureTests",
      dependencies: ["CoreFixture"],
      path: "__VERIFICATION__/FixtureTests"
    ),
  ]
)
""".replace("__VERIFICATION__", VERIFICATION_ROOT)


def _run_target_kind_self_test() -> None:
    """Declaration spellings beyond .target/.executableTarget are in scope.

    A ``Verification/``-rooted target declared with any other spelling would
    otherwise be invisible to both the filter and the parity comparison, which
    is the same "it happens to match today" gap this check exists to close.
    Nested occurrences of the same spellings are references, not declarations.
    """
    targets = _manifest_targets(_SELF_TEST_TARGET_KIND_MANIFEST)
    if set(targets) != {"CoreFixture", "AppFixture", "FixtureTests"}:
        raise RuntimeError(f"unexpected declared target set: {sorted(targets)}")
    if targets["FixtureTests"].kind != "testTarget":
        raise RuntimeError("testTarget declaration lost its kind")
    if _verification_target_names(targets) != {"FixtureTests"}:
        raise RuntimeError("a Verification-rooted testTarget escaped the filter")

    filtered = {
        name: target
        for name, target in targets.items()
        if name != "FixtureTests"
    }
    mode = _classify_manifest_source_mode(targets, filtered)
    if mode != SOURCE_MODE_PRIVATE_CANONICAL:
        raise RuntimeError(f"expected private_canonical, got {mode}")
    _expect_mode_error(
        targets,
        targets,
        "public Package template declares a verification target",
    )


def _run_real_manifest_declaration_self_test() -> None:
    """The same comparison, driven by this checkout's real manifests.

    Synthetic fixtures cannot show that the shipped template is compared on
    anything beyond name and path.  This mutates the real parsed graph -- one
    argument at a time, for every surviving target -- and requires each edit
    to turn red.
    """
    repo = Path(__file__).resolve().parents[1]
    canonical_path = repo / "Package.swift"
    template_path = repo / PUBLIC_PACKAGE_TEMPLATE
    if not canonical_path.is_file() or not template_path.is_file():
        raise RuntimeError("self-test cannot read the real Package manifests")
    canonical_targets = _manifest_targets(canonical_path.read_text(encoding="utf-8"))
    public_targets = _manifest_targets(template_path.read_text(encoding="utf-8"))
    mode = _classify_manifest_source_mode(canonical_targets, public_targets)
    if mode not in (SOURCE_MODE_PRIVATE_CANONICAL, SOURCE_MODE_SANITIZED_PUBLIC):
        raise RuntimeError(f"real manifests classified as {mode}")
    if not public_targets:
        raise RuntimeError("real public template declares no targets")

    mutated_any = False
    for name, target in sorted(public_targets.items()):
        if not target.arguments:
            # A target declared with name and path alone is legal SwiftPM;
            # there is simply nothing beyond the identity to mutate here.
            continue
        mutated_any = True
        for label, value in target.arguments:
            edited = dict(public_targets)
            edited[name] = replace(
                target,
                arguments=tuple(
                    sorted(
                        (existing, f"{existing_value} /* drift */")
                        if existing == label
                        else (existing, existing_value)
                        for existing, existing_value in target.arguments
                    )
                ),
            )
            _expect_mode_error(
                canonical_targets,
                edited,
                f"public Package target declaration mismatch in {name}: {label}",
            )
        dropped = dict(public_targets)
        dropped[name] = replace(target, arguments=())
        _expect_mode_error(
            canonical_targets,
            dropped,
            f"public Package target declaration mismatch in {name}:",
        )
        added = dict(public_targets)
        added[name] = replace(
            target,
            arguments=tuple(
                sorted(target.arguments + (("swiftSettings", '[ .unsafeFlags([ "-Onone" ]) ]'),))
            ),
        )
        _expect_mode_error(
            canonical_targets,
            added,
            f"public Package target declaration mismatch in {name}: swiftSettings",
        )
    if not mutated_any:
        raise RuntimeError(
            "no real public target carried an argument to mutate; this test "
            "proved nothing about the comparison"
        )


def _fixture_target(
    name: str, path: str | None = None, kind: str = "executableTarget"
) -> ManifestTarget:
    return ManifestTarget(kind=kind, name=name, path=path, arguments=())


def _run_manifest_mode_self_test() -> None:
    """Discriminative source-mode detection. Fail closed on mixed graphs."""
    verification_targets = {
        "MeetingStoreVerification": _fixture_target(
            "MeetingStoreVerification", VERIFICATION_ROOT + "/MeetingStoreRoundTrip"
        ),
        "RealE2EVerification": _fixture_target(
            "RealE2EVerification", VERIFICATION_ROOT + "/RealE2E"
        ),
    }
    public_targets = {
        "JustSaidCore": _fixture_target("JustSaidCore", kind="target"),
        "JustSaidUI": _fixture_target("JustSaidUI", kind="target"),
        "JustSaidApp": _fixture_target("JustSaidApp"),
    }

    canonical_private = dict(public_targets)
    canonical_private.update(verification_targets)
    mode_a = _classify_manifest_source_mode(canonical_private, public_targets)
    if mode_a != SOURCE_MODE_PRIVATE_CANONICAL:
        raise RuntimeError(f"expected private_canonical, got {mode_a}")

    mode_b = _classify_manifest_source_mode(public_targets, public_targets)
    if mode_b != SOURCE_MODE_SANITIZED_PUBLIC:
        raise RuntimeError(f"expected sanitized_public, got {mode_b}")

    # The regression that motivated this rule: a public template that still
    # declares any verification target names sources the export never copies.
    leaking_public = dict(public_targets)
    leaking_public["MeetingStoreVerification"] = verification_targets[
        "MeetingStoreVerification"
    ]
    _expect_mode_error(
        canonical_private,
        leaking_public,
        "public Package template declares a verification target",
    )
    _expect_mode_error(
        leaking_public,
        leaking_public,
        "public Package template declares a verification target",
    )

    dropped_public = dict(public_targets)
    dropped_public.pop("JustSaidUI")
    _expect_mode_error(
        canonical_private,
        dropped_public,
        "public Package target name/path parity mismatch",
    )

    drifted_public = dict(public_targets)
    drifted_public["UnexpectedTarget"] = _fixture_target("UnexpectedTarget")
    _expect_mode_error(
        public_targets,
        drifted_public,
        "public Package target name/path parity mismatch",
    )

    _run_target_kind_self_test()
    _run_manifest_declaration_self_test()
    _run_real_manifest_declaration_self_test()


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", nargs="?", help="candidate directory to scan")
    parser.add_argument("--json", action="store_true", help="emit redacted JSON findings")
    parser.add_argument("--export", action="store_true", help="materialize an allowlisted candidate")
    parser.add_argument("--repo", type=Path, help="canonical repository for --export")
    parser.add_argument("--output", type=Path, help="absolute candidate output for --export")
    parser.add_argument("--require-clean", action="store_true", help="require a clean committed source")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run discriminative scanner fixtures without printing secret values",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        if args.self_test:
            return run_self_test()
        if args.export:
            if args.repo is None or args.output is None:
                raise RuntimeError("--export requires --repo and --output")
            return export_candidate(args.repo, args.output, args.require_clean)
        if args.candidate is None:
            raise RuntimeError("a candidate directory is required")
        findings = scan_tree(Path(args.candidate))
        _print_findings(findings, args.json)
        if findings:
            print(f"PUBLIC_CANDIDATE_FAIL: {len(findings)} finding(s)", file=sys.stderr)
            return 1
        print("PUBLIC_CANDIDATE_PASS: no policy findings")
        return 0
    except (OSError, RuntimeError, ValueError) as error:
        # Operational messages only. Scan findings are already redacted before
        # this handler runs; do not interpolate matched secret values here.
        print(f"PUBLIC_POLICY_ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
