#!/bin/bash
# Builds a Release of Elenath from this checkout and installs it in /Applications.
#
#   scripts/install.sh            build and install
#   scripts/install.sh --open     …and open it afterwards
#
# The build is ad-hoc signed ("Sign to Run Locally"), which is all a Mac needs for an app you built yourself.
# Your notes live in the folder you chose in Elenath, so reinstalling never touches them.
set -euo pipefail

cd "$(dirname "$0")/.."

open_after=false
if [[ "${1:-}" == "--open" ]]; then
    open_after=true
fi

if ! command -v xcodebuild > /dev/null; then
    echo "xcodebuild not found. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

derived_data="build/InstallDerivedData"
echo "Building Elenath (Release, Apple silicon)…"
xcodebuild build \
    -project Elenath.xcodeproj -scheme Elenath -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    -quiet

app="$derived_data/Build/Products/Release/Elenath.app"
if [[ ! -d "$app" ]]; then
    echo "The build finished but $app is missing." >&2
    exit 1
fi

if pgrep -x Elenath > /dev/null; then
    echo "Quitting the running Elenath…"
    osascript -e 'tell application id "io.github.visaug36.Elenath" to quit' || true
    for _ in $(seq 1 50); do
        pgrep -x Elenath > /dev/null || break
        sleep 0.1
    done
fi

destination="/Applications/Elenath.app"
if [[ -d "$destination" ]]; then
    echo "Replacing $destination (the old copy goes to the Trash)…"
    osascript -e "tell application \"Finder\" to delete POSIX file \"$destination\"" > /dev/null
fi
ditto "$app" "$destination"
echo "Installed $destination"

if $open_after; then
    open "$destination"
fi
