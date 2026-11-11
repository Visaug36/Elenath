#!/bin/bash
# Fails when the app uses a string that Localizable.xcstrings doesn't have. Building in Xcode adds new strings
# to the catalog, but xcodebuild only extracts them (into .stringsdata files), so this runs the same sync on a
# copy of the catalog and compares the two.
#
#   scripts/check-strings.sh build/DerivedData
set -euo pipefail

derived="$1"
catalog=Elenath/Localizable.xcstrings
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$catalog" "$work/Localizable.xcstrings"

args=()
while IFS= read -r file; do
    args+=(--stringsdata "$file")
done < <(find "$derived/Build/Intermediates.noindex" -path '*/Elenath.build/Objects-normal/*' -name '*.stringsdata' | sort)
if [[ ${#args[@]} -eq 0 ]]; then
    echo "::error::No .stringsdata files for the app in $derived; build it first."
    exit 1
fi
echo "Syncing with $((${#args[@]} / 2)) .stringsdata files"

if ! xcrun xcstringstool sync "$work/Localizable.xcstrings" "${args[@]}"; then
    xcrun xcstringstool sync --help || true
    exit 1
fi

python3 - "$catalog" "$work/Localizable.xcstrings" <<'PY'
import json
import sys

before = json.load(open(sys.argv[1]))["strings"]
after = json.load(open(sys.argv[2]))["strings"]
missing = sorted(set(after) - set(before))
unused = sorted(
    key for key, entry in after.items()
    if entry.get("extractionState") == "stale" and before.get(key, {}).get("extractionState") != "stale"
)
for key in unused:
    print(f"::warning::Unused string in the catalog: {key!r}")
if missing:
    print(f"::error::{len(missing)} string(s) used in code are missing from {sys.argv[1]}:")
    for key in missing:
        print(f"  {key!r}")
    sys.exit(1)
print(f"All {len(after)} strings are in the catalog.")
PY
