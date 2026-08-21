from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("extract_release_notes.py")
WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "release.yml"
SPEC = importlib.util.spec_from_file_location("extract_release_notes", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def changelog(unreleased: str, suffix: str = "") -> str:
    return (
        "# Changelog\n\n## [Unreleased]\n"
        + textwrap.dedent(unreleased)
        + textwrap.dedent(suffix)
    )


def workflow_run_script(step_name: str) -> str:
    """Return one literal ``run: |`` block from the production workflow."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    marker = f"      - name: {step_name}"
    try:
        step_index = lines.index(marker)
        run_index = lines.index("        run: |", step_index + 1)
    except ValueError as error:
        raise AssertionError(f"could not find workflow step {step_name!r}") from error

    script_lines: list[str] = []
    for line in lines[run_index + 1 :]:
        if line and len(line) - len(line.lstrip(" ")) < 10:
            break
        script_lines.append(line[10:] if line else "")
    return "\n".join(script_lines) + "\n"


class ExtractReleaseNotesTests(unittest.TestCase):
    def test_exact_markdown_matrix(self) -> None:
        cases = [
            (
                "single-line bullet and placeholder section",
                changelog(
                    """
### Added
- Initial project skeleton.

### Changed
-
"""
                ),
                "### Added\n- Initial project skeleton.",
            ),
            (
                "multiline nested and fenced bullet",
                changelog(
                    """
### Added

- Parse a complete entry.
  This continuation remains attached.

  - Preserve a nested item.
    1. Preserve deeper nesting too.

  ```rust
  fn example() {
      println!("kept");
  }
  ```

  Preserve the final paragraph.

- Keep the next top-level entry separate.
"""
                ),
                textwrap.dedent(
                    """\
                    ### Added

                    - Parse a complete entry.
                      This continuation remains attached.

                      - Preserve a nested item.
                        1. Preserve deeper nesting too.

                      ```rust
                      fn example() {
                          println!("kept");
                      }
                      ```

                      Preserve the final paragraph.

                    - Keep the next top-level entry separate."""
                ),
            ),
            (
                "bare marker owns properly indented multiline content",
                changelog(
                    """
### Added
-
  Preserved continuation.

  - Preserve a nested item.

  ```text
  preserved fence
  ```
"""
                ),
                textwrap.dedent(
                    """\
                    ### Added
                    -
                      Preserved continuation.

                      - Preserve a nested item.

                      ```text
                      preserved fence
                      ```"""
                ),
            ),
            (
                "reviewer bare-marker boundary probe",
                changelog(
                    """
### Added
-
  Preserved continuation.
"""
                ),
                "### Added\n-\n  Preserved continuation.",
            ),
            (
                "multiple populated sections preserve order",
                changelog(
                    """
### Added
- First.
- Second.

### Changed
- Third.

### Fixed
-
"""
                ),
                "### Added\n- First.\n- Second.\n\n### Changed\n- Third.",
            ),
            (
                "unindented prose and orphan indentation stay outside blocks",
                changelog(
                    """
### Fixed
- Included before the boundary.
This paragraph is outside the list item.
  This orphan is outside too.
- Included after the boundary.
"""
                ),
                "### Fixed\n- Included before the boundary.\n- Included after the boundary.",
            ),
            (
                "one-space prose is outside a top-level list item",
                changelog(
                    """
### Added
- Kept.

 Outside paragraph.
"""
                ),
                "### Added\n- Kept.",
            ),
            (
                "continuation indentation follows marker padding",
                changelog(
                    """
### Added
-   Kept with wider padding.
    Four-column continuation.
   Three-column paragraph is outside.
"""
                ),
                "### Added\n-   Kept with wider padding.\n    Four-column continuation.",
            ),
            (
                "next version bounds Unreleased",
                changelog(
                    """
### Added
- Current note.
""",
                    """
## [1.0.0] - 2026-01-01
### Added
- Historical note that must not leak.
""",
                ),
                "### Added\n- Current note.",
            ),
            (
                "reference definitions bound Unreleased",
                changelog(
                    """
### Added
- Current note.
""",
                    """
[Unreleased]: https://example.invalid/compare/v1...HEAD
[1.0.0]: https://example.invalid/releases/v1
### Added
- Text after references must not leak.
""",
                ),
                "### Added\n- Current note.",
            ),
            (
                "only the Unreleased section is considered",
                textwrap.dedent(
                    """\
                    # Changelog

                    ### Added
                    - Preamble note.

                    ## [Unreleased]

                    ### Changed
                    - Current note.

                    ## [1.0.0] - 2026-01-01

                    ### Fixed
                    - Historical note.
                    """
                ),
                "### Changed\n- Current note.",
            ),
        ]

        for name, source, expected in cases:
            with self.subTest(name=name):
                self.assertEqual(MODULE.extract_release_notes(source), expected)

    def test_placeholder_only_and_empty_sections_fail_closed(self) -> None:
        sources = [
            changelog("\n### Added\n-\n\n### Fixed\n-   \n"),
            changelog("\n### Added\n\n### Changed\n   \n"),
            "# Changelog\n\n## [1.0.0]\n\n### Added\n- Historical.\n",
        ]

        for source in sources:
            with self.subTest(source=source):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    source_path = root / "CHANGELOG.md"
                    output_path = root / "release-notes.md"
                    source_path.write_text(source, encoding="utf-8")

                    result = subprocess.run(
                        [sys.executable, str(SCRIPT), str(source_path), str(output_path)],
                        capture_output=True,
                        text=True,
                        check=False,
                    )

                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(
                        result.stderr,
                        "::error::[Unreleased] section in CHANGELOG.md is empty. "
                        "Add release notes before releasing.\n",
                    )
                    self.assertFalse(output_path.exists())

    def test_cli_writes_the_exact_result_with_one_terminal_newline(self) -> None:
        source = changelog("\n### Added\n- One.\n  Continued.\n")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "CHANGELOG.md"
            output_path = root / "release-notes.md"
            source_path.write_text(source, encoding="utf-8")

            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(source_path), str(output_path)],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                output_path.read_text(encoding="utf-8"),
                "### Added\n- One.\n  Continued.\n",
            )

    def test_check_mode_uses_dedicated_exit_for_valid_empty_notes(self) -> None:
        cases = [
            (
                "manual bare-marker content",
                changelog("\n### Added\n-\n  Kept.\n"),
                0,
                "",
            ),
            ("placeholder-only", changelog("\n### Added\n-\n"), 3, ""),
            ("unsectioned placeholder-only", changelog("\n-\n"), 3, ""),
            (
                "unsectioned manual bullet",
                changelog("\n- Curated note.\n"),
                4,
                "::error::[Unreleased] contains a manual top-level bullet outside "
                "a '###' section. Move every manual bullet under a supported '###' "
                "section before releasing; CHANGELOG.md was left unchanged.\n",
            ),
            (
                "unsectioned bullet alongside renderable notes",
                changelog("\n- Curated preface.\n\n### Added\n- Renderable note.\n"),
                4,
                "::error::[Unreleased] contains a manual top-level bullet outside "
                "a '###' section. Move every manual bullet under a supported '###' "
                "section before releasing; CHANGELOG.md was left unchanged.\n",
            ),
            (
                "missing Unreleased header",
                "# Changelog\n\n## [1.0.0]\n- Historical note.\n",
                2,
                "::error::Could not find '## [Unreleased]' header in CHANGELOG.md\n",
            ),
        ]

        with tempfile.TemporaryDirectory() as directory:
            source_path = Path(directory) / "CHANGELOG.md"
            for name, source, expected_status, expected_stderr in cases:
                with self.subTest(name=name):
                    source_path.write_text(source, encoding="utf-8")
                    result = subprocess.run(
                        [sys.executable, str(SCRIPT), "--check", str(source_path)],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, expected_status, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr, expected_stderr)

            missing = subprocess.run(
                [sys.executable, str(SCRIPT), "--check", str(source_path) + ".missing"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(missing.returncode, 2)
            self.assertIn("::error::Could not read", missing.stderr)

    def test_production_autofill_then_extract_seam(self) -> None:
        if os.name == "nt":
            self.skipTest("production workflow seam runs in the Linux Actions shell")
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("production workflow scripts require bash")

        auto_fill = workflow_run_script("Auto-fill empty [Unreleased] from git log")
        extract = workflow_run_script("Extract release notes")
        manual_cases = [
            (
                "paragraph",
                changelog("\n### Added\n-\n  Preserved paragraph.\n"),
                "### Added\n-\n  Preserved paragraph.\n",
            ),
            (
                "nested list",
                changelog("\n### Added\n-\n  - Preserved nested item.\n"),
                "### Added\n-\n  - Preserved nested item.\n",
            ),
            (
                "fenced block",
                changelog("\n### Added\n-\n  ```text\n  preserved fence\n  ```\n"),
                "### Added\n-\n  ```text\n  preserved fence\n  ```\n",
            ),
        ]

        for name, source, expected_notes in manual_cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self._prepare_workflow_fixture(root, source)
                environment = self._workflow_environment(root, cliff_status=89)

                gate = subprocess.run(
                    [bash, "-c", auto_fill],
                    cwd=root,
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(gate.returncode, 0, gate.stderr)
                self.assertEqual((root / "CHANGELOG.md").read_text(encoding="utf-8"), source)
                self.assertFalse((root / "git-cliff.called").exists())

                rendered = subprocess.run(
                    [bash, "-c", extract],
                    cwd=root,
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(rendered.returncode, 0, rendered.stderr)
                self.assertEqual(
                    (root / "release-notes.md").read_text(encoding="utf-8"),
                    expected_notes,
                )

        with (
            self.subTest(name="unsectioned manual bullet fails closed"),
            tempfile.TemporaryDirectory() as directory,
        ):
            root = Path(directory)
            source = changelog("\n- Curated note outside a supported section.\n")
            original = source.encode("utf-8")
            self._prepare_workflow_fixture(root, source)
            environment = self._workflow_environment(
                root,
                cliff_output="### Added\n- Must not replace the changelog.\n",
            )

            gate = subprocess.run(
                [bash, "-c", auto_fill],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(gate.returncode, 4)
            self.assertIn("manual top-level bullet outside a '###' section", gate.stderr)
            self.assertFalse((root / "git-cliff.called").exists())
            self.assertEqual((root / "CHANGELOG.md").read_bytes(), original)

        with (
            self.subTest(name="placeholder-only auto-fills"),
            tempfile.TemporaryDirectory() as directory,
        ):
            root = Path(directory)
            source = changelog("\n### Added\n-\n\n### Changed\n-   \n")
            generated = "### Added\n- Generated from commits.\n"
            self._prepare_workflow_fixture(root, source)
            environment = self._workflow_environment(root, cliff_output=generated)

            gate = subprocess.run(
                [bash, "-c", auto_fill],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(gate.returncode, 0, gate.stderr)
            self.assertTrue((root / "git-cliff.called").exists())

            rendered = subprocess.run(
                [bash, "-c", extract],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            self.assertEqual(
                (root / "release-notes.md").read_text(encoding="utf-8"),
                generated,
            )

        with (
            self.subTest(name="parser failure never auto-fills"),
            tempfile.TemporaryDirectory() as directory,
        ):
            root = Path(directory)
            source = changelog("\n### Added\n-\n")
            self._prepare_workflow_fixture(root, source)
            parser = root / "tests" / "release-notes" / SCRIPT.name
            parser.write_text("raise RuntimeError('parser failure')\n", encoding="utf-8")
            environment = self._workflow_environment(
                root,
                cliff_output="### Added\n- Must not replace the changelog.\n",
            )

            gate = subprocess.run(
                [bash, "-c", auto_fill],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(gate.returncode, 1)
            self.assertIn("RuntimeError: parser failure", gate.stderr)
            self.assertFalse((root / "git-cliff.called").exists())
            self.assertEqual((root / "CHANGELOG.md").read_text(encoding="utf-8"), source)

    def _prepare_workflow_fixture(
        self,
        root: Path,
        changelog_text: str,
    ) -> None:
        parser_directory = root / "tests" / "release-notes"
        parser_directory.mkdir(parents=True)
        shutil.copy2(SCRIPT, parser_directory / SCRIPT.name)
        (root / "CHANGELOG.md").write_text(changelog_text, encoding="utf-8")

        bin_directory = root / "bin"
        bin_directory.mkdir()
        fake_cliff = bin_directory / "git-cliff"
        with fake_cliff.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(
                "#!/usr/bin/env sh\n"
                'printf "called\\n" > "$FAKE_CLIFF_MARKER"\n'
                'printf "%s" "$FAKE_CLIFF_OUTPUT"\n'
                'exit "$FAKE_CLIFF_STATUS"\n'
            )
        fake_cliff.chmod(0o755)

    def _workflow_environment(
        self,
        root: Path,
        *,
        cliff_status: int = 0,
        cliff_output: str = "",
    ) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "PREV_TAG": "",
                "NOTES_FILE": str(root / "release-notes.md"),
                "RUNNER_TEMP": str(root),
                "FAKE_CLIFF_MARKER": str(root / "git-cliff.called"),
                "FAKE_CLIFF_OUTPUT": cliff_output,
                "FAKE_CLIFF_STATUS": str(cliff_status),
                "PATH": str(root / "bin") + os.pathsep + environment.get("PATH", ""),
            }
        )
        return environment


if __name__ == "__main__":
    unittest.main()
