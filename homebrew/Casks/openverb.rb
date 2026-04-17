cask "openverb" do
  version "1.0.0"
  sha256 "TBD_PIN_BEFORE_RELEASE"

  url "https://github.com/openverb/openverb/releases/download/v#{version}/OpenVerb-#{version}.dmg"
  name "OpenVerb"
  desc "100% local voice-to-text for macOS"
  homepage "https://github.com/openverb/openverb"

  depends_on macos: ">= :ventura"

  app "OpenVerb.app"

  postflight do
    # Create model directory
    system_command "/bin/mkdir", args: ["-p", "#{Dir.home}/.openverb/models"]
  end

  zap trash: [
    # UserDefaults plist written by NSUserDefaults with the app's bundle ID.
    # LaunchAgent is NOT included — OpenVerb does not register a LaunchAgent.
    "~/Library/Preferences/io.openverb.app.plist",
    "~/.openverb",
  ]
end
