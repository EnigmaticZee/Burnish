#!/usr/bin/env python3
"""Turns one version's entry in docs/HISTORY.md into the small page Burnish's update window shows.

Usage: python3 scripts/release-notes-html.py <version>              (prints HTML)
       python3 scripts/release-notes-html.py --markdown <version>   (GitHub release notes)

The appcast carries this page inline, so the update window shows just the notes, styled for light
and dark, without loading a web page. Handles what HISTORY.md uses: paragraphs, "- " bullets
(with wrapped lines), "+ " lines for the short version, **bold**, *italics*, `code` and
[links](https://...).
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


def short_version(lines):
    """The "+ " lines: a few plain sentences for people who only skim."""
    short, in_short = [], False
    for line in lines:
        if line.startswith("+ "):
            short.append(line[2:].strip())
            in_short = True
        elif in_short and line.startswith("  ") and line.strip():
            short[-1] += " " + line.strip()
        else:
            in_short = False
    return short


def full_notes(lines):
    """Everything except the short version."""
    out, in_short = [], False
    for line in lines:
        if line.startswith("+ "):
            in_short = True
            continue
        if in_short and line.startswith("  ") and line.strip():
            continue
        in_short = False
        out.append(line)
    return out


def markdown(lines):
    """The GitHub release: the short version first, then the full notes."""
    short = short_version(lines)
    rest = "\n".join(full_notes(lines)).strip()
    if not short:
        return rest
    head, _, tail = rest.partition("\n\n")
    tail = tail.strip()
    listed = "\n".join(f"- {item}" for item in short)
    return f"{head}\n\n**The short version**\n\n{listed}\n\n**The full notes**\n\n{tail}".rstrip()


def body(lines):
    short = short_version(lines)
    lines = full_notes(lines)
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
    if short:
        # The headline, then the short version, then the full notes.
        summary = "<p class=\"label\">The short version</p><ul class=\"short\">" + "".join(f"<li>{inline(i)}</li>" for i in short) + "</ul><p class=\"label\">The full notes</p>"
        blocks.insert(1 if blocks else 0, summary)
    return "\n".join(blocks)


STYLE = """
:root { color-scheme: light dark; }
body { font: 13px -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.45; margin: 12px 14px; color: #1d1d1f; }
p:first-child { font-weight: 600; }
ul { padding-left: 18px; margin: 8px 0; }
li { margin: 6px 0; }
code { font: 12px ui-monospace, Menlo, monospace; }
.label { font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: #8a7560; margin: 14px 0 4px; }
ul.short li { margin: 4px 0; }
a { color: #b0641e; }
@media (prefers-color-scheme: dark) { body { color: #f2f2f7; } a { color: #f0a868; } }
"""

if __name__ == "__main__":
    if sys.argv[1] == "--markdown":
        print(markdown(section(sys.argv[2])))
        sys.exit()
    version = sys.argv[1]
    print(f"<!doctype html><html><head><meta charset=\"utf-8\"><style>{STYLE}</style></head><body>")
    print(body(section(version)))
    print("</body></html>")
