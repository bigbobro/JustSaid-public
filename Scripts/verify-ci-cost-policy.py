#!/usr/bin/env python3
"""Fail cheap Linux CI when a workflow can spend macOS minutes accidentally.

The private canonical repository and the sanitized public repository carry
the same two Linux workflows, pr-validation and public-policy. Any workflow
that asks for a macOS runner must be workflow_dispatch-only and declare a
timeout-minutes hard ceiling.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import sys
import tempfile


WORKFLOW_DIR = Path(".github/workflows")
MACOS_TIMEOUT_LIMIT = 45

REQUIRED_WORKFLOWS = (
    "pr-validation.yml",
    "public-policy.yml",
)
AUTOMATIC_TRIGGERS = ("pull_request", "push", "schedule")


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


def workflow_paths(workflow_dir: Path) -> list[Path]:
    return sorted([*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")])


def require_workflows_present(workflow_dir: Path) -> None:
    if not workflow_dir.is_dir():
        fail("missing workflow directory")
    names = {path.name for path in workflow_paths(workflow_dir)}
    missing = [name for name in REQUIRED_WORKFLOWS if name not in names]
    if missing:
        fail(f"missing required workflow: {', '.join(missing)}")


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


def validate_macos_workflows(workflow_dir: Path) -> None:
    for path in workflow_paths(workflow_dir):
        text = workflow_text(path)
        if not uses_macos(text):
            continue
        require_manual_macos(path, text)
        require_timeout_ceiling(path, text, MACOS_TIMEOUT_LIMIT)


def validate_pr_validation(workflow_dir: Path) -> None:
    text = workflow_text(workflow_dir / "pr-validation.yml")
    if has_trigger(text, "push"):
        fail("PR hygiene must not duplicate pull_request checks on every branch push")


def evaluate(workflow_dir: Path) -> None:
    require_workflows_present(workflow_dir)
    validate_macos_workflows(workflow_dir)
    validate_pr_validation(workflow_dir)


def _write_workflow(directory: Path, name: str, text: str) -> None:
    path = directory / name
    path.write_text(text, encoding="utf-8")


def _linux_pr_validation(*, extra_on: str = "") -> str:
    return f"""name: PR hygiene
on:
  pull_request:
{extra_on}  workflow_dispatch:
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


def _macos_workflow(*, timeout: int | None = 20, extra_on: str = "") -> str:
    timeout_line = "" if timeout is None else f"    timeout-minutes: {timeout}\n"
    return f"""name: macOS check
on:
  workflow_dispatch:
{extra_on}jobs:
  check:
    runs-on: macos-26
{timeout_line}    steps:
      - run: true
"""


def _baseline(root: Path, name: str) -> Path:
    directory = root / name
    directory.mkdir()
    _write_workflow(directory, "pr-validation.yml", _linux_pr_validation())
    _write_workflow(directory, "public-policy.yml", _linux_public_policy())
    return directory


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
        evaluate(_baseline(root, "baseline"))

        missing = root / "missing-public-policy"
        missing.mkdir()
        _write_workflow(missing, "pr-validation.yml", _linux_pr_validation())
        _expect_policy_error(missing, "missing required workflow: public-policy.yml")

        auto_pr = _baseline(root, "macos-on-pull-request")
        _write_workflow(auto_pr, "hidden-macos.yml", _macos_workflow(extra_on="  pull_request:\n"))
        _expect_policy_error(auto_pr, "automatic pull_request")

        auto_push = _baseline(root, "macos-on-push")
        _write_workflow(auto_push, "hidden-macos.yml", _macos_workflow(extra_on="  push:\n"))
        _expect_policy_error(auto_push, "automatic push")

        no_timeout = _baseline(root, "macos-without-timeout")
        _write_workflow(no_timeout, "manual-macos.yml", _macos_workflow(timeout=None))
        _expect_policy_error(no_timeout, "has no timeout-minutes hard ceiling")

        long_timeout = _baseline(root, "macos-long-timeout")
        _write_workflow(long_timeout, "manual-macos.yml", _macos_workflow(timeout=46))
        _expect_policy_error(long_timeout, "policy ceiling is 45")

        at_ceiling = _baseline(root, "macos-at-ceiling")
        _write_workflow(at_ceiling, "manual-macos.yml", _macos_workflow(timeout=45))
        evaluate(at_ceiling)

        pr_push = root / "pr-validation-on-push"
        pr_push.mkdir()
        _write_workflow(pr_push, "pr-validation.yml", _linux_pr_validation(extra_on="  push:\n"))
        _write_workflow(pr_push, "public-policy.yml", _linux_public_policy())
        _expect_policy_error(pr_push, "must not duplicate pull_request checks")

        print("CI_COST_POLICY_SELF_TEST_PASS")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run discriminative policy fixtures without network access",
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
        evaluate(args.workflow_dir)
        print(
            "CI cost policy passed: automatic checks use Linux; "
            "any macOS workflow is workflow_dispatch-only with "
            f"timeout <= {MACOS_TIMEOUT_LIMIT}m."
        )
        return 0
    except PolicyError as error:
        print(f"CI cost policy violation: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
