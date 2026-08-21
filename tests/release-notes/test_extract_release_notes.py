from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("extract_release_notes.py")
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


if __name__ == "__main__":
    unittest.main()
