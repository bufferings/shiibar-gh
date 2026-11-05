# Cask template for the bufferings/homebrew-tap release of Shiibar GH.
#
# A template, not a valid cask: .github/workflows/bump-cask.yml replaces
# {{VERSION}} and {{SHA256}} when it renders this file into
# Casks/shiibar-gh.rb of bufferings/homebrew-tap for a published release.
# CI renders it with dummy values and runs `brew style --cask` on it.
#
# Apple Silicon only, macOS 14 or later (docs/DESIGN.md, "Distribution and
# signing").
cask "shiibar-gh" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/bufferings/shiibar-gh/releases/download/v#{version}/shiibar-gh-#{version}-arm64.zip"
  name "Shiibar GH"
  desc "Menu bar app for the GitHub pull requests you are involved in"
  homepage "https://github.com/bufferings/shiibar-gh"

  depends_on arch:  :arm64
  depends_on macos: :sonoma

  app "Shiibar GH.app"
  binary "#{appdir}/Shiibar GH.app/Contents/Helpers/shiibar-gh"

  # A daemon whose socket file is gone cannot be stopped by quitting the
  # app, so it is stopped by its command line. The app always starts it as
  # "<appdir>/Shiibar GH.app/Contents/Helpers/shiibar-ghd --foreground", and
  # `pkill -x` matches the whole command line only, so a process that merely
  # names the path is left alone.
  uninstall_postflight_steps do
    run "/usr/bin/pkill",
        args:         ["-xf", "/.*/Shiibar GH\\.app/Contents/Helpers/shiibar-ghd --foreground"],
        must_succeed: false
  end

  uninstall quit: "shiibar.gh"

  zap trash: [
    "~/.local/state/shiibar-gh",
    "~/Library/Preferences/shiibar.gh.plist",
  ]

  caveats <<~EOS
    Open Shiibar GH once: it asks for the notification permission and
    registers itself to launch at login. Add your tokens in Settings ›
    Scopes. The tokens stay in the Keychain (service shiibar-gh) after an
    uninstall; remove them with `shiibar-gh scope remove` before
    uninstalling, or in Keychain Access.
  EOS
end
