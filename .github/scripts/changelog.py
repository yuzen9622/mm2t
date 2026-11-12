"""Usage: changelog.py <CHANGELOG.md> <version>

Prints the body of the "## [<version>]" section (Keep a Changelog format), with the "###" group
headings kept and the trailing link references dropped. Exits non-zero when the version has no
section or the section is empty, so a release cannot go out without release notes.
"""
import re
import sys

path, version = sys.argv[1:3]
lines = open(path, encoding="utf-8").read().splitlines()

start = next(
    (i for i, line in enumerate(lines) if re.match(rf"^## \[{re.escape(version)}\]( |$)", line)),
    None,
)
if start is None:
    sys.exit(f"{path} has no '## [{version}]' section. Move the [Unreleased] entries under it before tagging.")

body = []
for line in lines[start + 1:]:
    if line.startswith("## ") or re.match(r"^\[[^\]]+\]: ", line):
        break
    body.append(line)

text = "\n".join(body).strip()
if not re.search(r"^- ", text, re.M):
    sys.exit(f"The '## [{version}]' section in {path} has no entries.")
print(text)
