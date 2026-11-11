#!/bin/bash
# Fails when the project breaks one of Elenath's hard rules (see CLAUDE.md, "Architecture"):
#
#   1. No third-party packages: system frameworks only.
#   2. ElenathCore has no UI code: it never imports SwiftUI, AppKit, UIKit or Cocoa.
#   3. The entitlements are exactly the App Sandbox, app-scope bookmarks and user-selected read-write
#      files. No network entitlement and no Private Cloud Compute, so macOS itself keeps notes on the Mac.
#
# Given an app bundle, it also checks the entitlements that app is really signed with. Use a Release
# build for that: Xcode adds a debugging entitlement to Debug builds.
#
#   scripts/check-rules.sh [path/to/Elenath.app]
set -euo pipefail

cd "$(dirname "$0")/.."
app="${1:-}"
status=0

fail() {
    echo "::error::$1"
    status=1
}

# 1. No Swift packages.
if grep -qE 'XC(Remote|Local)SwiftPackageReference|XCSwiftPackageProductDependency' Elenath.xcodeproj/project.pbxproj; then
    fail "The Xcode project references a Swift package. Elenath uses system frameworks only."
fi
if [[ -e Package.swift || -e Package.resolved ]]; then
    fail "Found a Swift package manifest. Elenath has none."
fi

# 2. ElenathCore stays free of UI code.
ui_imports=$(grep -rnE '^[[:space:]]*(@[A-Za-z]+[[:space:]]+)*import[[:space:]]+(SwiftUI|AppKit|UIKit|Cocoa)([[:space:]]|$)' ElenathCore || true)
if [[ -n "$ui_imports" ]]; then
    fail "ElenathCore imports a UI framework:"$'\n'"$ui_imports"
fi

# 3. Entitlements.
allowed="com.apple.security.app-sandbox
com.apple.security.files.bookmarks.app-scope
com.apple.security.files.user-selected.read-write"

check_entitlements() {
    # $1: what is being checked; standard input: an entitlements property list as XML.
    local keys
    keys=$( (grep -oE '<key>[^<]+</key>' || true) | sed -E 's/<\/?key>//g' | sort)
    if [[ "$keys" != "$allowed" ]]; then
        fail "$1 must have exactly the sandbox, bookmark and user-selected-files entitlements, but has:"$'\n'"${keys:-(none)}"
    fi
}

check_entitlements "Config/Elenath.entitlements" < Config/Elenath.entitlements
if [[ -n "$app" ]]; then
    signed=$(codesign -d --entitlements - --xml "$app" 2> /dev/null || true)
    check_entitlements "$app" <<< "$signed"
fi

if [[ $status -eq 0 ]]; then
    echo "The project follows its rules: no packages, no UI code in ElenathCore, sandboxed with no network."
fi
exit $status
