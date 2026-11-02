#!/usr/bin/env python3
"""Cut the test fixtures out of Homebrew's full cask list.

Usage: scripts/make-cask-fixture.py cask.json

Writes Tests/CaskIndexTests/Fixtures/casks.json: the casks the matcher tests name, plus the first
cask of each tricky kind (version "latest", no checksum, .pkg, nested container, vendor installer,
deprecated, disabled, font) so the parser sees every shape, keeping only the keys the parser reads.
"""
import json
import sys

NAMED = [
    "google-chrome", "google-chrome@beta", "google-chrome@canary", "google-chrome@dev",
    "firefox", "firefox@beta", "firefox@esr", "firefox@nightly", "firefox@developer-edition", "firefox@cn",
    "brave-browser", "brave-browser@beta", "brave-origin",
    "visual-studio-code", "iterm2", "iterm2@beta", "slack", "slack@beta", "1password", "rectangle",
    "adguard", "adguard@nightly", "cleanmymac", "cleanmymac-cli",
    "discord", "discord@canary", "discord@ptb", "figma", "figma@beta", "nordvpn", "logi-options+", "pastenow",
    "qbittorrent", "qbittorrent@lt20", "c0re100-qbittorrent", "stremio", "stremio@beta",
    "wondershare-uniconverter", "mailbutler", "obsidian", "zoom", "spotify", "vlc", "telegram",
]
# Apps the truth set installs as "not in Homebrew's list": never let a tricky-kind pick add them.
ABSENT = {"betterdisplay"}
FIXTURE = "Tests/CaskIndexTests/Fixtures/casks.json"


# The top-level keys Sources/CaskIndex/Cask.swift reads; the rest (language variations, Ruby source
# checksums, platform lists) is almost half the bytes and never looked at.
KEEP = [
    "token",
    "name",
    "version",
    "url",
    "sha256",
    "artifacts",
    "variations",
    "depends_on",
    "container",
    "homepage",
    "deprecated",
    "deprecation_reason",
    "disabled",
    "disable_reason",
    "auto_updates",
    "caveats_rosetta",
]


def write(casks, dst):
    trimmed = [{k: v for k, v in c.items() if k in KEEP} for c in casks]
    with open(dst, "w") as out:
        json.dump(trimmed, out, indent=1, sort_keys=True)
    print(f"{len(casks)} casks -> {dst}")


def main(src):
    casks = json.load(open(src))
    by_token = {c["token"]: c for c in casks}
    keep = [by_token[t] for t in NAMED if t in by_token]
    kinds = {
        "latest": lambda c: c["version"] == "latest" and any("app" in a for a in c.get("artifacts") or []),
        "no_check": lambda c: c.get("sha256") == "no_check" and c["version"] != "latest",
        "nested": lambda c: isinstance(c.get("container"), dict) and "nested" in c["container"],
        "installer": lambda c: any("installer" in a for a in c.get("artifacts") or []),
        "deprecated": lambda c: c.get("deprecated") and not c.get("disabled"),
        "disabled": lambda c: c.get("disabled"),
        "font": lambda c: c["token"].startswith("font-"),
        "variations": lambda c: "arm64_sonoma" in (c.get("variations") or {}),
    }
    for check in kinds.values():
        match = next((c for c in casks if check(c) and c not in keep and c["token"] not in ABSENT), None)
        if match:
            keep.append(match)
    write(keep, FIXTURE)


if __name__ == "__main__":
    main(sys.argv[1])
