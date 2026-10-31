"""Repair malformed .fzp part files in a copy of fritzing-parts, before the parts database is built.

fritzing-parts' master branch (the branch Fritzing's in-app parts update expects) contains files
that are not well-formed XML, for example obsolete/Arduino Nano_v30.fzp repeats the "replacedby"
attribute. Qt 6's XML parser rejects them, and Fritzing then shows a modal error box, which blocks
a headless build forever. The only repair applied is the one upstream used on the develop branch
(commit dcaad939): drop repeated attributes and keep the last value.

usage: python fix_parts_xml.py <fritzing-parts folder>
Exits with an error if a file is still not well-formed after the repair.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

START_TAG = re.compile(r"<[A-Za-z_][^<>]*>")
ATTRIBUTE = re.compile(r"""\s+([A-Za-z_:][\w.:-]*)\s*=\s*("[^"]*"|'[^']*')""")


def dedupe_tag(match):
    tag = match.group(0)
    attributes = list(ATTRIBUTE.finditer(tag))
    names = [a.group(1) for a in attributes]
    if len(names) == len(set(names)):
        return tag
    keep = {name: i for i, name in enumerate(names)}  # index of the last occurrence
    out, pos = [], 0
    for i, a in enumerate(attributes):
        out.append(tag[pos:a.start()])
        if keep[a.group(1)] == i:
            out.append(a.group(0))
        pos = a.end()
    out.append(tag[pos:])
    return "".join(out)


def well_formed(path):
    try:
        ET.parse(path)
        return None
    except ET.ParseError as e:
        return str(e)


def main(root):
    fixed, broken = [], []
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            if not name.endswith(".fzp"):
                continue
            path = os.path.join(folder, name)
            if well_formed(path) is None:
                continue
            with open(path, encoding="utf-8") as f:
                text = f.read()
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(START_TAG.sub(dedupe_tag, text))
            error = well_formed(path)
            (broken if error else fixed).append((os.path.relpath(path, root), error))
    for rel, _ in fixed:
        print(f"repaired: {rel}")
    for rel, error in broken:
        print(f"still not well-formed: {rel}: {error}", file=sys.stderr)
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
