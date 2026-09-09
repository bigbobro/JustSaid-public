#!/usr/bin/env python3
"""Fail cheap Linux CI when a workflow can spend macOS minutes accidentally.

The checker is fail-closed on two explicit topologies:

- private_canonical: common public-safe workflows plus private-only
  full-validation and macos-smoke
- sanitized_public: only the exported public-safe workflows

Mixed or incomplete workflow sets are rejected. Mode is inferred from
files on disk, never from a repository name.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import sys
import tempfile


WORKFLOW_DIR = Path(".github/workflows")
FULL_MACOS_TIMEOUT_LIMIT = 45
SMOKE_MACOS_TIMEOUT_LIMIT = 20
PUBLIC_RUNNER_SMOKE_TIMEOUT_LIMIT = 10

CI_MODE_PRIVATE_CANONICAL = "private_canonical"
CI_MODE_SANITIZED_PUBLIC = "sanitized_public"

COMMON_REQUIRED_WORKFLOWS = (
    "pr-validation.yml",
    "public-policy.yml",
    "public-runner-smoke.yml",
)
PRIVATE_ONLY_WORKFLOWS = (
    "full-validation.yml",
    "macos-smoke.yml",
)
AUTOMATIC_TRIGGERS = ("pull_request", "push", "schedule")
HEAVY_PUBLIC_SMOKE_COMMANDS = ("swift build", "swift run", "xcodebuild")
FULL_VALIDATION_RELEASE_BUILD = "swift build -c release --product JustSaid"


class PolicyError(Exception):
    """CI cost policy violation."""


def fail(message: str) -> None:
    raise PolicyError(message)


def workflow_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read {path.name}: {error.strerror or error.__class__.__name__}")
    raise AssertionError("unreachable")


def timeout_values(text: str) -> list[int]:
    return [
        int(value)
        for value in re.findall(r"(?m)^\s*timeout-minutes:\s*(\d+)\s*$", text)
    ]


def require_timeout_ceiling(path: Path, text: str, ceiling: int) -> None:
    values = timeout_values(text)
    if not values:
        fail(f"{path.name} has no timeout-minutes hard ceiling")
    maximum = max(values)
    if maximum > ceiling:
        fail(f"{path.name} allows {maximum} macOS minutes; policy ceiling is {ceiling}")


def has_trigger(text: str, trigger: str) -> bool:
    return re.search(rf"(?m)^\s{{2}}{re.escape(trigger)}:\s*$", text) is not None


def uses_macos(text: str) -> bool:
    return "runs-on: macos" in text


def workflow_names(workflow_dir: Path) -> set[str]:
    return {path.name for path in workflow_paths(workflow_dir)}


def workflow_paths(workflow_dir: Path) -> list[Path]:
    return sorted([*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")])


def classify_ci_mode(workflow_dir: Path) -> str:
    if not workflow_dir.is_dir():
        fail("missing workflow directory")
    names = workflow_names(workflow_dir)
    if not names:
        fail("no GitHub Actions workflows found")
    common_present = all(name in names for name in COMMON_REQUIRED_WORKFLOWS)
    private_present = {name for name in PRIVATE_ONLY_WORKFLOWS if name in names}
    if common_present and private_present == set(PRIVATE_ONLY_WORKFLOWS):
        return CI_MODE_PRIVATE_CANONICAL
    if common_present and not private_present:
        return CI_MODE_SANITIZED_PUBLIC
    fail("CI workflow topology is ambiguous")
    raise AssertionError("unreachable")


def require_manual_macos(path: Path, text: str) -> None:
    for automatic_trigger in AUTOMATIC_TRIGGERS:
        if has_trigger(text, automatic_trigger):
            fail(
                f"{path.name} assigns a macOS runner from automatic "
                f"{automatic_trigger} events; macOS workflows must be "
                "workflow_dispatch-only"
            )
    if "workflow_dispatch:" not in text:
        fail(f"{path.name} uses macOS but is not manually dispatchable")


def validate_generic_macos_workflows(workflow_dir: Path) -> None:
    for path in workflow_paths(workflow_dir):
        text = workflow_text(path)
        if not uses_macos(text):
            continue
        require_manual_macos(path, text)


def validate_pr_validation(workflow_dir: Path) -> None:
    path = workflow_dir / "pr-validation.yml"
    text = workflow_text(path)
    if uses_macos(text):
        fail("automatic PR validation must remain on Linux")
    if has_trigger(text, "push"):
        fail("PR hygiene must not duplicate pull_request checks on every branch push")


def validate_public_policy(workflow_dir: Path) -> None:
    path = workflow_dir / "public-policy.yml"
    text = workflow_text(path)
    if uses_macos(text):
        fail("public-policy.yml must remain on Linux")


def validate_public_runner_smoke(workflow_dir: Path) -> None:
    path = workflow_dir / "public-runner-smoke.yml"
    text = workflow_text(path)
    if not uses_macos(text):
        fail("public-runner-smoke.yml must use a macOS runner")
    require_manual_macos(path, text)
    require_timeout_ceiling(path, text, PUBLIC_RUNNER_SMOKE_TIMEOUT_LIMIT)
    for command in HEAVY_PUBLIC_SMOKE_COMMANDS:
        if command in text:
            fail("public-runner-smoke.yml must not run heavy build commands")


def validate_full_validation(workflow_dir: Path) -> None:
    path = workflow_dir / "full-validation.yml"
    text = workflow_text(path)
    if "workflow_dispatch:" not in text:
        fail("full macOS validation must remain manually dispatchable")
    if has_trigger(text, "push"):
        fail("full macOS validation must not run from push events")
    if FULL_VALIDATION_RELEASE_BUILD not in text:
        fail("release validation must build only the JustSaid product")
    require_timeout_ceiling(path, text, FULL_MACOS_TIMEOUT_LIMIT)


def validate_private_macos_smoke(workflow_dir: Path) -> None:
    path = workflow_dir / "macos-smoke.yml"
    text = workflow_text(path)
    if "workflow_dispatch:" not in text:
        fail("macOS smoke validation must remain manually dispatchable")
    for automatic_trigger in AUTOMATIC_TRIGGERS:
        if has_trigger(text, automatic_trigger):
            fail("macOS smoke validation must be manual-only")
    require_timeout_ceiling(path, text, SMOKE_MACOS_TIMEOUT_LIMIT)


def evaluate(workflow_dir: Path) -> str:
    mode = classify_ci_mode(workflow_dir)
    validate_generic_macos_workflows(workflow_dir)
    validate_pr_validation(workflow_dir)
    validate_public_policy(workflow_dir)
    validate_public_runner_smoke(workflow_dir)
    if mode == CI_MODE_PRIVATE_CANONICAL:
        validate_full_validation(workflow_dir)
        validate_private_macos_smoke(workflow_dir)
    return mode


def _write_workflow(directory: Path, name: str, text: str) -> None:
    path = directory / name
    path.write_text(text, encoding="utf-8")


def _linux_pr_validation() -> str:
    return """name: PR hygiene
