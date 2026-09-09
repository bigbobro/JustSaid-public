#!/usr/bin/env python3
"""Fail-closed, relocation-aware guard for Swift unchecked Sendable conformances.

The guard compares parsed nominal declaration identities between the real
origin/main baseline and the current checkout. File and line relocation is
allowed, while genuinely new identities still need a nearby synchronization
invariant.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Iterable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_MANIFEST = "Package.swift"
VERIFICATION_ROOT = "Verification"
# Production sources are always required.  The verification tree exists only
# in the private canonical checkout; the sanitized public tree runs this same
# script with Sources/ alone.  Which of the two a checkout is, is inferred
# from files on disk and never from a repository name: Verification/ is
# required exactly when this checkout's own Package.swift roots targets in it
# -- the same structural signal Scripts/verify-public-tree.py uses to
# classify private_canonical vs sanitized_public.  A canonical checkout whose
# Verification/ tree went missing therefore still fails closed.
REQUIRED_SCOPE_ROOTS = ("Sources",)
SCOPE_ROOTS = ("Sources", VERIFICATION_ROOT)
VERIFICATION_TARGET_PATH_RE = re.compile(
    r'\bpath:\s*"' + re.escape(VERIFICATION_ROOT) + r'(?:/[^"]*)?"'
)
MARKERS = (
    "safety invariant",
    "lock-protected",
    "protected by",
    "serialized by",
    "owned by",
    "single-owner",
    "single owner",
    "queue-confined",
    "actor-isolated",
)
NOMINAL_KINDS = frozenset(("class", "struct", "enum", "actor", "extension"))
FUNCTION_KINDS = frozenset(("func", "init", "deinit", "subscript"))
FUNCTION_FOLLOWERS = frozenset(
    ("func", "var", "let", "subscript", "init", "deinit", "accessor")
)
FUNCTION_DECLARATION_PREFIXES = frozenset(
    (
        "private",
        "fileprivate",
        "internal",
        "public",
        "open",
        "package",
        "final",
        "static",
        "class",
        "mutating",
        "nonmutating",
        "convenience",
        "required",
        "override",
        "dynamic",
        "indirect",
        "prefix",
        "postfix",
        "infix",
        "nonisolated",
        "isolated",
        "distributed",
        "borrowing",
        "consuming",
        "sending",
    )
)
ESCAPED_IDENTIFIER_DELIMITER = chr(96)


class PolicyError(Exception):
    """An operational or source parsing failure; policy must fail closed."""


class ParseError(PolicyError):
    """A marker or declaration could not be mapped unambiguously."""


@dataclass(frozen=True)
class Token:
    value: str
    start: int
    end: int
    line: int
    kind: str


def _is_syntax_word(token: Token, value: str) -> bool:
    """Return true only for a bare Swift word, not an escaped identifier."""
    return token.value == value and token.kind != "escaped_identifier"


def _is_identifier_token(token: Token) -> bool:
    return token.kind in ("identifier", "escaped_identifier")


@dataclass(frozen=True)
class DeclarationIdentity:
    kind: str
    components: tuple[str, ...]
    applicability_signature: str = ""

    @property
    def qualified_name(self) -> str:
        return ".".join(self.components)

    @property
    def display(self) -> str:
        if self.applicability_signature:
            return (
                f"{self.kind}|{self.qualified_name}|"
                f"{self.applicability_signature}"
            )
        return f"{self.kind}|{self.qualified_name}"


@dataclass(frozen=True)
class DeclarationOccurrence:
    identity: DeclarationIdentity
    path: str
    line: int
    normalized_header: str


@dataclass(frozen=True)
class _NominalDeclaration:
    kind: str
    name: str
    keyword_index: int
    open_index: int
    close_index: int
    marker_indices: tuple[int, ...]
    normalized_header: str
    applicability_signature: str


@dataclass(frozen=True)
class _FunctionScope:
    name: str
    signature: str
    open_index: int
    close_index: int


@dataclass(frozen=True)
class PolicyFinding:
    occurrence: DeclarationOccurrence
    message: str


@dataclass(frozen=True)
class Evaluation:
    baseline: tuple[DeclarationOccurrence, ...]
    current: tuple[DeclarationOccurrence, ...]
    grandfathered: int
    new: tuple[DeclarationOccurrence, ...]
    removed: int
    findings: tuple[PolicyFinding, ...]

    @property
    def passed(self) -> bool:
        return not self.findings


def _is_identifier_start(character: str) -> bool:
    return character == "_" or character.isalpha() or ord(character) >= 128


def _is_identifier_continue(character: str) -> bool:
    return _is_identifier_start(character) or character.isdigit()


def _advance_line(source: str, start: int, end: int, line: int) -> int:
    return line + source.count("\n", start, end)


def _skip_comment(source: str, index: int, line: int) -> tuple[int, int]:
    length = len(source)
    if source.startswith("//", index):
        end = source.find("\n", index + 2)
        if end < 0:
            return length, line
        return end, line
    if not source.startswith("/*", index):
        raise AssertionError("comment must start at slash")
    depth = 1
    cursor = index + 2
    while cursor < length and depth:
        if source.startswith("/*", cursor):
            depth += 1
            cursor += 2
        elif source.startswith("*/", cursor):
            depth -= 1
            cursor += 2
        else:
            cursor += 1
    if depth:
        raise ParseError("unterminated block comment")
    return cursor, _advance_line(source, index, cursor, line)


def _skip_interpolation(
    source: str, index: int, line: int, hash_count: int
) -> tuple[int, int]:
    """Skip a string interpolation expression, including nested literals."""
    depth = 1
    cursor = index
    while cursor < len(source):
        if source.startswith("//", cursor) or source.startswith("/*", cursor):
            cursor, line = _skip_comment(source, cursor, line)
            continue
        character = source[cursor]
        if character == '"' or (
            character == "#"
            and cursor + 1 < len(source)
            and source[cursor + 1] == '"'
        ):
            cursor, line = _skip_string(source, cursor, line)
            continue
        interpolation_prefix = "\\" + ("#" * hash_count) + "("
        if hash_count and source.startswith(interpolation_prefix, cursor):
            depth += 1
            cursor += len(interpolation_prefix)
            continue
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            cursor += 1
            if depth == 0:
                return cursor, line
            continue
        if character == "\n":
            line += 1
        cursor += 1
    raise ParseError("unterminated string interpolation")


def _skip_string(source: str, index: int, line: int) -> tuple[int, int]:
    length = len(source)
    cursor = index
    hash_count = 0
    while cursor < length and source[cursor] == "#":
        hash_count += 1
        cursor += 1

    raw = hash_count > 0
    if raw:
        if cursor >= length or source[cursor] != '"':
            return index, line
        quote_start = cursor
    else:
        if source[cursor] != '"':
            raise AssertionError("string must start with quote")
        quote_start = cursor

    triple = source.startswith('"""', quote_start)
    opening_length = 3 if triple else 1
    closing = '"' * opening_length + ("#" * hash_count)
    cursor = quote_start + opening_length

    while cursor < length:
        if source.startswith(closing, cursor):
            cursor += len(closing)
            return cursor, line
        if not raw and source.startswith("\\(", cursor):
            cursor, line = _skip_interpolation(source, cursor + 2, line, 0)
        elif raw and source.startswith("\\" + ("#" * hash_count) + "(", cursor):
            prefix = "\\" + ("#" * hash_count) + "("
            cursor, line = _skip_interpolation(
                source, cursor + len(prefix), line, hash_count
            )
        elif not raw and source[cursor] == "\\":
            end = min(cursor + 2, length)
            line += source.count("\n", cursor, end)
            cursor = end
        else:
            if source[cursor] == "\n":
                line += 1
            cursor += 1
    raise ParseError("unterminated string literal")


