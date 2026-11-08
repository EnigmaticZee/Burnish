# Version history

## 0.5.1-beta — 2026-11-08
A nameplate on the desk, and Homebrew at the door.

+ Install Burnish with Homebrew: `brew install --cask enigmaticzee/tap/burnish`.
+ Burnish is made by Polite Owl, part of Observant Systems, and Settings now says so.
+ Scanning does less work: each app's program file is read once, not three times.
+ Fixes for a settings file read at a bad moment, a cancelled password prompt, an Electron app
  with a space in its update address, and installer packages that never left.

- **Fixed: a settings file that couldn't be read was treated as empty, then written over.** If a
  file in Burnish's folder, your ignore rules say, or an app's history, couldn't be read for a
  moment, Burnish took that as "nothing saved yet" and the next change wrote a fresh file over it.
  Only a file that genuinely isn't there counts as empty now; any other trouble is left alone and
  noted in the log.
- **Fixed: a cancelled password prompt was recognised by the wrong clue.** When an update needed
  admin rights and you cancelled, Burnish knew by the digits "-128" appearing anywhere in the
  system's reply, so a real failure whose message happened to contain them would have been shown
  as a cancellation, with no explanation. Burnish now reads the code the way macOS writes it.
- **Fixed: a check could stop on an Electron app with a space in its update address.** An app
  whose update settings name a storage bucket with a space in it brought the whole check down.
  Burnish now marks that feed as unreadable and carries on with the rest.
- **Install Burnish with Homebrew.** `brew install --cask enigmaticzee/tap/burnish` puts the same
  notarised app in Applications, and Burnish keeps updating itself from there, so `brew upgrade`
  leaves it alone.
- **Made by Polite Owl.** Burnish is published by Polite Owl, part of Observant Systems, and the
  Settings window says so under the version number. The front desk has a nameplate.
- **Scanning reads each app once.** Working out what an app is took up to three reads of its
  program file; it's one now, and matching apps installed with Homebrew to their names takes one
  pass instead of one per app. The detail pane also stops re-reading release notes and checking the
  disk every time it redraws.
- **Installer packages don't pile up.** A `.pkg` that Burnish hands to Apple's Installer is kept
  for a day so Installer can read it, then removed. They used to stay in Burnish's folder for good.
- **Save Diagnostics says so when the file couldn't be written.** It used to fail quietly.

## 0.5.0-beta — 2026-11-01
Opens like any other app.

+ Burnish is signed with a Developer ID and notarised by Apple, so it opens with no warning.
+ The app wears its own colour now: brass toggles, seals and a gradient progress bar.
+ The accuracy numbers on the website come from a Homebrew sample that refreshes itself every
  month.

- **Notarised by Apple.** Every release is now signed with a Developer ID and checked by Apple's
  notary service before it's published, with Apple's ticket stapled to the download. Download, drag,
  open: no "Open Anyway", no Terminal command. If you installed an earlier beta the hard way,
  there's nothing to undo; this update arrives through Burnish like any other, signed with the same
  update key as before.
- **Brass, not blue.** Toggles, menus, the hallmark seals and the Show all link take Burnish's own
  colour, matched to the website in light and dark, and progress bars draw the same brass gradient
  as the website's hero. A finished install gets a brass seal.
- **A ledger that stays current.** The *Never guesses* numbers on the website are measured against
  a sample of Homebrew's list. A job now re-cuts that sample on the first of every month and runs
  every test against it, so the date on the card stays within a month of today with nobody
  touching it.

## 0.4.1-beta — 2026-11-01
Brave's update opens now.

+ Brave's update installs; its disk image was being mistaken for a tarball.
+ Any disk image is recognised however it's compressed, and a misread download gets a second try
  with the other openers.
+ Every download format now goes through the real unpacker on every test run.
+ A download Burnish still can't open gets a one-click report with the file's facts filled in.

- **Fixed: Brave's update was refused with "The download couldn't be opened".** Brave ships an
  lzma-compressed disk image, which begins with the same bytes as a `.tar.xz`, so Burnish handed it
  to the wrong tool; iStripper's bzip2 image would have gone the same way. The checksum had already
  matched and nothing on the Mac was touched; the update simply didn't happen. Burnish now
  recognises a disk image by the trailer every one of them ends with, before it reads the first
  bytes.
- **A misread download gets a second try.** When the tool Burnish picked can't open a download,
  the other openers each get a turn before it gives up, and the file's name settles it when the
  bytes say nothing. A wrong guess now costs a second, not the install. When a tool does fail, the
  reason shown is its answer, not the warnings it printed on the way, and an image that macOS is
  busy attaching elsewhere gets a moment and another go.
- **Apps kept in a folder on a disk image are found.** An image with the app inside a folder used
  to come up empty.
- **Every format, through the real tools, on every test run.** Burnish's tests now build disk
  images in all six compressions, zips, gzip, bzip2 and xz tarballs and installer packages with
  the system's own tools, and open each with the real unpacker, so a change in any of them shows up
  before a release does.