on:
  pull_request:
  workflow_dispatch:
jobs:
  hygiene:
    runs-on: ubuntu-latest
    timeout-minutes: 8
    steps:
      - run: true
"""


def _linux_public_policy() -> str:
    return """name: Public policy
on:
  pull_request:
  workflow_dispatch:
jobs:
  policy:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: true
"""


def _public_runner_smoke(*, timeout: int = 5, extra_on: str = "", extra_run: str = "") -> str:
    on_block = "  workflow_dispatch:\n"
    if extra_on:
        on_block += extra_on
    run_block = "      - run: sw_vers\n      - run: swift --version\n"
    if extra_run:
        run_block += extra_run
    return f"""name: Public macOS runner smoke
on:
{on_block}jobs:
  smoke:
    runs-on: macos-26
    timeout-minutes: {timeout}
    steps:
{run_block}"""


def _full_validation(*, timeout: int = 45, extra_on: str = "", release_build: str | None = None) -> str:
    on_block = "  workflow_dispatch:\n"
    if extra_on:
        on_block += extra_on
    build = FULL_VALIDATION_RELEASE_BUILD if release_build is None else release_build
    return f"""name: Full validation
on:
{on_block}jobs:
  full-gate:
    runs-on: macos-26
    timeout-minutes: {timeout}
    steps:
      - run: {build}
