cask "burnish" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/EnigmaticZee/Burnish/releases/download/v#{version}/Burnish-#{version}.dmg"
  name "Burnish"
  desc "Finds and installs updates for apps from any source"
  homepage "https://github.com/EnigmaticZee/Burnish"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Burnish.app"

  uninstall quit: "io.github.enigmaticzee.Burnish"

  zap trash: [
    "~/Library/Application Support/Burnish",
    "~/Library/Caches/io.github.enigmaticzee.Burnish",
    "~/Library/HTTPStorages/io.github.enigmaticzee.Burnish",
    "~/Library/Preferences/io.github.enigmaticzee.Burnish.plist",
  ]
end
