# Community match fixes and update feeds

Burnish matches each installed app to a Homebrew cask by scoring bundle IDs, file names and display names. When it gets one wrong, fix it here for everyone.

`community-overrides.json` maps an app's bundle ID to a cask token, or to `null` when the app has no cask:

```json
{
  "schema": 1,
  "overrides": {
    "com.example.SomeApp": "some-app",
    "com.example.NotInHomebrew": null
  }
}
```

Rules:

- Only add a bundle ID that belongs to exactly one cask. Don't add apps with several channels (stable, beta, ESR) that share a bundle ID; Burnish picks the channel from the installed version.
- Say in the pull request how you checked: the app's `CFBundleIdentifier` (`defaults read /Applications/Foo.app/Contents/Info.plist CFBundleIdentifier`) and the cask page on formulae.brew.sh.
- The user's own corrections in the app always win over this file.

Burnish downloads this file at most once a day from the `main` branch.

## Update feeds

Some apps don't say where they update from and aren't in Homebrew, so Burnish can only say "Can't
check". People can ask for one with **Request Support on GitHub** in the app, which opens a
ready-made issue. If you know where such an app announces its updates, add it under `feeds`:

```json
{
  "schema": 1,
  "overrides": {},
  "feeds": {
    "com.example.SparkleApp": { "sparkle": "https://example.com/appcast.xml" },
    "com.example.GitHubApp": { "github": "owner/repository" }
  }
}
```

- `sparkle` is the app's Sparkle appcast, over HTTPS. `github` is the repository whose releases
  are the app's releases.
- Feeds are only used for apps with no feed of their own and no confident Homebrew match.
- Burnish reads these feeds to spot updates and show release notes, and never installs from them:
  the person gets the developer's download page instead. That keeps the first of Burnish's
  promises (only install from the app's own feed or Homebrew's data) intact.
- In the pull request, link the developer's page that shows the feed or repository is theirs.
