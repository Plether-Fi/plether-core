#!/usr/bin/env python3
"""Reject stale test links and non-discoverable property names in the perps map."""

from pathlib import Path
import re
import sys


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    document = root / "packages/perps/test/perps/TEST_MAP.md"
    if not document.is_file():
        print(f"Missing test map: {document}", file=sys.stderr)
        return 1
    content = document.read_text()
    references = re.findall(r"\[[^\]]+\]\(([^)]+\.t\.sol)\)::`((?:test|invariant)\w*)`", content)
    errors = []
    if not references:
        errors.append("No exact discoverable test/property references found")
    for relative, function in references:
        path = (document.parent / relative).resolve()
        if not path.is_relative_to(root):
            errors.append(f"Test reference escapes the repository: {relative}")
        elif not path.is_file():
            errors.append(f"Missing test file: {relative}")
        elif not re.search(r"\bfunction\s+" + re.escape(function) + r"\s*\(", path.read_text()):
            errors.append(f"Missing test/property: {relative}::{function}")
    for relative in re.findall(r"\[[^\]]+\]\(([^)#]+\.t\.sol)(?:#[^)]*)?\)", content):
        if not (document.parent / relative).is_file():
            errors.append(f"Broken test link: {relative}")
    for relative, anchor in re.findall(r"\[[^\]]+\]\(([^)#]+\.md)(?:#([^)]*))?\)", content):
        path = (document.parent / relative).resolve()
        if not path.is_file():
            errors.append(f"Missing specification/document: {relative}")
            continue
        headings = re.findall(r"^#{1,6}\s+(.+)$", path.read_text(), flags=re.M)
        anchors = {re.sub(r"[^\w -]", "", heading.lower()).replace(" ", "-") for heading in headings}
        if anchor and anchor not in anchors:
            errors.append(f"Missing specification heading: {relative}#{anchor}")
    if errors:
        print("\n".join(sorted(set(errors))), file=sys.stderr)
        return 1
    print(f"Perps test map: {len(references)} exact test/property references verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
