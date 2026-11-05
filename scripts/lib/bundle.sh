# shellcheck shell=bash
# Assembling and signing "Shiibar GH.app", shared by scripts/dev-install.sh
# and scripts/release/build-release-app.sh so both use one bundle layout and
# one signing order. Sourced, not executed.
#
# The app is an LSUIElement menu bar app. The daemon and the CLI live in
# Contents/Helpers/ (docs/tasks/M3.md, "Daemon lifecycle"). Every executable
# in the bundle is signed with the same flags, because notarization needs
# the hardened runtime on all of them. The signing identifiers never change:
# Keychain access and the notification permission are tied to them
# (docs/DESIGN.md, "Distribution and signing").

_BUNDLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC2034 # used by the scripts that source this file
APP_NAME="Shiibar GH.app"
APP_EXECUTABLE="ShiibarGhApp"
BUNDLE_ID="shiibar.gh"
DAEMON_ID="shiibar.gh.daemon"
CLI_ID="shiibar.gh.cli"

# The [workspace.package] version of the root Cargo.toml, the one source of
# the version.
read_workspace_version() {
  local cargo_toml="$1"
  awk '
    /^\[workspace\.package\]/ { in_section = 1; next }
    /^\[/ { in_section = 0 }
    in_section && /^version[[:space:]]*=/ {
      gsub(/^version[[:space:]]*=[[:space:]]*"/, "")
      gsub(/".*$/, "")
      print
      exit
    }
  ' "$cargo_toml"
}

# assemble_app_bundle <app_path> <app_bin> <daemon_bin> <cli_bin> <version> <bundle_version>
assemble_app_bundle() {
  local app_path="$1" app_bin="$2" daemon_bin="$3" cli_bin="$4"
  local version="$5" bundle_version="$6"

  rm -rf "$app_path"
  mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Helpers" "$app_path/Contents/Resources"

  install -m 755 "$app_bin" "$app_path/Contents/MacOS/$APP_EXECUTABLE"
  install -m 755 "$daemon_bin" "$app_path/Contents/Helpers/shiibar-ghd"
  install -m 755 "$cli_bin" "$app_path/Contents/Helpers/shiibar-gh"

  cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$APP_EXECUTABLE</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>Shiibar GH</string>
	<key>CFBundleDisplayName</key>
	<string>Shiibar GH</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$bundle_version</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 Mitsuyuki Shiiba — MIT OR Apache-2.0</string>
</dict>
</plist>
PLIST

  # A subshell keeps the EXIT trap for the work directory local.
  (
    icon_workdir="$(mktemp -d)"
    trap 'rm -rf "$icon_workdir"' EXIT
    swift "$_BUNDLE_LIB_DIR/../generate-app-icon.swift" "$icon_workdir"
    iconutil -c icns "$icon_workdir/AppIcon.iconset" -o "$icon_workdir/AppIcon.icns"
    install -m 644 "$icon_workdir/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
  )
}

# sign_app_bundle <identity> <app_path> [extra codesign flags...]
#
# The helpers first, the bundle last, so the bundle's seal covers the signed
# helpers. Extra flags (--options runtime --timestamp for notarization) go to
# every call.
sign_app_bundle() {
  local identity="$1" app_path="$2"
  shift 2
  codesign --force --sign "$identity" "$@" --identifier "$DAEMON_ID" "$app_path/Contents/Helpers/shiibar-ghd"
  codesign --force --sign "$identity" "$@" --identifier "$CLI_ID" "$app_path/Contents/Helpers/shiibar-gh"
  codesign --force --sign "$identity" "$@" --identifier "$BUNDLE_ID" "$app_path"
}
