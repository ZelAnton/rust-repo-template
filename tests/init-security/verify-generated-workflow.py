#!/usr/bin/env python3
"""Verify generated release identity data and execute its commit step safely."""

from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import subprocess
import sys

try:
    import yaml
except ImportError as error:  # yamllint installs the same parser in CI.
    raise SystemExit("PyYAML is required (install yamllint or pyyaml)") from error


def run(arguments: list[str], cwd: Path, *, env: dict[str, str] | None = None) -> None:
    result = subprocess.run(
        arguments,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise AssertionError(
            f"command failed ({result.returncode}): {arguments!r}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


def output(arguments: list[str], cwd: Path) -> str:
    return subprocess.check_output(arguments, cwd=cwd, text=True, encoding="utf-8")


def decode_identity(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise AssertionError(f"{label} must be a YAML string")
    try:
        encoded = value.encode("ascii")
        return base64.b64decode(encoded, validate=True).decode("utf-8")
    except (UnicodeError, ValueError) as error:
        raise AssertionError(f"{label} is not canonical UTF-8 Base64") from error


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--bash", required=True)
    parser.add_argument("--expected-name", required=True)
    parser.add_argument("--expected-email", required=True)
    args = parser.parse_args()

    repo = args.repo.resolve()
    workflow_path = repo / ".github" / "workflows" / "release.yml"
    workflow_text = workflow_path.read_text(encoding="utf-8")
    workflow = yaml.safe_load(workflow_text)
    steps = workflow["jobs"]["release"]["steps"]
    step = next(item for item in steps if item.get("name") == "Commit version bump + changelog")
    step_env = step["env"]
    script = step["run"]

    name_key = "RELEASE_GIT_AUTHOR_NAME_B64"
    email_key = "RELEASE_GIT_AUTHOR_EMAIL_B64"
    actual_name = decode_identity(step_env.get(name_key), name_key)
    actual_email = decode_identity(step_env.get(email_key), email_key)
    if actual_name != args.expected_name:
        raise AssertionError(f"release author name changed: {actual_name!r}")
    if actual_email != args.expected_email:
        raise AssertionError(f"release author email changed: {actual_email!r}")
    if args.expected_name in workflow_text or args.expected_email in workflow_text:
        raise AssertionError("raw release identity leaked into generated workflow source")
    if "__Author__" in workflow_text or "__AuthorEmail__" in workflow_text:
        raise AssertionError("release identity placeholder remained unresolved")

    required_fragments = (
        "set -euo pipefail",
        'git config user.name "$release_git_author_name"',
        'git config user.email "$release_git_author_email"',
    )
    for fragment in required_fragments:
        if fragment not in script:
            raise AssertionError(f"release commit step lost safe fragment: {fragment}")

    name_marker = repo / "init-security-name-owned"
    email_marker = repo / "init-security-email-owned"
    run(["git", "init", "-q"], repo)
    run(["git", "config", "commit.gpgsign", "false"], repo)
    run(["git", "add", "Cargo.toml", "Cargo.lock", "CHANGELOG.md"], repo)
    run(
        [
            "git",
            "-c",
            "user.name=Initializer Security Baseline",
            "-c",
            "user.email=baseline@example.com",
            "commit",
            "-qm",
            "baseline",
        ],
        repo,
    )
    with (repo / "CHANGELOG.md").open("a", encoding="utf-8", newline="\n") as changelog:
        changelog.write("\n<!-- init-security release change -->\n")

    environment = os.environ.copy()
    environment.update(
        {
            "VERSION": "9.9.9",
            name_key: str(step_env[name_key]),
            email_key: str(step_env[email_key]),
        }
    )
    run([args.bash, "-c", script], repo, env=environment)

    if name_marker.exists() or email_marker.exists():
        raise AssertionError("release identity executed a shell side effect")
    configured_name = output(["git", "config", "--get", "user.name"], repo).rstrip("\n")
    configured_email = output(["git", "config", "--get", "user.email"], repo).rstrip("\n")
    if configured_name != args.expected_name or configured_email != args.expected_email:
        raise AssertionError("git config did not preserve the release identity exactly")
    commit_identity = subprocess.check_output(
        ["git", "log", "-1", "--format=%an%x00%ae"], cwd=repo
    ).removesuffix(b"\n")
    expected_identity = f"{args.expected_name}\0{args.expected_email}".encode("utf-8")
    if commit_identity != expected_identity:
        raise AssertionError(
            f"release commit identity changed: {commit_identity!r} != {expected_identity!r}"
        )


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, StopIteration, TypeError, yaml.YAMLError) as error:
        print(f"init-security verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
