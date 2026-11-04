cask "octomux" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/anilsenay/octomux/releases/download/v#{version}/Octomux-#{version}.dmg"
  name "Octomux"
  desc "Terminal multiplexer and coding agent manager"
  homepage "https://github.com/anilsenay/octomux"

  livecheck do
    url "https://github.com/anilsenay/octomux/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # Octomux updates itself (Sparkle), so `brew upgrade` leaves it alone unless --greedy.
  auto_updates true
  depends_on macos: :sonoma

  app "Octomux.app"

  # The daemon's launchd agent points into the app. Sessions run in their own processes and outlive it, so an
  # upgrade keeps them: the new app installs the agent again on launch and its daemon picks them up.
  uninstall launchctl: "dev.octomux.daemon",
            quit:      "dev.octomux.app"

  zap launchctl: "dev.octomux.daemon",
      # The sessions (shells and agents) of this install; Octomux Dev runs from "Octomux Dev.app" and is left alone.
      script:    {
        executable:   "/usr/bin/pkill",
        args:         ["-f", "/Octomux.app/Contents/Resources/bin/octomux "],
        must_succeed: false,
      },
      trash:     [
        "~/Library/Application Support/Octomux",
        "~/Library/Caches/dev.octomux.app",
        "~/Library/HTTPStorages/dev.octomux.app",
        "~/Library/HTTPStorages/dev.octomux.app.binarycookies",
        "~/Library/LaunchAgents/dev.octomux.daemon.plist",
        "~/Library/Preferences/dev.octomux.app.plist",
        "~/Library/WebKit/dev.octomux.app",
      ]
end
