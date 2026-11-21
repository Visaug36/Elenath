#!/bin/bash
# Fails when the project breaks one of Elenath's hard rules (see CLAUDE.md, "Architecture"):
#
#   1. No third-party packages: system frameworks only.
#   2. ElenathCore has no UI code: it never imports SwiftUI, AppKit, UIKit or Cocoa.
#   3. The entitlements are exactly the App Sandbox, app-scope bookmarks and user-selected read-write
#      files. No network entitlement and no Private Cloud Compute, so macOS itself keeps notes on the Mac.
#   4. Every public query of Retrieval, the one type that reads the index, is called in SealingLeakTests,
#      so a new query can't be added without proving that it respects sealed spaces.
#   5. No log line makes readable what may hold a note's title or text, a file name or a path: an
#      error's description, a URL, a path, a title, a name or a body is never logged with
#      `privacy: .public`.
#   6. Workflows use actions pinned to a commit, and give their token no more than read access unless a
#      job asks for more itself.
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

# 4. Sealing: every query of Retrieval is asked from every workplace in the leak tests. A query is its name
# and its first argument label, so each overload (notes(in:), notes(tagged:), notes(linkedTo:)) needs its own.
leak_tests=ElenathCoreTests/Index/SealingLeakTests.swift
leak_tests_flat=$(tr '\n' ' ' < "$leak_tests" 2> /dev/null || true)

# Prints "name label" for each public func of the type that starts at $2 in file $1 ("_" for an unlabeled
# first argument, nothing when there are no arguments).
queries_of() {
    awk -v start="$2" '$0 ~ start { inside = 1 } inside' "$1" | tr '\n' ' ' \
        | (grep -oE 'public func [A-Za-z]+\([^:)]*' || true) \
        | sed -E 's/public func ([A-Za-z]+)\([[:space:]]*([A-Za-z_]*).*/\1 \2/' | sort -u
}

# Fails unless every query of $2 (found by queries_of in $1 from $3) is called as `$4.query(label:` in the
# leak tests.
check_queries_asked() {
    local file=$1 type=$2 start=$3 receiver=$4 queries name label pattern
    queries=$(queries_of "$file" "$start")
    if [[ -z "$queries" ]]; then
        fail "Found no queries in $file. Has $type moved?"
        return
    fi
    while read -r name label; do
        if [[ -z "$label" ]]; then
            pattern="${receiver}\\.${name}\\([[:space:]]*\\)"
        elif [[ "$label" == "_" ]]; then
            pattern="${receiver}\\.${name}\\("
        else
            pattern="${receiver}\\.${name}\\([[:space:]]*${label}:"
        fi
        if ! grep -qE "$pattern" <<< "$leak_tests_flat"; then
            shown="${name}(${label:+$label:})"
            fail "$type.$shown is not in $leak_tests. A query that isn't checked there may leak a sealed space."
        fi
    done <<< "$queries"
}

if [[ -f ElenathCore/Index/Retrieval.swift ]]; then
    check_queries_asked ElenathCore/Index/Retrieval.swift Retrieval '^public actor Retrieval' retrieval
fi

# 4b. The calendar's sealing exception: every query of CalendarReach is asked in the leak tests too.
if [[ -f ElenathCore/Calendar/Library/CalendarReach.swift ]]; then
    check_queries_asked ElenathCore/Calendar/Library/CalendarReach.swift CalendarReach '^public struct CalendarReach' \
        calendarReach
fi

# 5. Privacy in logs: what may name the user's notes or files is never public.
leaks=$(grep -rnE --include='*.swift' \
    '(localizedDescription|describing|\.path|[Uu][Rr][Ll]|[Tt]itle|[Nn]ame|[Bb]ody|[Tt]ext|[Pp]rompt|[Ll]ocation|[Nn]otes|[Kk]eywords)[A-Za-z]*(\)[A-Za-z.]*)*, privacy: \.public' \
    Elenath ElenathCore || true)
if [[ -n "$leaks" ]]; then
    fail "These log lines make a title, a text, a file name or a path readable:
$leaks"
fi

# 6. Workflows: pinned actions, read-only tokens by default.
for workflow in .github/workflows/*.yml; do
    unpinned=$(grep -nE '^\s*-?\s*uses:' "$workflow" | grep -vE 'uses:\s*[^@]+@[0-9a-f]{40}(\s|$)' || true)
    if [[ -n "$unpinned" ]]; then
        fail "$workflow uses actions that aren't pinned to a commit:
$unpinned"
    fi
    if ! awk '/^permissions:/ { getline; if ($0 ~ /^  contents: read$/) found = 1 } END { exit !found }' "$workflow"; then
        fail "$workflow must give its token \"contents: read\" at the top; a job that writes asks for it itself."
    fi
done

if [[ $status -eq 0 ]]; then
    echo "The project follows its rules: no packages, no UI code in ElenathCore, sandboxed with no network, every query leak-tested, nothing private logged in the open, pinned workflows."
fi
exit $status