def tokenize(source: str) -> tuple[Token, ...]:
    """Tokenize Swift enough to locate declarations, hiding comments/strings."""
    tokens: list[Token] = []
    cursor = 0
    line = 1
    length = len(source)

    while cursor < length:
        character = source[cursor]
        if character.isspace():
            if character == "\n":
                line += 1
            cursor += 1
            continue

        if source.startswith("//", cursor) or source.startswith("/*", cursor):
            cursor, line = _skip_comment(source, cursor, line)
            continue

        if character == '"' or (
            character == "#" and cursor + 1 < length and source[cursor + 1] == '"'
        ):
            new_cursor, line = _skip_string(source, cursor, line)
            if new_cursor == cursor:
                raise ParseError("invalid string literal")
            cursor = new_cursor
            continue

        if character == ESCAPED_IDENTIFIER_DELIMITER:
            start = cursor
            token_line = line
            cursor += 1
            content_start = cursor
            while cursor < length and source[cursor] != ESCAPED_IDENTIFIER_DELIMITER:
                cursor += 1
            if cursor >= length:
                raise ParseError("unterminated escaped identifier")
            value = source[content_start:cursor]
            cursor += 1
            tokens.append(
                Token(value, start, cursor, token_line, "escaped_identifier")
            )
            continue

        if _is_identifier_start(character):
            start = cursor
            token_line = line
            cursor += 1
            while cursor < length and _is_identifier_continue(source[cursor]):
                cursor += 1
            tokens.append(
                Token(source[start:cursor], start, cursor, token_line, "identifier")
            )
            continue

        tokens.append(Token(character, cursor, cursor + 1, line, "punctuation"))
        cursor += 1

    return tuple(tokens)


def _brace_pairs(tokens: Sequence[Token]) -> dict[int, int]:
    opens: list[int] = []
    open_to_close: dict[int, int] = {}
    for index, token in enumerate(tokens):
        if token.value == "{":
            opens.append(index)
        elif token.value == "}":
            if not opens:
                raise ParseError(f"unmatched closing brace at line {token.line}")
            opening = opens.pop()
            open_to_close[opening] = index
    if opens:
        line = tokens[opens[-1]].line
        raise ParseError(f"unmatched opening brace at line {line}")
    return open_to_close


def _marker_indices(tokens: Sequence[Token]) -> tuple[int, ...]:
    return tuple(
        index
        for index in range(len(tokens) - 2)
        if tokens[index].value == "@"
        and _is_syntax_word(tokens[index + 1], "unchecked")
        and _is_syntax_word(tokens[index + 2], "Sendable")
    )


def _next_identifier(tokens: Sequence[Token], index: int) -> int | None:
    if index < len(tokens) and _is_identifier_token(tokens[index]):
        return index
    return None


def _parse_nominal_name(
    tokens: Sequence[Token], keyword_index: int, kind: str
) -> tuple[str, int] | None:
    name_index = _next_identifier(tokens, keyword_index + 1)
    if name_index is None:
        return None

    def skip_generic_arguments(index: int) -> tuple[int, str]:
        if index >= len(tokens) or tokens[index].value != "<":
            return index, ""
        start = index
        depth = 0
        while index < len(tokens):
            value = tokens[index].value
            if value == "<":
                depth += 1
            elif value == ">":
                depth -= 1
                if depth == 0:
                    suffix = " ".join(
                        token.value for token in tokens[start : index + 1]
                    )
                    return index + 1, suffix
            index += 1
        raise ParseError("unterminated generic argument list in nominal identity")

    if kind != "extension":
        after_name, suffix = skip_generic_arguments(name_index + 1)
        return tokens[name_index].value + suffix, after_name

    parts: list[str] = []
    cursor = name_index
    while True:
        current = _next_identifier(tokens, cursor)
        if current is None:
            raise ParseError("extension target is not a qualified nominal name")
        cursor, suffix = skip_generic_arguments(current + 1)
        parts.append(tokens[current].value + suffix)
        if cursor >= len(tokens) or tokens[cursor].value != ".":
            break
        cursor += 1
    return ".".join(parts), cursor


