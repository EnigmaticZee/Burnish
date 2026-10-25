#!/usr/bin/env python3
"""Cut the test fixtures out of Homebrew's full cask list.

Usage: scripts/make-cask-fixture.py cask.json

Writes Tests/CaskIndexTests/Fixtures/casks.json: the casks the matcher tests name, plus the first
cask of each tricky kind (version "latest", no checksum, .pkg, nested container, vendor installer,
deprecated, disabled, font) so the parser sees every shape. Also writes the much smaller
Tests/BurnishCoreTests/Fixtures/casks.json with just the apps the end-to-end checker test uses.
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
# The end-to-end checker test: Chrome, Firefox, AdGuard and Discord with their channels, and PasteNow.
CORE = [t for t in NAMED if t.split("@")[0] in ("google-chrome", "firefox", "adguard", "discord", "pastenow")]
MATCHER_FIXTURE = "Tests/CaskIndexTests/Fixtures/casks.json"
CORE_FIXTURE = "Tests/BurnishCoreTests/Fixtures/casks.json"


def write(casks, dst):
    with open(dst, "w") as out:
        json.dump(casks, out, indent=1, sort_keys=True)
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
        "font": lambda c: c["token"].startswith("font-"),
        "variations": lambda c: "arm64_sonoma" in (c.get("variations") or {}),
    }
    for check in kinds.values():
        match = next((c for c in casks if check(c) and c not in keep), None)
        if match:
            keep.append(match)
    write(keep, MATCHER_FIXTURE)
    write([by_token[t] for t in CORE if t in by_token], CORE_FIXTURE)


if __name__ == "__main__":
    main(sys.argv[1])