"""


def _macos_smoke(*, timeout: int = 20, extra_on: str = "") -> str:
    on_block = "  workflow_dispatch:\n"
    if extra_on:
        on_block += extra_on
    return f"""name: Targeted macOS smoke
on:
{on_block}jobs:
  smoke:
    runs-on: macos-26
    timeout-minutes: {timeout}
    steps:
      - run: true
"""


def _expect_policy_error(workflow_dir: Path, fragment: str) -> None:
    try:
        evaluate(workflow_dir)
    except PolicyError as error:
        if fragment not in str(error):
            raise PolicyError(
                f"self-test mismatch: expected {fragment!r} in {error}"
            ) from error
        return
    raise PolicyError(f"expected policy rejection ({fragment})")


def run_self_test() -> int:
    root = Path(tempfile.mkdtemp(prefix="justsaid-ci-cost-self-test-"))
    try:
        private = root / "private"
        private.mkdir()
        _write_workflow(private, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(private, "public-policy.yml", _linux_public_policy())
        _write_workflow(private, "public-runner-smoke.yml", _public_runner_smoke())
        _write_workflow(private, "full-validation.yml", _full_validation())
        _write_workflow(private, "macos-smoke.yml", _macos_smoke())
        if evaluate(private) != CI_MODE_PRIVATE_CANONICAL:
            fail("expected private_canonical")

        public = root / "public"
        public.mkdir()
        _write_workflow(public, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(public, "public-policy.yml", _linux_public_policy())
        _write_workflow(public, "public-runner-smoke.yml", _public_runner_smoke())
        if evaluate(public) != CI_MODE_SANITIZED_PUBLIC:
            fail("expected sanitized_public")

        only_full = root / "only-full"
        only_full.mkdir()
        _write_workflow(only_full, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(only_full, "public-policy.yml", _linux_public_policy())
        _write_workflow(only_full, "public-runner-smoke.yml", _public_runner_smoke())
        _write_workflow(only_full, "full-validation.yml", _full_validation())
        _expect_policy_error(only_full, "CI workflow topology is ambiguous")

        only_smoke = root / "only-smoke"
        only_smoke.mkdir()
        _write_workflow(only_smoke, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(only_smoke, "public-policy.yml", _linux_public_policy())
        _write_workflow(only_smoke, "public-runner-smoke.yml", _public_runner_smoke())
        _write_workflow(only_smoke, "macos-smoke.yml", _macos_smoke())
        _expect_policy_error(only_smoke, "CI workflow topology is ambiguous")

        missing_common = root / "missing-common"
        missing_common.mkdir()
        _write_workflow(missing_common, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(missing_common, "public-policy.yml", _linux_public_policy())
        _write_workflow(missing_common, "full-validation.yml", _full_validation())
        _write_workflow(missing_common, "macos-smoke.yml", _macos_smoke())
        _expect_policy_error(missing_common, "CI workflow topology is ambiguous")

        auto_push = root / "auto-push"
        auto_push.mkdir()
        _write_workflow(auto_push, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(auto_push, "public-policy.yml", _linux_public_policy())
        _write_workflow(
            auto_push,
            "public-runner-smoke.yml",
            _public_runner_smoke(extra_on="  push:\n"),
        )
        _expect_policy_error(auto_push, "automatic push")

        long_timeout = root / "long-timeout"
        long_timeout.mkdir()
        _write_workflow(long_timeout, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(long_timeout, "public-policy.yml", _linux_public_policy())
        _write_workflow(
            long_timeout,
            "public-runner-smoke.yml",
            _public_runner_smoke(timeout=15),
        )
        _expect_policy_error(long_timeout, "policy ceiling is 10")

        surprise = root / "surprise-macos"
        surprise.mkdir()
        _write_workflow(surprise, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(surprise, "public-policy.yml", _linux_public_policy())
        _write_workflow(surprise, "public-runner-smoke.yml", _public_runner_smoke())
        _write_workflow(
            surprise,
            "hidden-macos.yml",
            """name: Hidden
on:
  pull_request:
jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 5
    steps:
      - run: true