def _find_header_open(
    tokens: Sequence[Token], start_index: int
) -> int | None:
    paren_depth = 0
    bracket_depth = 0
    marker_seen = False
    declaration_starters = frozenset(
        (
            "let",
            "var",
            "func",
            "init",
            "deinit",
            "subscript",
            "return",
            "import",
            "private",
            "fileprivate",
            "internal",
            "public",
            "open",
            "package",
            "final",
            *NOMINAL_KINDS,
        )
    )
    cursor = start_index
    while cursor < len(tokens):
        value = tokens[cursor].value
        if (
            value == "@"
            and cursor + 2 < len(tokens)
            and _is_syntax_word(tokens[cursor + 1], "unchecked")
            and _is_syntax_word(tokens[cursor + 2], "Sendable")
        ):
            marker_seen = True
        if value == "(":
            paren_depth += 1
        elif value == ")":
            if paren_depth == 0:
                return None
            paren_depth -= 1
        elif value == "[":
            bracket_depth += 1
        elif value == "]":
            if bracket_depth == 0:
                return None
            bracket_depth -= 1
        elif value == "{" and paren_depth == 0 and bracket_depth == 0:
            return cursor
        elif value in (";", "}") and paren_depth == 0 and bracket_depth == 0:
            return None
        elif (
            _is_syntax_word(tokens[cursor], value)
            and value in NOMINAL_KINDS
            and cursor > start_index
            and paren_depth == 0
            and bracket_depth == 0
            and tokens[cursor - 1].value not in (":", ",", "&", "where")
        ):
            # A second nominal keyword before a body means the preceding
            # header is incomplete; do not borrow the later declaration body.
            return None
        elif (
            marker_seen
            and _is_syntax_word(tokens[cursor], value)
            and value in declaration_starters
            and paren_depth == 0
            and bracket_depth == 0
        ):
            # A statement/declaration starter after the marker indicates that
            # the marked header never reached its own body.
            return None
        cursor += 1
    return None


def _looks_like_type_keyword(tokens: Sequence[Token], index: int, kind: str) -> bool:
    if kind != "class":
        return True
    if index + 1 >= len(tokens):
        return True
    return not any(
        _is_syntax_word(tokens[index + 1], follower)
        for follower in FUNCTION_FOLLOWERS
    )


def _normalized_header(tokens: Sequence[Token], start: int, end: int) -> str:
    return " ".join(token.value for token in tokens[start:end]).strip()


def _parse_applicability_signature(
    tokens: Sequence[Token], start: int, end: int
) -> str:
    """Return a token-normalized trailing ``where`` clause.

    A nominal declaration's body opening brace is the only reliable boundary
    available to this lightweight parser.  We therefore locate ``where`` only
    at the top level of the declaration header, validate all nested delimiters,
    and fail closed when the clause is empty or malformed rather than silently
    dropping applicability from identity.
    """
    where_index: int | None = None
    angle_depth = 0
    paren_depth = 0
    bracket_depth = 0

    for index in range(start, end):
        token = tokens[index]
        value = token.value
        if (
            _is_syntax_word(token, "where")
            and angle_depth == 0
            and paren_depth == 0
            and bracket_depth == 0
        ):
            if where_index is not None:
                raise ParseError(
                    f"multiple trailing where clauses near line {token.line}"
                )
            where_index = index
            continue

        if value == "<":
            angle_depth += 1
        elif value == ">":
            if angle_depth == 0:
                raise ParseError(
                    f"unmatched generic closing delimiter at line {token.line}"
                )
            angle_depth -= 1
        elif value == "(":
            paren_depth += 1
        elif value == ")":
            if paren_depth == 0:
                raise ParseError(
                    f"unmatched header closing parenthesis at line {token.line}"
                )
            paren_depth -= 1
        elif value == "[":
            bracket_depth += 1
        elif value == "]":
            if bracket_depth == 0:
                raise ParseError(
                    f"unmatched header closing bracket at line {token.line}"
                )
            bracket_depth -= 1

    if angle_depth or paren_depth or bracket_depth:
        raise ParseError("unbalanced declaration-header delimiter")
    if where_index is None:
        return ""

    signature = _normalized_header(tokens, where_index, end)
    if signature == "where":
        raise ParseError("trailing where clause has no constraints")
    return signature


def _split_qualified_name(name: str) -> tuple[str, ...]:
    """Split a qualified name without treating dots inside generic args as scope."""
    parts: list[str] = []
    current: list[str] = []
    angle_depth = 0
    for character in name:
        if character == "<":
            angle_depth += 1
        elif character == ">":
            angle_depth -= 1
            if angle_depth < 0:
                raise ParseError("malformed generic identity")
        if character == "." and angle_depth == 0:
            if not current:
                raise ParseError("empty qualified identity component")
            parts.append("".join(current))
            current = []
        else:
            current.append(character)
    if angle_depth != 0 or not current:
        raise ParseError("malformed generic identity")
    parts.append("".join(current))
    return tuple(parts)


def _parse_nominal_declarations(
    tokens: Sequence[Token], open_to_close: Mapping[int, int]
) -> tuple[_NominalDeclaration, ...]:
    markers = _marker_indices(tokens)
    declarations: list[_NominalDeclaration] = []

    for index, token in enumerate(tokens):
        if token.kind == "escaped_identifier":
            continue
        kind = token.value
        if kind not in NOMINAL_KINDS or not _looks_like_type_keyword(tokens, index, kind):
            continue
        parsed_name = _parse_nominal_name(tokens, index, kind)
        if parsed_name is None:
            continue
        name, after_name = parsed_name
        open_index = _find_header_open(tokens, after_name)
        if open_index is None:
            continue
        close_index = open_to_close.get(open_index)
        if close_index is None:
            raise ParseError(
                f"{kind} {name} has no matched body at line {token.line}"
            )
        applicability_signature = _parse_applicability_signature(
            tokens, after_name, open_index
        )
        owned_markers = tuple(
            marker for marker in markers if index <= marker < open_index
        )
        declarations.append(
            _NominalDeclaration(
                kind=kind,
                name=name,
                keyword_index=index,
                open_index=open_index,
                close_index=close_index,
                marker_indices=owned_markers,
                normalized_header=_normalized_header(tokens, index, open_index),
                applicability_signature=applicability_signature,
            )
        )

    for marker in markers:
        owners = [
            declaration
            for declaration in declarations
            if declaration.keyword_index <= marker < declaration.open_index
        ]
        if len(owners) != 1:
            line = tokens[marker].line
            raise ParseError(
                f"@unchecked Sendable at line {line} cannot be mapped to one nominal declaration"
            )
    return tuple(declarations)


