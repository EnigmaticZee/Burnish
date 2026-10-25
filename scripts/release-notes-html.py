#!/usr/bin/env python3
"""Turns one version's entry in docs/HISTORY.md into the small page Burnish's update window shows.

Usage: python3 scripts/release-notes-html.py <version>   (prints HTML)

The appcast carries this page inline, so the update window shows just the notes, styled for light
and dark, without loading a web page. Handles what HISTORY.md uses: paragraphs, "- " bullets
(with wrapped lines), **bold**, *italics*, `code` and [links](https://...).
"""
import html
import re
import sys
from pathlib import Path

HISTORY = Path(__file__).resolve().parent.parent / "docs" / "HISTORY.md"


def section(version):
    lines, on = [], False
    for line in HISTORY.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            if on:
                break
            on = line.startswith(f"## {version} ")
            continue
        if on:
            lines.append(line)
    if not lines:
        sys.exit(f"No entry for {version} in docs/HISTORY.md")
    return lines


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)
    return text


def body(lines):
    blocks, para, items = [], [], []

    def flush_para():
        if para:
            blocks.append(f"<p>{inline(' '.join(para))}</p>")
            para.clear()

    def flush_list():
        if items:
            blocks.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            flush_para()
            flush_list()
        elif line.startswith("- "):
            flush_para()
            items.append(line[2:].strip())
        elif line.startswith("  ") and items:
            items[-1] += " " + line.strip()
        else:
            flush_list()
            para.append(line.strip())
    flush_para()
    flush_list()
    return "\n".join(blocks)


STYLE = """
:root { color-scheme: light dark; }
body { font: 13px -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.45; margin: 12px 14px; color: #1d1d1f; }
p:first-child { font-weight: 600; }
ul { padding-left: 18px; margin: 8px 0; }
li { margin: 6px 0; }
code { font: 12px ui-monospace, Menlo, monospace; }
a { color: #b0641e; }
@media (prefers-color-scheme: dark) { body { color: #f2f2f7; } a { color: #f0a868; } }
"""

if __name__ == "__main__":
    version = sys.argv[1]
    print(f"<!doctype html><html><head><meta charset=\"utf-8\"><style>{STYLE}</style></head><body>")
    print(body(section(version)))
    print("</body></html>")
