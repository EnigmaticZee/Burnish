# Version history

## 0.1.0-alpha — 2026-10-25
First light. Burnish is ready for people who like to try things early.

- **Finds updates for apps from anywhere.** Direct downloads, the Mac App Store and Homebrew,
  checked against each app's own update feed first and Homebrew's public app list second, so the
  version you see is the developer's own wherever it can be.
- **Tells you when it isn't sure.** Apps it can't match confidently wait under *Needs
  confirmation*, and anything it can't check says why. It would rather miss an update than raise a
  false alarm.
- **Updates safely, one click at a time or all at once.** Every download is checked for the
  developer's signature, its checksum and Apple's notarisation before anything changes, apps are
  asked politely to quit (never forced), and the old version goes to the Trash in case you want it
  back.
- **Leaves paid upgrades to you.** A jump like 5.x to 6.x is marked *May be paid* and never
  included in Update All.
- **Keeps itself up to date**, quietly, the same careful way.

This is an alpha: detection has been tested on a handful of Macs, not hundreds. If Burnish matches
an app to the wrong thing, use **Wrong match? → Report** in the app and it opens a ready-made issue.