def _find_function_name(tokens: Sequence[Token], index: int) -> str:
    if tokens[index].value in ("init", "deinit", "subscript"):
        return tokens[index].value
    cursor = index + 1
    if cursor < len(tokens) and _is_identifier_token(tokens[cursor]):
        return tokens[cursor].value
    parts: list[str] = []
    while cursor < len(tokens) and tokens[cursor].value not in ("(", "{", ";", "}"):
        parts.append(tokens[cursor].value)
        cursor += 1
    return "".join(parts) or "operator"


def _find_function_body(tokens: Sequence[Token], start_index: int) -> int | None:
    paren_depth = 0
    bracket_depth = 0
    declaration_boundaries = FUNCTION_KINDS | NOMINAL_KINDS | frozenset(
        ("protocol",)
    )
    cursor = start_index
    while cursor < len(tokens):
        value = tokens[cursor].value
        if value == "(":
            paren_depth += 1
        elif value == ")":
            if paren_depth:
                paren_depth -= 1
        elif value == "[":
            bracket_depth += 1
        elif value == "]":
            if bracket_depth:
                bracket_depth -= 1
        elif (
            _is_syntax_word(tokens[cursor], value)
            and value in declaration_boundaries
            and paren_depth == 0
            and bracket_depth == 0
        ):
            # Do not let a declaration without a body borrow the next
            # declaration's body (for example, a protocol requirement
            # followed by a concrete method).
            return None
        elif value == "{" and paren_depth == 0 and bracket_depth == 0:
            return cursor
        elif value in (";", "}") and paren_depth == 0 and bracket_depth == 0:
            return None
        cursor += 1
    return None


def _is_probable_function_declaration(
    tokens: Sequence[Token], index: int
) -> bool:
    """Reject call/member-expression keywords masquerading as declarations."""
    if index == 0:
        return True
    previous = tokens[index - 1].value
    if previous == ".":
        return False
    # `func` is a declaration keyword in valid Swift; allowing it after a
    # closing parameter list also covers adjacent bodyless declarations.
    # The other function-kind words are routinely used as member-expression
    # calls (`value.init { ... }`), so they stay subject to the stricter
    # prefix/attribute checks below.
    if tokens[index].value == "func":
        return True
    if previous in ("{", "}", ";") or (
        _is_syntax_word(tokens[index - 1], previous)
        and previous in FUNCTION_DECLARATION_PREFIXES
    ):
        return True

    # Attributes may be written as either @MainActor or @available(...).
    # Walk only to the nearest declaration boundary; finding an attribute
    # there is enough evidence that this is a declaration, while an arbitrary
    # expression remains unknown and is handled fail-closed by scope mapping.
    cursor = index - 1
    while cursor >= 0 and tokens[cursor].value not in ("{", "}", ";"):
        if tokens[cursor].value == "@":
            return True
        cursor -= 1
    return False


def _parse_function_scopes(
    tokens: Sequence[Token], open_to_close: Mapping[int, int]
) -> tuple[_FunctionScope, ...]:
    scopes: list[_FunctionScope] = []
    for index, token in enumerate(tokens):
        if token.kind == "escaped_identifier" or token.value not in FUNCTION_KINDS:
            continue
        if not _is_probable_function_declaration(tokens, index):
            continue
        open_index = _find_function_body(tokens, index + 1)
        if open_index is None or open_index not in open_to_close:
            continue
        scopes.append(
            _FunctionScope(
                name=_find_function_name(tokens, index),
                signature=_normalized_header(tokens, index, open_index),
                open_index=open_index,
                close_index=open_to_close[open_index],
            )
        )
    return tuple(scopes)


def _enclosing(
    index: int, intervals: Iterable[tuple[int, int, object]]
) -> list[tuple[int, int, object]]:
    return sorted(
        [interval for interval in intervals if interval[0] < index < interval[1]],
        key=lambda item: item[0],
    )


def _qualified_components(
    declaration: _NominalDeclaration,
    declarations: Sequence[_NominalDeclaration],
    functions: Sequence[_FunctionScope],
    tokens: Sequence[Token],
    all_open_to_close: Mapping[int, int],
) -> tuple[str, ...]:
    enclosing_nominals = _enclosing(
        declaration.keyword_index,
        [
            (item.open_index, item.close_index, item)
            for item in declarations
            if item is not declaration
        ],
    )
    enclosing_functions = _enclosing(
        declaration.keyword_index,
        [
            (item.open_index, item.close_index, item)
            for item in functions
        ],
    )
    known_openings = {
        item[0] for item in enclosing_nominals
    } | {item[0] for item in enclosing_functions}
    for opening, closing in all_open_to_close.items():
        if opening < declaration.keyword_index < closing and opening not in known_openings:
            raise ParseError(
                f"nominal declaration {declaration.name} is inside an unrecognized lexical scope "
                f"at declaration line {tokens[declaration.keyword_index].line}"
            )

    components: list[str] = []
    scope_items: list[tuple[int, str, str]] = []
    for _, _, item in enclosing_nominals:
        scope_items.append((item.open_index, "nominal", item.name))
    for _, _, item in enclosing_functions:
        scope_items.append((item.open_index, "function", item.signature))
    for _, scope_kind, scope_name in sorted(scope_items):
        if scope_kind == "function":
            components.append(f"<function:{scope_name}>")
        else:
            components.extend(_split_qualified_name(scope_name))
    components.extend(_split_qualified_name(declaration.name))
    return tuple(components)


def parse_source(source: str, path: str = "<memory>") -> tuple[DeclarationOccurrence, ...]:
    tokens = tokenize(source)
    open_to_close = _brace_pairs(tokens)
    declarations = _parse_nominal_declarations(tokens, open_to_close)
    functions = _parse_function_scopes(tokens, open_to_close)

    occurrences: list[DeclarationOccurrence] = []
    for declaration in declarations:
        if not declaration.marker_indices:
            continue
        components = _qualified_components(
            declaration, declarations, functions, tokens, open_to_close
        )
        identity = DeclarationIdentity(
            declaration.kind,
            components,
            declaration.applicability_signature,
        )
        for marker_index in declaration.marker_indices:
            occurrences.append(
                DeclarationOccurrence(
                    identity=identity,
                    path=path,
                    line=tokens[marker_index].line,
                    normalized_header=declaration.normalized_header,
                )
            )
    return tuple(
        sorted(
            occurrences,
            key=lambda item: (item.path, item.line, item.identity.display),
        )
    )


