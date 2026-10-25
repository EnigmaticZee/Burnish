#!/usr/bin/env python3
"""Builds the website into a folder, with "What's new" filled from docs/HISTORY.md.

Usage: python3 scripts/build-site.py <version> [out-dir]      (out-dir defaults to _site)

The deploy workflow passes the version of the newest published release, so the page never
announces a version whose download isn't up yet. Uses only the standard library.
"""
import html
import importlib.util
import re
import shutil
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
REPO = "https://github.com/EnigmaticZee/Burnish"
DOWNLOAD = f"{REPO}/releases/latest/download/Burnish.dmg"

# The same Markdown handling as the update window's notes (scripts/release-notes-html.py).
spec = importlib.util.spec_from_file_location("notes", ROOT / "scripts" / "release-notes-html.py")
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


def release_date(version):
    for line in notes.HISTORY.read_text(encoding="utf-8").splitlines():
        match = re.match(rf"## {re.escape(version)} — (\d{{4}})-(\d{{2}})-(\d{{2}})", line)
        if match:
            return date(*map(int, match.groups()))
    sys.exit(f"No dated entry for {version} in docs/HISTORY.md")


def split_entry(lines):
    """The first paragraph is the headline, "- " lines are the items, the rest is extra."""
    paragraphs, items, current = [], [], []
    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            if current:
                paragraphs.append(" ".join(current))
                current = []
        elif line.startswith("- "):
            items.append(line[2:].strip())
        elif line.startswith("  ") and items and not current:
            items[-1] += " " + line.strip()
        else:
            current.append(line.strip())
    if current:
        paragraphs.append(" ".join(current))
    headline = paragraphs[0] if paragraphs else ""
    return headline, items, paragraphs[1:]


def short_block(short):
    """The short version, marked as a summary; nothing when the entry has none."""
    if not short:
        return ""
    lines = "\n".join(f"            <li>{notes.inline(line)}</li>" for line in short)
    return (f'        <div class="short">\n          <span class="short-badge">The short version</span>\n'
            f'          <ul>\n{lines}\n          </ul>\n        </div>')


def build(version, out):
    lines = notes.section(version)
    short = notes.short_version(lines)
    headline, items, extra = split_entry(notes.full_notes(lines))
    when = release_date(version)
    plain = re.sub(r"[*`]", "", headline).rstrip(".")
    values = {
        "VERSION": html.escape(version),
        "RELEASE_DATE": f"{when.day} {when.strftime('%B %Y')}",
        "RELEASE_DATE_ISO": when.isoformat(),
        "RELEASE_HEADLINE": notes.inline(headline),
        "RELEASE_HEADLINE_PLAIN": html.escape(plain),
        "RELEASE_SHORT": short_block(short),
        "RELEASE_ITEMS": "\n".join(f"          <li>{notes.inline(item)}</li>" for item in items),
        "RELEASE_EXTRA": "\n".join(f'        <p class="release-extra">{notes.inline(p)}</p>' for p in extra),
        "DOWNLOAD_URL": DOWNLOAD,
        "REPO": REPO,
    }
    page = (SITE / "index.html").read_text(encoding="utf-8")
    for key, value in values.items():
        page = page.replace("{{" + key + "}}", value)
    leftover = re.findall(r"\{\{[A-Z_]+\}\}", page)
    if leftover:
        sys.exit(f"Unfilled placeholders: {leftover}")

    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(SITE, out, ignore=shutil.ignore_patterns("index.html", ".DS_Store"))
    (out / "index.html").write_text(page, encoding="utf-8")
    print(f"Built {out} for {version}: {len(items)} items in What's new")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    build(sys.argv[1], Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "_site")