- **A download Burnish can't open gets a ready-made report.** The refusal keeps the file's facts:
  its name and size, its first bytes, how it was read. *Report This on GitHub…* opens an issue with
  those filled in and nothing about you or your other apps, so a fix can start from the report
  alone.

## 0.4.0-beta — 2026-11-01
Feeds found, feeds added.

+ Apps that keep their update feed inside the app itself, not in their Info.plist, get checked now.
+ Know where an app announces its updates? Add the feed yourself, and share it with everyone in one
  click.
+ Settings → Privacy can save a diagnostics file for bug reports. Nothing is sent anywhere.
+ The menu bar list is back for anyone with six or more updates waiting.

- **Feeds written into the app count too.** Some Sparkle apps hand their feed address to Sparkle in
  code rather than in Info.plist, so to Burnish they looked feedless. Burnish now reads the address
  out of the app's own executable, inside the same signed bundle, and asks that feed, keeping it
  only when the feed plainly belongs to the app: it names the app, or it lists the version you
  have. The hallmark reads *Found inside the app, which names it.* On the Mac Burnish is built on,
  that moved iStripper from *Can't check* to an update.
- **Add an app's feed yourself.** An app under *Can't check* (Apple's and App Store apps aside)
  offers *Add Update Feed…*, which takes a Sparkle appcast address or a GitHub repository. Burnish
  reads it to spot new versions and opens the developer's download page; it never installs from a
  feed the app didn't name itself. *Share This Feed…* opens a ready-made GitHub issue so everyone
  with that app gets the feed. Burnish is made by one person, so those land in batches. This
  replaces *Request Support on GitHub*.
- **Save a diagnostics file.** Settings → Privacy → *Save Diagnostics…* writes one text file:
  Burnish's version, your settings, the last check, each app's history and Burnish's recent log
  lines. It names the apps on your Mac, so you choose where it goes, and nothing leaves the Mac
  unless you attach it to a bug report. The command line has `burnish diagnostics` for the same.
- **Every release carries its accuracy report.** The test run's numbers, the apps checked against a
  dated Homebrew snapshot and the false alerts among them (none), are attached to each release and
  shown on the website's *Never guesses* card, in place of a sentence we wrote ourselves.
- **Fixed: the menu bar list went missing past five updates.** With six or more updates waiting,
  the menu bar window showed its header and its buttons and nothing in between, and had since
  0.1.0-alpha. The bell rang, but the desk was empty. The list is back, and scrolls when it's long.
- **Fixed: VoiceOver read each hallmark's explanation two or three times.** Once is plenty.

## 0.3.2-beta — 2026-10-26
Same app, right chip.

+ Burnish now refuses an update that won't run on your Mac's chip.
+ An app that runs natively on Apple silicon is never swapped for one that needs Rosetta.
+ Apps Burnish can't check get a button to ask for them to be covered.

- **Updates must be built for your Mac.** Before replacing anything, Burnish now reads which chips
  the new copy is built for. It refuses one that won't run on this Mac's processor, one that would
  trade an app running natively on Apple silicon for an Intel-only build that needs Rosetta, and
  one whose chips it can't read, and offers the developer's download page instead. An app that's
  already Intel-only can still update to another Intel-only version, and every update's hallmarks
  now include *Built for this Mac*.
- **Ask for an app to be covered.** Apps under *Can't check*, other than Apple's and App Store
  apps, get *Request Support on GitHub*. It opens a ready-made issue with the app's name, bundle ID
  and version, and nothing is sent until you submit it. Know where the app posts its updates? Say
  so, and it can become a community feed for everyone.

## 0.3.1-beta — 2026-10-26
Tidier, and better at taking a hint.

+ Updates you can install with one click now sit together, apart from the ones you download
  yourself.
+ What's New opens right here on your Mac, not on a web page.
+ An app's details step aside when you click somewhere else.
+ Hallmarks lead with the three that matter, and the rest fold away.
+ Settings fits on the screen now, in four tabs.

- **Updates are grouped by who does the work.** *Ready to install* holds everything one click and
  Update All can do. *Major upgrades*, *Updated elsewhere* (the App Store, Homebrew or a
  developer's own updater) and *Download yourself* follow, each sorted by name. The menu bar list
  does the same.
- **What's New stays on your Mac.** It used to open Burnish's releases page on GitHub. Now it opens
  a window with this version's notes: the short version first, the full notes folded away,
  earlier versions underneath, and nothing downloaded. It's in the menu bar's ⋯ menu and in
  Settings too.
- **Details know when to leave.** An app's details close when you click an empty part of the list,
  switch tabs or switch to another app, so Escape is now optional.
- **Hallmarks, folded.** Each update shows the three hallmarks that matter most, and anything worth
  knowing is always one of them. *Show all* opens the rest under headings, in the order the install
  checks them, with the way back last.
- **Settings in four tabs.** General, Updates, Sources and Privacy, in a normal-sized window that
  opens in front of whatever you were using, instead of one very tall column. Privacy lists every
  place Burnish talks to.
- **Fixed:** a hallmark pointed at "the checks below" while they sat above it.

## 0.3.0-beta — 2026-10-25
Burnish now shows its working.

+ Every update lists where it comes from and the checks it has to pass before it goes in.
+ Minor updates can install themselves, after a wait you choose.
+ Release notes get a quick read up top, plus what you missed if you skipped a few versions.
+ Apps that only run on Intel get flagged while there's still time.
+ Each app can have its own rules: stay on version 5, try the betas, or just let me know.

- **Every update shows its hallmarks.** An app's details now list where the download comes from
  and each check it has to pass before Burnish installs it: the developer's signature, the
  published checksum, the same developer as your copy, Gatekeeper. A check the source can't offer
  says so instead of quietly passing, and the app's history records which ones ran. Like the marks
  stamped on silver, only for apps.
- **Updates can install themselves, but only the boring ones.** Turn on automatic updates in
  Settings and Burnish installs minor updates for apps that aren't open, once they've been out as
  long as you choose: three days unless you say otherwise. Security updates skip the wait. Major
  upgrades, anything Burnish can't install with every check, and anything at all on Low Data Mode
  still wait for you.
- **Rules for each app.** In an app's details you can have its updates installed automatically or
  only announced, stay on the major version you have, or include beta releases where the
  developer publishes them.
- **A quick read of the release notes.** Burnish sorts the developer's notes into security fixes,
  new things, fixes and improvements, and shows the first few, clearly marked as a summary. It
  only ever repeats what the developer wrote, and the full notes sit folded underneath. Skipped a
  few versions? It lists what each one brought.
- **Intel-only apps get flagged.** Apps built only for Intel chips run through Rosetta, which Apple
  is retiring for most apps after macOS 27. Burnish marks them and says how many you have, so
  there's time to find a newer build or a replacement.
- **The community can point Burnish at feeds apps forget to mention.** A line in this repository's
  community file lets Burnish check an app that names no update feed and isn't in Homebrew. It
  shows the new version and its notes, then leaves the install to you, because the app never named
  that feed itself.
- **A longer way back.** Turn on *Keep earlier versions* and the version an update replaces waits
  in Burnish's own folder for 30 days, so emptying the Trash doesn't take Put Back with it. After
  that it goes to the Trash.
- **Shortcuts and links.** `burnish://check`, `burnish://update-all` and `burnish://open` work from
  Shortcuts' Open URL, the `burnish` command-line tool now ships inside the app with a new `count`
  command, and the daily notification has an Update All button.
- **IT can set Burnish up once.** Settings delivered in a configuration profile are applied and
  shown as set by your organisation. [The admin guide](https://github.com/EnigmaticZee/Burnish/blob/main/docs/ADMINS.md) lists every key.
- **Details open when you ask for them.** The list gets the whole window until you pick an app,
  and Escape puts the details away again. Right-click any app, in the window or the menu bar, to
  update it, ignore it or show it in Finder.
- **Fixed:** notices about being offline or needing App Management no longer sit on top of the
  sidebar's search field.

Nothing to do: Burnish updates itself as usual, and automatic updates stay off until you turn them
on.

## 0.2.0-beta — 2026-10-25
Now accepting returns.

+ Changed your mind about an update? Put the old version back in one click.
+ A desktop widget keeps count of what's waiting.
+ Office, Adobe, Setapp and JetBrains apps now open their own updaters.
+ Tauri apps finally get checked, and App Store updates go in one trip.

- **Put back the version you had before.** Every update already left the old copy in the Trash;
  now Burnish remembers which one and brings it back in one click, after checking it as carefully
  as a fresh download. It then skips the version you rolled back from, so Update All doesn't undo
  the undo.
- **A history for every app.** Updates found, installs, hand-offs and refusals, newest first, kept
  on your Mac.
- **A desktop widget.** How many updates are waiting, and in the medium size, which ones.
- **Apps with their own updater get it.** Office opens Microsoft AutoUpdate, Adobe apps open
  Creative Cloud, and Setapp and JetBrains apps open Setapp and Toolbox, instead of a download
  page.
- **Tauri apps get checked too.** Burnish finds the update address compiled into the app and asks
  it; the app installs the update itself. They used to wait in *Can't check*, looking left out.
- **App Store updates in one trip.** With several waiting, one click opens the App Store's
  Updates page, where Apple's Update All does them together.
- **Fixed:** error messages no longer say "Feed not reachable" twice in one breath, the welcome
  screen now lists every place Burnish talks to (it was four short), and the disk image has
  proper art and passes strict signature checks.

On the command line, `burnish restore` and `burnish history` do the same as the app. Every word
Burnish shows now lives in a string catalog, ready for translators once the interface settles.

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
an app to the wrong thing, use **Wrong Match? → Report a Wrong Match on GitHub** in the app and it
opens a ready-made issue.
