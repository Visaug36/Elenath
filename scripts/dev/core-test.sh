#!/bin/bash
# Lints the Swift sources and runs ElenathCore's tests with the open-source Swift toolchain, without Xcode.
# ElenathCore has no UI code and builds on Linux, so this is a quick check before pushing. CI on macOS is
# still the judge: it builds the app and runs the same tests with Xcode.
#
#   scripts/dev/core-test.sh                       lint, then build and test ElenathCore
#   scripts/dev/core-test.sh --filter LinkTests    pass arguments on to `swift test`
#
# Needs `swift` and `swift-format` on the PATH (https://www.swift.org/install/, the release that matches
# CI's Xcode) and, on Linux, the SQLite headers (libsqlite3-dev).
set -euo pipefail

cd "$(dirname "$0")/../.."
root=$PWD

echo "Linting…"
swift-format lint --strict --recursive --parallel Elenath ElenathCore ElenathCoreTests

# A throwaway Swift package that points at the real sources. It lives outside the repository, which has
# no Package.swift on purpose: Xcode builds the real targets.
work="${ELENATH_SHADOW_DIR:-${TMPDIR:-/tmp}/elenath-core-shadow}"
mkdir -p "$work/Sources" "$work/Tests"
ln -sfn "$root/ElenathCore" "$work/Sources/ElenathCore"
ln -sfn "$root/ElenathCoreTests" "$work/Tests/ElenathCoreTests"

sqlite_target=""
sqlite_dependency=""
if [[ "$(uname)" != "Darwin" ]]; then
    # macOS has a SQLite3 module in its SDK; elsewhere this wraps the system's libsqlite3.
    mkdir -p "$work/Sources/SQLite3"
    printf 'module SQLite3 [system] {\n    header "shim.h"\n    link "sqlite3"\n    export *\n}\n' \
        > "$work/Sources/SQLite3/module.modulemap"
    printf '#include <sqlite3.h>\n' > "$work/Sources/SQLite3/shim.h"
    sqlite_target='.systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),'
    sqlite_dependency='"SQLite3"'
fi

cat > "$work/Package.swift" <<PACKAGE
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElenathCoreShadow",
    targets: [
        $sqlite_target
        .target(name: "ElenathCore", dependencies: [$sqlite_dependency], path: "Sources/ElenathCore"),
        .testTarget(
            name: "ElenathCoreTests", dependencies: ["ElenathCore", $sqlite_dependency],
            path: "Tests/ElenathCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
PACKAGE

echo "Testing ElenathCore…"
(cd "$work" && swift test "$@")
