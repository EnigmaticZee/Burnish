# Benchmark

How Burnish does on a real Mac, recorded so changes to detection can be compared over time.
Run `swift run burnish check --csv` and note the totals; to compare with another updater, run it on
the same Mac at the same time.

## Detection — 24 Oct 2026, macOS 27.0.1, 25 apps

| | |
| --- | --- |
| Updates found | 7 (4 from Homebrew's data, 1 from a developer's Sparkle feed, 1 from the App Store, 1 from Homebrew for a Chromium-based browser with a prefixed version) |
| False "update available" alerts | 0 (each update checked against the developer's own site or the App Store) |
| Apps matched to an update source | 21 of 25 (21 of 24 not counting an Apple app that macOS updates) |
| Needs confirmation | 1 (a helper app that only shares a bundle-ID hint with its parent's cask) |
| Can't check | 4 (two apps with no public update source, one in-house app, one Apple app) |

The first real install, using `burnish update`: an Electron app went from 0.0.416 to 0.0.419. The
download's checksum, the code signature, Gatekeeper's notarisation check and the Team ID were all
verified, and the old copy went to the Trash.

## Performance — release build, Apple silicon

| Metric | Target | Measured |
| --- | --- | --- |
| Full check, warm cache (25 apps) | under 10 s for 150 apps | 0.4–0.9 s |
| Full check, cold (downloads the 19 MB cask list) | — | 2.2 s |
| Inventory scan (25 apps, with code-signature reads) | — | 0.28 s |
| Idle memory after a check (menu bar app) | under 60 MB | 43 MB footprint |

This Mac has 25 apps, not 150. Feed requests run eight at a time with a 10-second timeout, so the
150-app figure still needs a run on a fuller Mac.
