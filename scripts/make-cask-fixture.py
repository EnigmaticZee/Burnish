#!/usr/bin/env python3
"""Cut a small test fixture out of Homebrew's full cask list.

Usage: scripts/make-cask-fixture.py cask.json Tests/CaskIndexTests/Fixtures/casks.json

Keeps the casks the matcher tests name, plus the first cask of each tricky kind
(version "latest", no checksum, .pkg, nested container, vendor installer,
deprecated, disabled, font) so the parser sees every shape.
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


def main(src, dst):
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
    with open(dst, "w") as out:
        json.dump(keep, out, indent=1, sort_keys=True)
    print(f"{len(keep)} casks -> {dst}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
