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
REAL_BULLET_RE = re.compile(r"^-[ \t]+\S")


def _bullet_spans(lines: list[str]) -> list[tuple[int, int]]:
    """Return complete top-level bullet spans in one changelog section."""
    spans: list[tuple[int, int]] = []
    index = 0

    while index < len(lines):
        if not REAL_BULLET_RE.match(lines[index]):
            index += 1
            continue

        start = index
        end = index + 1
        index += 1

        while index < len(lines):
            line = lines[index]
            if not line.strip():
                index += 1
                continue
            if line[:1] in {" ", "\t"}:
                end = index + 1
                index += 1
                continue
            break

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


def main(argv: Sequence[str]) -> int:
    if len(argv) != 3:
        print(
            f"usage: {Path(argv[0]).name} CHANGELOG OUTPUT",
            file=sys.stderr,
        )
        return 2

    changelog_path = Path(argv[1])
    output_path = Path(argv[2])
    result = extract_release_notes(changelog_path.read_text(encoding="utf-8"))
    if not result:
        print(
            "::error::[Unreleased] section in CHANGELOG.md is empty. "
            "Add release notes before releasing.",
            file=sys.stderr,
        )
        return 1

    output_path.write_text(result + "\n", encoding="utf-8")
    print("----- release notes -----")
    print(result)
    print("-------------------------")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