""",
        )
        _expect_policy_error(surprise, "automatic pull_request")

        drifted_full = root / "drifted-full"
        drifted_full.mkdir()
        _write_workflow(drifted_full, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(drifted_full, "public-policy.yml", _linux_public_policy())
        _write_workflow(drifted_full, "public-runner-smoke.yml", _public_runner_smoke())
        _write_workflow(
            drifted_full,
            "full-validation.yml",
            _full_validation(release_build="swift build -c release"),
        )
        _write_workflow(drifted_full, "macos-smoke.yml", _macos_smoke())
        _expect_policy_error(
            drifted_full, "release validation must build only the JustSaid product"
        )

        auto_full = root / "auto-full"
        auto_full.mkdir()
        _write_workflow(auto_full, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(auto_full, "public-policy.yml", _linux_public_policy())
        _write_workflow(auto_full, "public-runner-smoke.yml", _public_runner_smoke())
        _write_workflow(
            auto_full,
            "full-validation.yml",
            _full_validation(extra_on="  push:\n"),
        )
        _write_workflow(auto_full, "macos-smoke.yml", _macos_smoke())
        _expect_policy_error(auto_full, "automatic push")

        long_full = root / "long-full"
        long_full.mkdir()
        _write_workflow(long_full, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(long_full, "public-policy.yml", _linux_public_policy())
        _write_workflow(long_full, "public-runner-smoke.yml", _public_runner_smoke())
        _write_workflow(long_full, "full-validation.yml", _full_validation(timeout=46))
        _write_workflow(long_full, "macos-smoke.yml", _macos_smoke())
        _expect_policy_error(long_full, "policy ceiling is 45")

        auto_private_smoke = root / "auto-private-smoke"
        auto_private_smoke.mkdir()
        _write_workflow(auto_private_smoke, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(auto_private_smoke, "public-policy.yml", _linux_public_policy())
        _write_workflow(
            auto_private_smoke, "public-runner-smoke.yml", _public_runner_smoke()
        )
        _write_workflow(auto_private_smoke, "full-validation.yml", _full_validation())
        _write_workflow(
            auto_private_smoke,
            "macos-smoke.yml",
            _macos_smoke(extra_on="  pull_request:\n"),
        )
        _expect_policy_error(auto_private_smoke, "automatic pull_request")

        long_private_smoke = root / "long-private-smoke"
        long_private_smoke.mkdir()
        _write_workflow(long_private_smoke, "pr-validation.yml", _linux_pr_validation())
        _write_workflow(long_private_smoke, "public-policy.yml", _linux_public_policy())
        _write_workflow(
            long_private_smoke, "public-runner-smoke.yml", _public_runner_smoke()
        )
        _write_workflow(long_private_smoke, "full-validation.yml", _full_validation())
        _write_workflow(long_private_smoke, "macos-smoke.yml", _macos_smoke(timeout=21))
        _expect_policy_error(long_private_smoke, "policy ceiling is 20")

        print("CI_COST_POLICY_SELF_TEST_PASS")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run discriminative topology fixtures without network access",
    )
    parser.add_argument(
        "--workflow-dir",
        type=Path,
        default=WORKFLOW_DIR,
        help="workflow directory to check (default: .github/workflows)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        if args.self_test:
            return run_self_test()
        mode = evaluate(args.workflow_dir)
        if mode == CI_MODE_PRIVATE_CANONICAL:
            detail = (
                f"full <= {FULL_MACOS_TIMEOUT_LIMIT}m, "
                f"macos-smoke <= {SMOKE_MACOS_TIMEOUT_LIMIT}m, "
                f"public-runner-smoke <= {PUBLIC_RUNNER_SMOKE_TIMEOUT_LIMIT}m"
            )
        else:
            detail = (
                f"public-runner-smoke <= {PUBLIC_RUNNER_SMOKE_TIMEOUT_LIMIT}m; "
                "private full-validation workflows are absent"
            )
        print(
            "CI cost policy passed: "
            f"mode={mode}; automatic checks use Linux; "
            f"macOS is workflow_dispatch-only; {detail}."
        )
        return 0
    except PolicyError as error:
        print(f"CI cost policy violation: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
