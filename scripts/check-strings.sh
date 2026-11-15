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

python3 - "$catalog" "$work/Localizable.xcstrings" "${args[@]}" <<'PY'
import json
import sys

before = json.load(open(sys.argv[1]))["strings"]
after = json.load(open(sys.argv[2]))["strings"]
missing = sorted(set(after) - set(before))

# Every key the code uses, from the .stringsdata files (JSON): a key in the catalog that none of them has is
# left over from code that changed.
used = set()
readable = True
for path in sys.argv[3:]:
    if path == "--stringsdata":
        continue
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        readable = False
        break
    tables = data.get("tables") if isinstance(data, dict) else None
    if not isinstance(tables, dict):
        readable = False
        break
    for entries in tables.values():
        if isinstance(entries, list):
            used.update(entry["key"] for entry in entries if isinstance(entry, dict) and "key" in entry)
if readable and used:
    unused = sorted(set(before) - used)
else:
    print("notice: The .stringsdata files aren't JSON; unused strings are judged by Xcode's stale marks only.")
    unused = sorted(
        key for key, entry in after.items()
        if entry.get("extractionState") == "stale" and before.get(key, {}).get("extractionState") != "stale"
    )
for key in unused:
    print(f"::warning::Unused string in the catalog: {key!r}")
    print("UNUSED " + json.dumps(key, ensure_ascii=False))
if missing:
    print(f"::error::{len(missing)} string(s) used in code are missing from {sys.argv[1]}:")
    for key in missing:
        print(f"  {key!r}")
    # The entries as Xcode extracted them, one JSON object per line, to paste into the catalog.
    print("Missing entries:")
    for key in missing:
        print("ENTRY " + json.dumps({key: after[key]}, ensure_ascii=False))
    sys.exit(1)
print(f"All {len(after)} strings are in the catalog.")
PY
