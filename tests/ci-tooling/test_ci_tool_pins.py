#!/usr/bin/env python3
"""Fail-closed contracts for tools installed by production workflows."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).parents[2]
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
DEPENDABOT = ROOT / ".github" / "dependabot.yml"
REQUIREMENTS_INPUT = ROOT / "tests" / "ci-tooling" / "requirements.in"
REQUIREMENTS_LOCK = ROOT / "tests" / "ci-tooling" / "requirements.txt"
EXPECTED_CARGO_EDIT = "0.13.13"


def load_yaml(path: Path) -> dict[object, object]:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise AssertionError(f"{path} must contain a YAML mapping")
    return document


def named_step(workflow: dict[object, object], job: str, name: str) -> dict[object, object]:
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        raise AssertionError("workflow must contain a jobs mapping")
    job_definition = jobs.get(job)
    if not isinstance(job_definition, dict):
        raise AssertionError(f"workflow must contain job {job!r}")
    steps = job_definition.get("steps")
    if not isinstance(steps, list):
        raise AssertionError(f"job {job!r} must contain a steps list")
    matches = [step for step in steps if isinstance(step, dict) and step.get("name") == name]
    if len(matches) != 1:
        raise AssertionError(f"expected exactly one {name!r} step, found {len(matches)}")
    return matches[0]


class CiToolPinTests(unittest.TestCase):
    def test_yamllint_install_uses_hashed_lock(self) -> None:
        workflow = load_yaml(CI_WORKFLOW)
        install = named_step(workflow, "yaml-lint", "Install yamllint")
        self.assertEqual(
            install.get("run"),
            "python -m pip install --require-hashes --only-binary=:all: "
            "-r tests/ci-tooling/requirements.txt",
        )

        text = CI_WORKFLOW.read_text(encoding="utf-8")
        self.assertNotRegex(text, r"(?m)^\s*run:\s*pip install yamllint\s*$")
        setup_python = next(
            step
            for step in workflow["jobs"]["yaml-lint"]["steps"]
            if isinstance(step, dict) and str(step.get("uses", "")).startswith("actions/setup-python@")
        )
        self.assertEqual(setup_python.get("with", {}).get("python-version"), "3.14")

    def test_yamllint_lock_is_exact_and_hashed(self) -> None:
        input_text = REQUIREMENTS_INPUT.read_text(encoding="utf-8")
        match = re.search(r"(?m)^yamllint==([0-9]+\.[0-9]+\.[0-9]+)\s*$", input_text)
        self.assertIsNotNone(match, "requirements.in must pin one exact yamllint version")
        expected_version = match.group(1)

        lock_text = REQUIREMENTS_LOCK.read_text(encoding="utf-8")
        self.assertNotIn("--index-url", lock_text)
        effective_lines = [
            line
            for line in lock_text.splitlines()
            if line.strip()
            and not line.lstrip().startswith("#")
            and not line.lstrip().startswith("--hash=")
        ]
        for line in effective_lines:
            self.assertRegex(
                line,
                r"^[A-Za-z0-9_.-]+==[^\s\\]+\s+\\$",
                "every locked requirement must use one exact version",
            )
        package_starts = list(
            re.finditer(r"(?m)^([A-Za-z0-9_.-]+)==([^\s\\]+)(?:\s+\\)?$", lock_text)
        )
        self.assertEqual(len(package_starts), len(effective_lines))
        self.assertGreater(len(package_starts), 0, "requirements lock must contain packages")
        locked_versions = {match.group(1).lower(): match.group(2) for match in package_starts}
        self.assertEqual(locked_versions.get("yamllint"), expected_version)

        for index, package in enumerate(package_starts):
            block_end = (
                package_starts[index + 1].start()
                if index + 1 < len(package_starts)
                else len(lock_text)
            )
            block = lock_text[package.start() : block_end]
            self.assertRegex(
                block,
                r"--hash=sha256:[0-9a-f]{64}",
                f"{package.group(1)} must have a SHA-256 artifact hash",
            )

    def test_dependabot_tracks_ci_python_lock(self) -> None:
        config = load_yaml(DEPENDABOT)
        updates = config.get("updates")
        self.assertIsInstance(updates, list)
        matches = [
            update
            for update in updates
            if isinstance(update, dict)
            and update.get("package-ecosystem") == "pip"
            and update.get("directory") == "/tests/ci-tooling"
        ]
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0].get("schedule", {}).get("interval"), "weekly")

    def test_cargo_edit_install_is_exact_and_locked(self) -> None:
        workflow = load_yaml(RELEASE_WORKFLOW)
        install = named_step(workflow, "release", "Install cargo-edit")
        self.assertEqual(
            install.get("run"),
            f"cargo install cargo-edit --version {EXPECTED_CARGO_EDIT} --locked",
        )

        text = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.assertNotRegex(
            text,
            r"(?m)^\s*run:\s*cargo install cargo-edit --locked\s*$",
        )


if __name__ == "__main__":
    unittest.main()
