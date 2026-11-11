#!/bin/bash
# Puts back the committed version of every screenshot that differs from it only by rendering noise (a few
# pixels of antialiasing), so the Screenshots workflow commits only images that really changed.
#
#   scripts/screenshots/keep-unchanged.sh docs/images
set -euo pipefail

dir="$1"
here="$(cd "$(dirname "$0")" && pwd)"
# Fewer changed pixels than this is noise; a changed label or block is thousands.
threshold=200
mkdir -p build
swiftc -O "$here/image-diff.swift" -o build/image-diff

for image in "$dir"/*.png; do
    git cat-file -e "HEAD:$image" 2> /dev/null || continue  # a new screenshot
    git diff --quiet -- "$image" && continue                 # byte for byte the same
    git show "HEAD:$image" > build/previous.png
    changed=$(build/image-diff build/previous.png "$image")
    if [[ "$changed" != "size" ]] && ((changed < threshold)); then
        echo "$image: $changed pixels differ, keeping the committed image"
        git checkout -- "$image"
    else
        echo "$image: changed ($changed pixels)"
    fi
done
