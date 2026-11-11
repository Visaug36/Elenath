#!/bin/bash
# Renders the app icon's SVG master into the asset catalog's AppIcon set (16 to 512 pt, @1x and @2x) and into
# docs/images (1024 and 256 px, for the README). Run it again whenever docs/icon/icon.svg changes.
#
#   scripts/icon/make-appicon.sh [icon.svg]
#
# Needs Node.js and Playwright with Chromium (see render.cjs). The app's build doesn't need either: the
# rendered PNGs are committed.
set -euo pipefail

cd "$(dirname "$0")/../.."
master="${1:-docs/icon/icon.svg}"
set_dir="Elenath/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$set_dir" docs/images

jobs=()
entries=""
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        name="icon_${size}x${size}.png"
        if [[ $scale -eq 2 ]]; then
            name="icon_${size}x${size}@2x.png"
        fi
        jobs+=("$pixels" "$master" "$set_dir/$name")
        entries+="    {
      \"filename\": \"$name\",
      \"idiom\": \"mac\",
      \"scale\": \"${scale}x\",
      \"size\": \"${size}x${size}\"
    },
"
    done
done
jobs+=(1024 "$master" docs/images/icon-1024.png 256 "$master" docs/images/icon-256.png)
node "$(dirname "$0")/render.cjs" "${jobs[@]}"

printf '{\n  "images": [\n%s\n  ],\n  "info": {\n    "author": "xcode",\n    "version": 1\n  }\n}\n' "${entries%,$'\n'}" \
    > "$set_dir/Contents.json"
echo "Wrote the AppIcon set and docs/images/icon-1024.png, icon-256.png from $master"