def _declares_verification_targets(root: Path) -> bool:
    """Whether this checkout's Package.swift roots targets in Verification/.

    An unreadable manifest is a tampered checkout, not a public tree, so the
    inference itself fails closed.
    """
    try:
        manifest = (root / PACKAGE_MANIFEST).read_text(encoding="utf-8")
    except OSError as error:
        raise PolicyError(
            f"cannot read {PACKAGE_MANIFEST}: "
            f"{error.strerror or error.__class__.__name__}"
        ) from error
    return VERIFICATION_TARGET_PATH_RE.search(manifest) is not None


def _required_scope_roots(root: Path) -> frozenset[str]:
    required = set(REQUIRED_SCOPE_ROOTS)
    if _declares_verification_targets(root):
        required.add(VERIFICATION_ROOT)
    return frozenset(required)


def _scope_paths(root: Path) -> tuple[str, ...]:
    required = _required_scope_roots(root)
    paths: list[str] = []
    for scope_root in SCOPE_ROOTS:
        directory = root / scope_root
        if not directory.is_dir():
            if scope_root not in required:
                continue
            raise PolicyError(f"missing policy scope directory: {scope_root}")
        for path in sorted(directory.rglob("*.swift")):
            if path.is_symlink() or not path.is_file():
                raise PolicyError(f"non-regular Swift scope entry: {path}")
            paths.append(path.relative_to(root).as_posix())
    if not paths:
        raise PolicyError("policy scope contains no Swift files")
    return tuple(paths)


def _read_current_sources() -> dict[str, str]:
    sources: dict[str, str] = {}
    for relative in _scope_paths(ROOT):
        try:
            sources[relative] = (ROOT / relative).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise PolicyError(f"cannot read {relative}: {error}") from error
    return sources


def _run_git(*arguments: str, binary: bool = False) -> str | bytes:
    result = subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=not binary,
    )
    if result.returncode != 0:
        detail = (
            result.stderr.decode("utf-8", errors="replace").strip()
            if binary
            else result.stderr.strip()
        )
        raise PolicyError(detail or "git command failed")
    return result.stdout


def _read_baseline_sources() -> dict[str, str]:
    _run_git("rev-parse", "--verify", "origin/main^{commit}")
    listing = _run_git(
        "ls-tree",
        "-r",
        "--name-only",
        "origin/main",
        "--",
        "Sources",
        "Verification",
    )
    if not isinstance(listing, str):
        raise PolicyError("could not read baseline path list")
    paths = tuple(
        line.strip()
        for line in listing.splitlines()
        if line.strip().endswith(".swift")
    )
    if not paths:
        raise PolicyError("origin/main baseline has no Swift files in policy scope")

    sources: dict[str, str] = {}
    for relative in paths:
        try:
            content = _run_git("show", f"origin/main:{relative}", binary=True)
            if not isinstance(content, bytes):
                raise PolicyError("baseline content was not bytes")
            sources[relative] = content.decode("utf-8")
        except (UnicodeError, PolicyError) as error:
            raise PolicyError(f"cannot read baseline {relative}: {error}") from error
    return sources


def _inventories(files: Mapping[str, str]) -> tuple[DeclarationOccurrence, ...]:
    occurrences: list[DeclarationOccurrence] = []
    for path in sorted(files):
        try:
            occurrences.extend(parse_source(files[path], path))
        except PolicyError as error:
            raise ParseError(f"{path}: {error}") from error
    return tuple(
        sorted(
            occurrences,
            key=lambda item: (item.path, item.line, item.identity.display),
        )
    )


def has_nearby_invariant(source: str, line_number: int) -> bool:
    lines = source.splitlines()
    start = max(0, line_number - 8)
    end = min(len(lines), line_number + 8)
    context = "\n".join(lines[start:end]).lower()
    return any(marker in context for marker in MARKERS)


def evaluate_sources(
    baseline_files: Mapping[str, str], current_files: Mapping[str, str]
) -> Evaluation:
    baseline = _inventories(baseline_files)
    current = _inventories(current_files)
    baseline_counts = Counter(item.identity for item in baseline)
    current_counts = Counter(item.identity for item in current)
    remaining = Counter(baseline_counts)
    grandfathered_occurrences = 0
    new_occurrences: list[DeclarationOccurrence] = []

    for occurrence in current:
        if remaining[occurrence.identity] > 0:
            remaining[occurrence.identity] -= 1
            grandfathered_occurrences += 1
        else:
            new_occurrences.append(occurrence)

    removed = sum((baseline_counts - current_counts).values())
    findings: list[PolicyFinding] = []
    for occurrence in new_occurrences:
        source = current_files.get(occurrence.path)
        if source is None:
            raise ParseError(
                f"current occurrence {occurrence.identity.display} cannot map to {occurrence.path}"
            )
        if not has_nearby_invariant(source, occurrence.line):
            findings.append(
                PolicyFinding(
                    occurrence,
                    "new @unchecked Sendable lacks a nearby thread-safety invariant",
                )
            )

    return Evaluation(
        baseline=baseline,
        current=current,
        grandfathered=grandfathered_occurrences,
        new=tuple(new_occurrences),
        removed=removed,
        findings=tuple(findings),
    )


