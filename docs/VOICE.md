# How Burnish talks

Burnish's commits and release notes should be a pleasure to read. Some apps have shown that release
notes can be funny; we want notes that are funny **and** still tell you exactly what changed. Skip
every joke and you should lose nothing but the fun.

Inside the app, copy stays plain and calm (no exclamation marks, no confetti). The personality
lives here: commit messages, release notes, tag messages and pull request descriptions.

## The rules

1. **Fact first, wink second.** The first words say what changed. The wink, if there is one, comes
   after and never replaces it.
2. **The joke comes from the change.** Find what's actually funny about *this* bug or feature: an
   app pretending to ship on GitHub, a closure borrowing a name before it existed. No stock quips
   that would fit any commit, and no "polished to a shine" filler.
3. **One wink per item, at most.** Plenty of items have none. Plain, plain, then a good line reads
   better than a joke in every sentence.
4. **Our world is brass and a front-desk bell.** A concierge who notices things, rings once and
   keeps a tidy desk. Use it sparingly: once per release, not once per line.
5. **Some things are never funny.** Security fixes, data loss, a refused install, anything that
   cost someone time. Say plainly what happened, who was affected and what to do.
6. **Never punch down.** Not at the people using Burnish, not at other developers, not at other
   apps.
7. **Specific beats clever.** "Checks 150 apps in two seconds" beats "blazing fast". Name the app,
   the version, the thing that broke.
8. **Short.** If a line needs a second read, rewrite it.
9. **British spelling,** to match the rest of the project: recognise, notarisation, colour.
10. **Easy on the emoji.** None in commits. At most one in a release, and only if it earns it.

## Commits

- **Subject:** imperative mood ("Teach", "Stop", "Let"), says what changed, 72 characters at most,
  no full stop. It can carry the wink.
- **Body:** a blank line, then what changed and why in plain sentences, including what someone
  using Burnish will notice. Wrap around 72–100 characters.
- No attribution trailers.

| Instead of | Write |
| --- | --- |
| `Fix bug` | `Stop treating "latest" as a version number newer than everything` |
| `Update UpdateChecker.swift` | `Declare client before the closure borrows it` |
| `Polish things ✨` | `Teach the menu bar bell to ring while it checks` |
| `Fix DMG` | `Stop the DMG smuggling Finder info past codesign` |
| `Demo data tweak` | `Let Figma stop pretending it ships on GitHub` |

A full example:

```
Stop the DMG smuggling Finder info past codesign

dmgbuild's hide_extensions wrote com.apple.FinderInfo onto Burnish.app, and strict signature
checks reject any bundle carrying it. Finder hides .app on its own, so the setting goes and the
app inside the DMG now passes codesign --verify --strict.
```

## Release notes

`docs/HISTORY.md` is the single source: it becomes the GitHub release, the update window inside
Burnish and the "What's new" section of the website, so every entry has to read well in a small
window. Short paragraphs, no tables, no headings inside an entry.

**Write for the person using Burnish, not for us.** No module names, no "refactored", no
"improved performance" without saying what got faster. If someone who has never seen the code
can't tell what changed for them, rewrite it.

**The size of the release sets the tone.**

- **A big release** (new features people will notice) stays clear: lead with what's new, one
  bold line each, and keep the jokes for the headline and maybe one item.
- **A small release** (fixes, polish, nothing anyone would plan their day around) is where the
  fun lives. Every fix still says exactly what used to go wrong, but each one can carry its own
  wink, and the headline can be pure play. Safety and security fixes stay plain even here.

- **Open with one line** that sets the mood, like a headline: "First light." Not a paragraph.
- **Then the short version:** three to five lines starting with `+ `, one plain sentence each, for
  people who only skim. No bold, no jargon, fun allowed: "Changed your mind about an update? Put
  the old version back in one click." The website shows it as a summary card with the full
  notes folded away underneath; the GitHub release and the update window put it first.
- **Each item:** a bold line saying what changed for the person, then a sentence or two on why it
  matters, with at most one wink.
- **Order:** anything about safety or security first (plain), then new things, then improvements,
  then fixes.
- **Fixes describe what used to go wrong, in the person's terms:** "Apps with a space in their
  name could land in *Can't check*", not "fixed path escaping in Inventory".
- **End with anything the person needs to do,** if anything. Usually nothing.

Examples (made up, to show the shape):

> **Put back the version you had before.** Every update already left the old copy in the Trash;
> now Burnish remembers which one it was and brings it back in one click. Second thoughts are
> allowed.

> **Tauri apps get checked too.** They used to wait in *Can't check*, looking left out.

A small release, whole:

> ## 0.2.1-beta — 2026-11-02
> Small fixes, big feelings.
>
> - **Discord no longer claims to be two apps.** Having Discord and Discord Canary installed made
>   the Updates list show Discord twice; it had been reading the Canary's version for both.
> - **The widget wakes up after a restart.** It used to say "Open Burnish to check your apps"
>   until the next daily check, even though Burnish had checked an hour ago.
> - **"Checked just now" stays honest.** It no longer says "just now" for an hour.

> **Fixed: an update feed that redirected to a different website was followed without warning.**
> Burnish now stops and offers the developer's download page instead. If you updated an app from
> a feed like this, it was still verified against the developer's signature before installing.
