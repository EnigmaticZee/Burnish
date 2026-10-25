# Community match overrides

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
