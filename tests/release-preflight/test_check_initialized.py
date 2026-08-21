from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_initialized.py")
WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "release.yml"


def token(name: str) -> str:
    return "__" + name + "__"


def workflow_run_script(step_name: str) -> str:
    """Return one inline ``run:`` command or literal ``run: |`` block."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    marker = f"      - name: {step_name}"
    try:
        step_index = lines.index(marker)
    except ValueError as error:
        raise AssertionError(f"could not find workflow step {step_name!r}") from error

    run_line = lines[step_index + 1]
    inline_prefix = "        run: "
    if run_line.startswith(inline_prefix) and run_line != "        run: |":
        return run_line[len(inline_prefix) :] + "\n"
    if run_line != "        run: |":
        raise AssertionError(f"workflow step {step_name!r} has no adjacent run command")

    script_lines: list[str] = []
    for line in lines[step_index + 2 :]:
        if line and len(line) - len(line.lstrip(" ")) < 10:
            break
        script_lines.append(line[10:] if line else "")
    return "\n".join(script_lines) + "\n"


def write_fixture(root: Path, *, initialized: bool) -> None:
    workflow_directory = root / ".github" / "workflows"
    workflow_directory.mkdir(parents=True)

    if initialized:
        name = "example-crate"
        description = "An initialized fixture"
        owner = "example-org"
        author = "RXhhbXBsZSBBdXRob3I="
        author_email = "YXV0aG9yQGV4YW1wbGUuaW52YWxpZA=="
        year = "2026"
    else:
        name = token("ProjectName")
        description = token("Description")
        owner = token("GitHubOwner")
        author = token("Author")
        author_email = token("AuthorEmail")
        year = token("Year")

    (root / "Cargo.toml").write_text(
        textwrap.dedent(
            f'''\
            [package]
            name = "{name}"
            version = "0.1.0"
            edition = "2024"
            description = "{description}"
            repository = "https://github.com/{owner}/{name}"
            '''
        ),
        encoding="utf-8",
    )
    (root / "Cargo.lock").write_text(
        textwrap.dedent(
            f'''\
            version = 4

            [[package]]
            name = "{name}"
            version = "0.1.0"
            '''
        ),
        encoding="utf-8",
    )
    (workflow_directory / "release.yml").write_text(
        "env:\n"
        f'  RELEASE_GIT_AUTHOR_NAME_B64: "{author}"\n'
        f'  RELEASE_GIT_AUTHOR_EMAIL_B64: "{author_email}"\n',
        encoding="utf-8",
    )
    (root / ".github" / "CODEOWNERS").write_text(
        f"* @{owner}\n",
        encoding="utf-8",
    )
    (root / "LICENSE").write_text(f"Copyright {year} {author}\n", encoding="utf-8")

    if not initialized:
        (root / "TEMPLATE.md").write_text("template instructions\n", encoding="utf-8")
        guide = root / "docs" / "AGENT-INIT-GUIDE.md"
        guide.parent.mkdir()
        guide.write_text("template agent guide\n", encoding="utf-8")


def run_contract(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(root)],
        capture_output=True,
        text=True,
        check=False,
    )


class ReleaseInitializationPreflightTests(unittest.TestCase):
    def test_checked_in_untouched_template_is_rejected(self) -> None:
        template_root = Path(__file__).parents[2]
        if not (template_root / "TEMPLATE.md").exists():
            self.skipTest("template-only files were removed by initialization")

        result = run_contract(template_root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("Cargo.toml [package].name is still the template identity", result.stderr)
        self.assertIn("template-only files are still present", result.stderr)

    def test_untouched_template_is_rejected_with_exact_remediation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, initialized=False)

            result = run_contract(root)

            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertIn("Cargo.toml [package].name is still the template identity", result.stderr)
            self.assertIn("template-only files are still present", result.stderr)
            self.assertIn("Cargo.toml still contains initialization placeholders", result.stderr)
            workflow_path = (
                ".github\\workflows\\release.yml"
                if os.name == "nt"
                else ".github/workflows/release.yml"
            )
            self.assertIn(workflow_path, result.stderr)
            self.assertIn(
                "pwsh ./scripts/init.ps1 -ProjectName <crate-name>", result.stderr
            )
            self.assertIn(
                "bash ./scripts/init.sh --project-name <crate-name>", result.stderr
            )

    def test_initialized_project_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, initialized=True)

            result = run_contract(root)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "Release initialization preflight passed.\n")
            self.assertEqual(result.stderr, "")

    def test_no_single_marker_can_bypass_the_preflight(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, initialized=False)
            manifest = (root / "Cargo.toml").read_text(encoding="utf-8")
            (root / "Cargo.toml").write_text(
                manifest.replace(token("ProjectName"), "renamed-crate"),
                encoding="utf-8",
            )

            renamed_only = run_contract(root)

            self.assertEqual(renamed_only.returncode, 1)
            self.assertIn("template-only files are still present", renamed_only.stderr)
            self.assertIn("initialization placeholders", renamed_only.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, initialized=True)
            workflow = root / ".github" / "workflows" / "release.yml"
            workflow.write_text(
                workflow.read_text(encoding="utf-8") + f"# {token('AuthorEmail')}\n",
                encoding="utf-8",
            )

            leftover_placeholder = run_contract(root)

            self.assertEqual(leftover_placeholder.returncode, 1)
            self.assertNotIn("template-only files are still present", leftover_placeholder.stderr)
            self.assertIn(
                "release.yml still contains initialization placeholders",
                leftover_placeholder.stderr,
            )

    def test_codeowners_placeholder_alone_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, initialized=True)
            (root / ".github" / "CODEOWNERS").write_text(
                f"* @{token('GitHubOwner')}\n",
                encoding="utf-8",
            )

            result = run_contract(root)

            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            codeowners_path = (
                ".github\\CODEOWNERS" if os.name == "nt" else ".github/CODEOWNERS"
            )
            self.assertEqual(
                result.stderr,
                "::error::Release blocked: project initialization is incomplete.\n"
                f"::error:: - {codeowners_path} still contains initialization "
                "placeholders: GitHubOwner\n"
                "::error::Initialize the repository before releasing: "
                "pwsh ./scripts/init.ps1 -ProjectName <crate-name>\n"
                "::error::POSIX alternative: "
                "bash ./scripts/init.sh --project-name <crate-name>\n",
            )

    def test_malformed_or_missing_manifest_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, initialized=True)
            (root / "Cargo.toml").write_text("[package\n", encoding="utf-8")

            malformed = run_contract(root)

            self.assertEqual(malformed.returncode, 1)
            self.assertIn("Cargo.toml is not valid TOML", malformed.stderr)

        with tempfile.TemporaryDirectory() as directory:
            missing = run_contract(Path(directory))

            self.assertEqual(missing.returncode, 1)
            self.assertIn("could not read", missing.stderr)

    def test_workflow_invokes_the_checked_in_contract(self) -> None:
        self.assertEqual(
            workflow_run_script("Preflight — require initialized project"),
            "python3 tests/release-preflight/check_initialized.py .\n",
        )

    @unittest.skipIf(os.name == "nt", "production workflow shell runs on Linux")
    def test_production_workflow_step_rejects_and_accepts_fixtures(self) -> None:
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("production workflow step requires bash")
        command = workflow_run_script("Preflight — require initialized project")

        for initialized, expected_status in ((False, 1), (True, 0)):
            with self.subTest(initialized=initialized), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_fixture(root, initialized=initialized)
                script_directory = root / "tests" / "release-preflight"
                script_directory.mkdir(parents=True)
                shutil.copy2(SCRIPT, script_directory / SCRIPT.name)

                result = subprocess.run(
                    [bash, "-c", command],
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )

                self.assertEqual(result.returncode, expected_status, result.stderr)


if __name__ == "__main__":
    unittest.main()