def _display_report(evaluation: Evaluation) -> str:
    production_current = sum(
        occurrence.path.startswith("Sources/") for occurrence in evaluation.current
    )
    verification_current = sum(
        occurrence.path.startswith("Verification/") for occurrence in evaluation.current
    )
    lines = [
        "Concurrency policy:",
        f"production_current={production_current}",
        f"verification_current={verification_current}",
        f"baseline_total={len(evaluation.baseline)}",
        f"current_total={len(evaluation.current)}",
        f"grandfathered={evaluation.grandfathered}",
        f"new={len(evaluation.new)}",
        f"removed={evaluation.removed}",
    ]
    if not evaluation.new:
        if _has_relocated_occurrence(evaluation):
            lines.append(
                "Existing conformances relocated without growing unsafe surface."
            )
        lines.append(
            "Concurrency policy passed: no new @unchecked Sendable conformances."
        )
    else:
        for finding in evaluation.findings:
            occurrence = finding.occurrence
            lines.append(
                f"{occurrence.path}:{occurrence.line}: "
                f"{occurrence.identity.display}: {finding.message}: "
                f"{occurrence.normalized_header}"
            )
        if not evaluation.findings:
            lines.append(
                "Concurrency policy passed: new conformances document their "
                "synchronization invariant."
            )
    return "\n".join(lines)


def _has_relocated_occurrence(evaluation: Evaluation) -> bool:
    baseline_by_identity: dict[DeclarationIdentity, Counter[str]] = {}
    current_by_identity: dict[DeclarationIdentity, Counter[str]] = {}
    for occurrence in evaluation.baseline:
        baseline_by_identity.setdefault(occurrence.identity, Counter())[occurrence.path] += 1
    for occurrence in evaluation.current:
        current_by_identity.setdefault(occurrence.identity, Counter())[occurrence.path] += 1
    for identity in baseline_by_identity.keys() & current_by_identity.keys():
        baseline_paths = baseline_by_identity[identity]
        current_paths = current_by_identity[identity]
        same_path = sum((baseline_paths & current_paths).values())
        if same_path < sum(baseline_paths.values()) and same_path < sum(current_paths.values()):
            return True
    return False


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


_SELF_TEST_CANONICAL_MANIFEST = """\
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "FixturePackage",
  targets: [
    .target(name: "CoreFixture"),
    .executableTarget(
      name: "FixtureVerification",
      dependencies: ["CoreFixture"],
      path: "__VERIFICATION__/Fixture"
    ),
  ]
)
""".replace("__VERIFICATION__", VERIFICATION_ROOT)

_SELF_TEST_PUBLIC_MANIFEST = """\
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "FixturePackage",
  targets: [
    .target(name: "CoreFixture"),
  ]
)
"""


def _write_scope_fixture(
    root: Path, manifest: str | None, scope_roots: Iterable[str]
) -> None:
    root.mkdir(parents=True, exist_ok=True)
    if manifest is not None:
        (root / PACKAGE_MANIFEST).write_text(manifest, encoding="utf-8")
    for scope_root in scope_roots:
        directory = root / scope_root
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Fixture.swift").write_text(
            "struct Fixture {}\n", encoding="utf-8"
        )


def _expect_scope_error(root: Path, fragment: str, label: str) -> None:
    try:
        _scope_paths(root)
    except PolicyError as error:
        _expect(
            fragment in str(error),
            f"{label}: expected {fragment!r} in {error}",
        )
        return
    raise AssertionError(f"{label}: expected a fail-closed rejection")


def _run_scope_mode_self_test() -> None:
    """Verification is optional only where the manifest declares no such target.

    The regression guarded here is fail-open: making Verification/
    unconditionally optional for the sanitized public tree would also let a
    private canonical checkout silently skip a Verification/ tree that had
    been deleted or renamed.
    """
    sandbox = Path(tempfile.mkdtemp(prefix="justsaid-concurrency-scope-"))
    try:
        canonical_complete = sandbox / "canonical-complete"
        _write_scope_fixture(
            canonical_complete,
            _SELF_TEST_CANONICAL_MANIFEST,
            ("Sources", VERIFICATION_ROOT),
        )
        _expect(
            _scope_paths(canonical_complete)
            == ("Sources/Fixture.swift", f"{VERIFICATION_ROOT}/Fixture.swift"),
            "canonical mode did not scan both scope roots",
        )

        canonical_missing = sandbox / "canonical-missing-verification"
        _write_scope_fixture(
            canonical_missing, _SELF_TEST_CANONICAL_MANIFEST, ("Sources",)
        )
        _expect_scope_error(
            canonical_missing,
            f"missing policy scope directory: {VERIFICATION_ROOT}",
            "canonical mode without Verification/",
        )

        public_missing = sandbox / "public-missing-verification"
        _write_scope_fixture(
            public_missing, _SELF_TEST_PUBLIC_MANIFEST, ("Sources",)
        )
        _expect(
            _scope_paths(public_missing) == ("Sources/Fixture.swift",),
            "public mode rejected a legitimately absent Verification/",
        )

        for label, manifest in (
            ("canonical", _SELF_TEST_CANONICAL_MANIFEST),
            ("public", _SELF_TEST_PUBLIC_MANIFEST),
        ):
            without_sources = sandbox / f"{label}-missing-sources"
            _write_scope_fixture(without_sources, manifest, ())
            _expect_scope_error(
                without_sources,
                "missing policy scope directory: Sources",
                f"{label} mode without Sources/",
            )

        without_manifest = sandbox / "missing-manifest"
        _write_scope_fixture(without_manifest, None, ("Sources",))
        _expect_scope_error(
            without_manifest,
            f"cannot read {PACKAGE_MANIFEST}",
            "checkout without a Package manifest",
        )
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _expect_counts(
    evaluation: Evaluation,
    *,
    new: int,
    removed: int,
    grandfathered: int,
    passed: bool,
    label: str,
) -> None:
    _expect(len(evaluation.new) == new, f"{label}: expected new={new}")
    _expect(evaluation.removed == removed, f"{label}: expected removed={removed}")
    _expect(
        evaluation.grandfathered == grandfathered,
        f"{label}: expected grandfathered={grandfathered}",
    )
    _expect(evaluation.passed == passed, f"{label}: unexpected pass state")


