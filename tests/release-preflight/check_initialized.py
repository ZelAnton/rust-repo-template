"""Fail closed when the release workflow runs from an uninitialized template."""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path
from typing import Sequence


PLACEHOLDER_NAMES = (
    "ProjectName",
    "Author",
    "AuthorEmail",
    "GitHubOwner",
    "Description",
    "Year",
)
INITIALIZATION_SURFACES = (
    Path("Cargo.toml"),
    Path("Cargo.lock"),
    Path(".github/workflows/release.yml"),
    Path("LICENSE"),
    Path("README.md"),
    Path("CHANGELOG.md"),
    Path("CONTRIBUTING.md"),
    Path("SECURITY.md"),
)
TEMPLATE_ONLY_PATHS = (
    Path("TEMPLATE.md"),
    Path("docs/AGENT-INIT-GUIDE.md"),
)


def _placeholder(name: str) -> str:
    # Construct the marker so running either initializer cannot rewrite the
    # sentinel's own vocabulary.
    return "__" + name + "__"


def _read_utf8(path: Path, issues: list[str]) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        issues.append(f"could not read {path}: {error}")
        return None


def initialization_issues(root: Path) -> list[str]:
    """Return every observed reason that repository initialization is incomplete."""
    issues: list[str] = []

    remaining_template_paths = [
        str(path) for path in TEMPLATE_ONLY_PATHS if (root / path).exists()
    ]
    if remaining_template_paths:
        issues.append(
            "template-only files are still present: "
            + ", ".join(remaining_template_paths)
        )

    manifest_path = root / "Cargo.toml"
    manifest_text = _read_utf8(manifest_path, issues)
    if manifest_text is not None:
        try:
            manifest = tomllib.loads(manifest_text)
        except tomllib.TOMLDecodeError as error:
            issues.append(f"Cargo.toml is not valid TOML: {error}")
        else:
            package = manifest.get("package")
            package_name = package.get("name") if isinstance(package, dict) else None
            if not isinstance(package_name, str) or not package_name.strip():
                issues.append("Cargo.toml [package].name is missing or empty")
            elif package_name == _placeholder("ProjectName"):
                issues.append("Cargo.toml [package].name is still the template identity")

    for relative_path in INITIALIZATION_SURFACES:
        path = root / relative_path
        if not path.exists():
            continue
        text = manifest_text if relative_path == Path("Cargo.toml") else _read_utf8(path, issues)
        if text is None:
            continue
        remaining = [
            name for name in PLACEHOLDER_NAMES if _placeholder(name) in text
        ]
        if remaining:
            issues.append(
                f"{relative_path} still contains initialization placeholders: "
                + ", ".join(remaining)
            )

    return issues


def main(argv: Sequence[str]) -> int:
    if len(argv) > 2:
        print(f"usage: {Path(argv[0]).name} [REPOSITORY_ROOT]", file=sys.stderr)
        return 2

    root = Path(argv[1] if len(argv) == 2 else ".")
    issues = initialization_issues(root)
    if not issues:
        print("Release initialization preflight passed.")
        return 0

    print("::error::Release blocked: project initialization is incomplete.", file=sys.stderr)
    for issue in issues:
        print(f"::error:: - {issue}", file=sys.stderr)
    print(
        "::error::Initialize the repository before releasing: "
        "pwsh ./scripts/init.ps1 -ProjectName <crate-name>",
        file=sys.stderr,
    )
    print(
        "::error::POSIX alternative: "
        "bash ./scripts/init.sh --project-name <crate-name>",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
