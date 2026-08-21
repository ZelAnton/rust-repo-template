"""Extract curated Markdown release notes from a Keep a Changelog document."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Sequence


UNRELEASED_RE = re.compile(
    r"^## \[Unreleased\][ \t]*\r?\n(.*?)(?=^## \[|^\[[^\]\r\n]+\]:|\Z)",
    re.MULTILINE | re.DOTALL,
)
SECTION_HEADER_RE = re.compile(r"^###[ \t]+\S")
BULLET_MARKER_RE = re.compile(r"^-(?:$|(?P<padding>[ \t]+)(?P<content>\S.*)?)$")
CHECK_EMPTY_EXIT = 3


def _advance_column(column: int, whitespace: str) -> int:
    """Return the visual column after CommonMark-style spaces and tabs."""
    for character in whitespace:
        if character == "\t":
            column += 4 - (column % 4)
        else:
            column += 1
    return column


def _leading_columns(line: str) -> int:
    whitespace = line[: len(line) - len(line.lstrip(" \t"))]
    return _advance_column(0, whitespace)


def _bullet_marker(line: str) -> tuple[int, bool] | None:
    """Return this top-level item's content indent and inline-content state."""
    match = BULLET_MARKER_RE.match(line)
    if match is None:
        return None

    content = match.group("content")
    if content is None:
        # An empty marker can still introduce content on a following line. The
        # default list padding is one column, so continuation starts at column 2.
        return 2, False

    padding = match.group("padding")
    if padding is None:
        raise AssertionError("inline bullet content must follow marker padding")
    padding_columns = _advance_column(1, padding) - 1
    # CommonMark treats one to four columns as list padding. With five or more,
    # one column is padding and the remainder belongs to the item content.
    content_indent = 1 + padding_columns if padding_columns <= 4 else 2
    return content_indent, True


def _bullet_spans(lines: list[str]) -> list[tuple[int, int]]:
    """Return complete top-level bullet spans in one changelog section."""
    spans: list[tuple[int, int]] = []
    index = 0

    while index < len(lines):
        marker = _bullet_marker(lines[index])
        if marker is None:
            index += 1
            continue

        content_indent, has_content = marker
        start = index
        end = index + 1
        is_real = has_content
        index += 1

        while index < len(lines):
            line = lines[index]
            if not line.strip():
                index += 1
                continue
            if _leading_columns(line) >= content_indent:
                is_real = True
                end = index + 1
                index += 1
                continue
            break

        if is_real:
            spans.append((start, end))

    return spans


def _render_section(header: str, lines: list[str]) -> str | None:
    spans = _bullet_spans(lines)
    if not spans:
        return None

    rendered = [header]
    first_start = spans[0][0]
    leading = lines[:first_start]
    if leading and all(not line.strip() for line in leading):
        rendered.extend(leading)

    previous_end: int | None = None
    for start, end in spans:
        if previous_end is not None:
            separator = lines[previous_end:start]
            if separator and all(not line.strip() for line in separator):
                rendered.extend(separator)
        rendered.extend(lines[start:end])
        previous_end = end

    return "\n".join(rendered)


def extract_release_notes(changelog: str) -> str:
    """Return populated ``###`` sections from the bounded Unreleased body."""
    match = UNRELEASED_RE.search(changelog)
    if not match:
        return ""

    body_lines = match.group(1).splitlines()
    sections: list[str] = []
    index = 0

    while index < len(body_lines):
        header = body_lines[index]
        if not SECTION_HEADER_RE.match(header):
            index += 1
            continue

        section_start = index + 1
        index = section_start
        while index < len(body_lines) and not SECTION_HEADER_RE.match(body_lines[index]):
            index += 1

        rendered = _render_section(header, body_lines[section_start:index])
        if rendered is not None:
            sections.append(rendered)

    return "\n\n".join(sections)


def _read_changelog(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        print(f"::error::Could not read {path}: {error}", file=sys.stderr)
        return None


def main(argv: Sequence[str]) -> int:
    if len(argv) == 3 and argv[1] == "--check":
        changelog = _read_changelog(Path(argv[2]))
        if changelog is None:
            return 2
        # A dedicated status keeps Python/import failures (normally exit 1)
        # distinct from the one state where auto-fill is allowed.
        return 0 if extract_release_notes(changelog) else CHECK_EMPTY_EXIT

    if len(argv) != 3:
        print(
            f"usage: {Path(argv[0]).name} CHANGELOG OUTPUT\n"
            f"       {Path(argv[0]).name} --check CHANGELOG",
            file=sys.stderr,
        )
        return 2

    changelog_path = Path(argv[1])
    output_path = Path(argv[2])
    changelog = _read_changelog(changelog_path)
    if changelog is None:
        return 2
    result = extract_release_notes(changelog)
    if not result:
        print(
            "::error::[Unreleased] section in CHANGELOG.md is empty. "
            "Add release notes before releasing.",
            file=sys.stderr,
        )
        return 1

    try:
        output_path.write_text(result + "\n", encoding="utf-8")
    except OSError as error:
        print(f"::error::Could not write {output_path}: {error}", file=sys.stderr)
        return 2
    print("----- release notes -----")
    print(result)
    print("-------------------------")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