def run_self_test() -> int:
    plain_foo = "final class Foo: @unchecked Sendable {\n}\n"
    invariant_bar = (
        "// Safety invariant: lock-protected state.\n"
        "final class Bar: @unchecked Sendable {\n}\n"
    )
    cases: list[str] = []

    evaluation = evaluate_sources({"main.swift": plain_foo}, {"main.swift": plain_foo})
    _expect_counts(evaluation, new=0, removed=0, grandfathered=1, passed=True, label="A unchanged")
    cases.append("A unchanged")

    evaluation = evaluate_sources({"main.swift": plain_foo}, {"Foo.swift": plain_foo})
    _expect_counts(evaluation, new=0, removed=0, grandfathered=1, passed=True, label="B moved file")
    cases.append("B moved file")

    visibility_base = "fileprivate final class Foo: @unchecked Sendable {\n}\n"
    visibility_head = "internal final class Foo: @unchecked Sendable {\n}\n"
    evaluation = evaluate_sources({"main.swift": visibility_base}, {"Foo.swift": visibility_head})
    _expect_counts(
        evaluation, new=0, removed=0, grandfathered=1, passed=True, label="C visibility"
    )
    cases.append("C visibility-only relocation")

    evaluation = evaluate_sources(
        {"main.swift": plain_foo},
        {"main.swift": plain_foo + "final class Bar: @unchecked Sendable {\n}\n"},
    )
    _expect_counts(
        evaluation, new=1, removed=0, grandfathered=1, passed=False, label="D true new"
    )
    cases.append("D true new without invariant")

    evaluation = evaluate_sources(
        {"main.swift": plain_foo},
        {"main.swift": plain_foo + invariant_bar},
    )
    _expect_counts(
        evaluation, new=1, removed=0, grandfathered=1, passed=True, label="E invariant"
    )
    cases.append("E true new with invariant")

    evaluation = evaluate_sources(
        {"main.swift": plain_foo},
        {"main.swift": "final class Bar: @unchecked Sendable {\n}\n"},
    )
    _expect_counts(
        evaluation, new=1, removed=1, grandfathered=0, passed=False, label="F replacement"
    )
    cases.append("F count-neutral replacement")

    duplicate = plain_foo + plain_foo
    evaluation = evaluate_sources({"main.swift": plain_foo}, {"main.swift": duplicate})
    _expect_counts(
        evaluation, new=1, removed=0, grandfathered=1, passed=False, label="G duplicate"
    )
    cases.append("G duplicate growth")

    evaluation = evaluate_sources({"main.swift": plain_foo}, {})
    _expect_counts(
        evaluation, new=0, removed=1, grandfathered=0, passed=True, label="H removal"
    )
    cases.append("H removal-only change")

    evaluation = evaluate_sources(
        {"main.swift": plain_foo},
        {"main.swift": "final actor Foo: @unchecked Sendable {\n}\n"},
    )
    _expect_counts(
        evaluation, new=1, removed=1, grandfathered=0, passed=False, label="I kind"
    )
    cases.append("I declaration kind change")

    generic_base = "final class Foo<T>: @unchecked Sendable {\n}\n"
    generic_head = "final class Foo<T, U>: @unchecked Sendable {\n}\n"
    evaluation = evaluate_sources(
        {"main.swift": generic_base}, {"main.swift": generic_head}
    )
    _expect_counts(
        evaluation,
        new=1,
        removed=1,
        grandfathered=0,
        passed=False,
        label="generic identity change",
    )
    cases.append("generic identity change")

    conditional_base = (
        "extension Box: @unchecked Sendable where Element: Sendable {\n"
        "}\n"
    )
    evaluation = evaluate_sources(
        {"main.swift": conditional_base}, {"Box.swift": conditional_base}
    )
    _expect_counts(
        evaluation,
        new=0,
        removed=0,
        grandfathered=1,
        passed=True,
        label="K conditional move",
    )
    cases.append("K conditional conformance moved")

    conditional_to_unconditional = "extension Box: @unchecked Sendable {\n}\n"
    evaluation = evaluate_sources(
        {"main.swift": conditional_base},
        {"main.swift": conditional_to_unconditional},
    )
    _expect_counts(
        evaluation,
        new=1,
        removed=1,
        grandfathered=0,
        passed=False,
        label="L conditional to unconditional",
    )
    cases.append("L conditional to unconditional")

    evaluation = evaluate_sources(
        {"main.swift": conditional_to_unconditional},
        {"main.swift": conditional_base},
    )
    _expect_counts(
        evaluation,
        new=1,
        removed=1,
        grandfathered=0,
        passed=False,
        label="M unconditional to conditional",
    )
    cases.append("M unconditional to conditional")

    changed_constraint = conditional_base.replace(
        "Element: Sendable", "Element: Codable"
    )
    evaluation = evaluate_sources(
        {"main.swift": conditional_base}, {"main.swift": changed_constraint}
    )
    _expect_counts(
        evaluation,
        new=1,
        removed=1,
        grandfathered=0,
        passed=False,
        label="N changed where constraint",
    )
    cases.append("N changed where constraint")

    reformatted_constraint = (
        "extension Box: @unchecked Sendable where\n"
        "  Element: Sendable\n"
        "{\n}\n"
    )
    evaluation = evaluate_sources(
        {"main.swift": conditional_base}, {"main.swift": reformatted_constraint}
    )
    _expect_counts(
        evaluation,
        new=0,
        removed=0,
        grandfathered=1,
        passed=True,
        label="O where whitespace",
    )
    cases.append("O where whitespace-only reformat")

    generic_conditional_base = (
        "final class Box<T>: @unchecked Sendable where T: Sendable {\n}\n"
    )
    generic_conditional_head = generic_conditional_base.replace(
        "T: Sendable", "T: Codable"
    )
    evaluation = evaluate_sources(
        {"main.swift": generic_conditional_base},
        {"main.swift": generic_conditional_head},
    )
    _expect_counts(
        evaluation,
        new=1,
        removed=1,
        grandfathered=0,
        passed=False,
        label="P generic nominal where",
    )
    cases.append("P generic nominal trailing where change")

    try:
        evaluate_sources(
            {},
            {"main.swift": "extension Box: @unchecked Sendable where {\n}\n"},
        )
    except ParseError:
        cases.append("unparseable where boundary")
    else:
        raise AssertionError("unparseable where boundary unexpectedly passed")

    try:
        evaluate_sources({}, {"main.swift": "@unchecked Sendable\n"})
    except ParseError:
        cases.append("J unparseable declaration")
    else:
        raise AssertionError("J unparseable declaration unexpectedly passed")

    hidden_text = (
        "// @unchecked Sendable\n"
        "let text = \"@unchecked Sendable\"\n"
    )
    _expect(not parse_source(hidden_text, "hidden.swift"), "comment/string marker leaked")
    cases.append("comments and strings ignored")

    nested = "struct Outer {\n  final class Foo: @unchecked Sendable {\n  }\n}\n"
    qualified_head = nested.replace(
        "final class Foo", "// Safety invariant: lock-protected.\n  final class Foo"
    )
    evaluation = evaluate_sources({"main.swift": plain_foo}, {"main.swift": qualified_head})
    _expect_counts(
        evaluation, new=1, removed=1, grandfathered=0, passed=True, label="qualified"
    )
    _expect(
        evaluation.new[0].identity.qualified_name == "Outer.Foo",
        "qualified context did not distinguish Outer.Foo",
    )
    cases.append("qualified lexical context")

    extension_foo = "extension Foo: @unchecked Sendable {\n}\n"
    extension_outer = "extension Outer.Foo: @unchecked Sendable {\n}\n"
    evaluation = evaluate_sources(
        {"main.swift": extension_foo},
        {"main.swift": "// Safety invariant: serialized by owner.\n" + extension_outer},
    )
    _expect_counts(
        evaluation, new=1, removed=1, grandfathered=0, passed=True, label="extension target"
    )
    _expect(
        evaluation.new[0].identity.qualified_name == "Outer.Foo",
        "extension target qualification was not preserved",
    )
    cases.append("qualified extension target")

    try:
        evaluate_sources(
            {},
            {"main.swift": "let make = { final class Foo: @unchecked Sendable {} }\n"},
        )
    except ParseError:
        cases.append("ambiguous closure scope")
    else:
        raise AssertionError("ambiguous closure scope unexpectedly passed")

    try:
        evaluate_sources(
            {},
            {
                "main.swift": (
                    "let value = Thing.init { "
                    "final class Foo: @unchecked Sendable {} }\n"
                )
            },
        )
    except ParseError:
        cases.append("member initializer closure scope")
    else:
        raise AssertionError("member initializer closure scope unexpectedly passed")

    try:
        evaluate_sources(
            {},
            {
                "main.swift": (
                    "let `func` = { final class Foo: @unchecked Sendable {} }\n"
                )
            },
        )
    except ParseError:
        cases.append("escaped keyword closure scope")
    else:
        raise AssertionError("escaped keyword closure scope unexpectedly passed")

    named_local = "func make() { final class Foo: @unchecked Sendable {} }\n"
    evaluation = evaluate_sources(
        {"main.swift": named_local}, {"moved.swift": named_local}
    )
    _expect_counts(
        evaluation, new=0, removed=0, grandfathered=1, passed=True, label="named scope"
    )
    _expect(
        evaluation.current[0].identity.qualified_name == "<function:func make ( )>.Foo",
        "named function scope was not retained in identity",
    )
    cases.append("named lexical scope")

    conditional_local = (
        "import Foundation\n"
        "#if DEBUG\n"
        "func make() { final class Foo: @unchecked Sendable {} }\n"
        "#endif\n"
    )
    evaluation = evaluate_sources(
        {"main.swift": conditional_local}, {"moved.swift": conditional_local}
    )
    _expect_counts(
        evaluation,
        new=0,
        removed=0,
        grandfathered=1,
        passed=True,
        label="import and conditional function scope",
    )
    cases.append("import and conditional function scope")

    overloaded_base = (
        "func f(_ x: Int) { final class Foo: @unchecked Sendable {} }\n"
        "func f(_ x: String) { final class Foo: @unchecked Sendable {} }\n"
    )
    overloaded_head = (
        "func f(_ x: Int) { final class Foo: @unchecked Sendable {} }\n"
        "func f(_ x: Bool) { final class Foo: @unchecked Sendable {} }\n"
    )
    evaluation = evaluate_sources(
        {"main.swift": overloaded_base}, {"main.swift": overloaded_head}
    )
    _expect_counts(
        evaluation,
        new=1,
        removed=1,
        grandfathered=1,
        passed=False,
        label="overloaded function scopes",
    )
    _expect(
        evaluation.new[0].identity.qualified_name
        == "<function:func f ( _ x : Bool )>.Foo",
        "function signature was not retained in identity",
    )
    cases.append("overloaded function scopes")

    declaration_boundary = (
        "func first()\n"
        "func second() { final class Foo: @unchecked Sendable {} }\n"
    )
    evaluation = evaluate_sources(
        {"main.swift": declaration_boundary},
        {"moved.swift": declaration_boundary},
    )
    _expect_counts(
        evaluation,
        new=0,
        removed=0,
        grandfathered=1,
        passed=True,
        label="function body boundary",
    )
    _expect(
        evaluation.current[0].identity.qualified_name
        == "<function:func second ( )>.Foo",
        "bodyless function borrowed a later declaration body",
    )
    cases.append("function body declaration boundary")

    _run_scope_mode_self_test()
    cases.append("scope roots are mode-aware and fail closed")

    print("Concurrency policy self-test:")
    for case in cases:
        print(f"PASS {case}")
    print("CONCURRENCY_POLICY_SELF_TEST_PASS")
    return 0


def run_policy() -> int:
    try:
        baseline_files = _read_baseline_sources()
        current_files = _read_current_sources()
        evaluation = evaluate_sources(baseline_files, current_files)
    except PolicyError as error:
        print(f"Concurrency policy FAIL_CLOSED: {error}", file=sys.stderr)
        return 2

    print(_display_report(evaluation))
    return 1 if evaluation.findings else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run in-memory parser and multiset fixtures without Git",
    )
    arguments = parser.parse_args()
    if arguments.self_test:
        try:
            return run_self_test()
        except (AssertionError, PolicyError) as error:
            print(f"Concurrency policy self-test failed: {error}", file=sys.stderr)
            return 1
    return run_policy()


if __name__ == "__main__":
    raise SystemExit(main())
