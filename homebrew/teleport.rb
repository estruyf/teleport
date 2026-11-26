cask "teleport" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/estruyf/teleport/releases/download/v#{version}/Teleport-#{version}-arm64-mac.zip"
  name "Teleport"
  desc "Use the apps on another Mac as if they were right here"
  homepage "https://github.com/estruyf/teleport"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Teleport updates itself with Sparkle from the appcast on the latest release, so `brew upgrade`
  # leaves it alone rather than race the in-app updater. A host installs updates on its own while
  # no viewer is connected. The tap still moves on every release, which is what `--greedy` and a
  # fresh `brew install` read.
  auto_updates true
  # Only an Apple Silicon build is released, and LSMinimumSystemVersion is 14.0.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Teleport.app"

  # A host runs from the menu bar without a Dock icon, so an upgrade would otherwise replace the
  # bundle under a copy that is still running.
  uninstall quit: "ai.teleport.app"

  # ~/.teleport holds this Mac's device key, its pairings and settings: after a zap, paired Macs
  # have to pair again. Files received through portals (~/Downloads/Teleport) are left alone.
  zap trash: [
    "~/.teleport",
    "~/Library/Caches/ai.teleport.app",
    "~/Library/HTTPStorages/ai.teleport.app",
    "~/Library/Preferences/ai.teleport.app.plist",
    "~/Library/Saved Application State/ai.teleport.app.savedState",
  ]
end
