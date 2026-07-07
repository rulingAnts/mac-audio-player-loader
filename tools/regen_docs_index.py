#!/usr/bin/env python3
"""Regenerate docs/index.html from README.html.

README.html (the file shipped in the release zip) embeds every image as a
base64 data: URI so it works as a single offline file. The GitHub Pages copy
(docs/index.html) references docs/images/*.png|jpg instead. This script
rewrites the src attributes by matching a distinctive substring of each
<img> line (usually the alt text) to a file name. Run it after ANY edit to
README.html, from the repo root:  python3 tools/regen_docs_index.py
"""
import re
import pathlib
import sys

MAPPING = [
    ("unzipped", "01-folder.png"),
    ("hub-setup photo", "01b-hub-setup.jpg"),
    ("Spotlight search", "02-open-terminal.png"),
    ("onto the Terminal window", "03-drag-script.png"),
    ("Dock icon", "03b-drag-to-dock.png"),
    ("volume-label dialog", "04-label.png"),
    ("target disks detected", "05-count.png"),
    ("disk chooser list", "06-choose.png"),
    ("erase/keep confirmation", "07-confirm.png"),
    ("progress bar running", "08-progress.png"),
    ("after a fully successful run", "run-again-success.png"),
    ("RESULTS summary", "09-results.png"),
    ("some devices failed", "run-again-redo.png"),
    ("Finder sidebar showing only REDO", "10-finder-redo.png"),
    ("names-on-the-devices dialog", "11-names.png"),
    ("player picker list", "12-player.png"),
    ("content-check caution dialog", "13-content-check.png"),
    ("flagged write-order preview", "14-preview-flagged.png"),
    ("preview page with simple numbers", "15-preview-renamed.png"),
]

DATA_RE = re.compile(r'src="data:image/(?:png|jpeg);base64,[^"]*"')

def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    html = (root / "README.html").read_text()
    lines = html.split("\n")
    used = []
    for i, ln in enumerate(lines):
        if DATA_RE.search(ln) and 'alt="' in ln:
            fn = next((f for s, f in MAPPING if s in ln), None)
            if not fn:
                sys.exit(f"UNMAPPED embedded image on line {i+1}: {ln[:120]!r}\n"
                         f"Add a MAPPING entry (key on the alt text) and re-run.")
            if not (root / "docs/images" / fn).exists():
                sys.exit(f"docs/images/{fn} does not exist")
            used.append(fn)
            lines[i] = DATA_RE.sub(f'src="images/{fn}"', ln)
    (root / "docs/index.html").write_text("\n".join(lines))
    norm = lambda s: DATA_RE.sub("IMG", re.sub(r'src="images/[^"]*"', "IMG", s))
    same = norm(html) == norm((root / "docs/index.html").read_text())
    print(f"mapped {len(used)} images; mirror {'IDENTICAL' if same else 'DIFFERS — INVESTIGATE'}")
    return 0 if same else 1

if __name__ == "__main__":
    sys.exit(main())
