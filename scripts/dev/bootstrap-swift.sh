#!/bin/bash
# Installs the open-source Swift toolchain that matches CI's Xcode, for scripts/dev/core-test.sh on Linux.
# It goes into a folder outside the repository, and nothing is changed system-wide.
#
#   scripts/dev/bootstrap-swift.sh [install-folder]
#
# Then put its bin folder first on the PATH, as the last line it prints shows. Written for Ubuntu 24.04 on
# x86_64, where the project is developed; other systems get Swift from https://www.swift.org/install/.
set -euo pipefail

# Swift 6.3.3 is the compiler in Xcode 26.6, which CI builds with. Keep them in step.
version="6.3.3"
folder="${1:-$HOME/.cache/elenath/swift-$version}"

if [[ -x "$folder/usr/bin/swift" ]]; then
    echo "Swift $version is already in $folder"
else
    mkdir -p "$folder"
    url="https://download.swift.org/swift-$version-release/ubuntu2404/swift-$version-RELEASE/swift-$version-RELEASE-ubuntu24.04.tar.gz"
    echo "Downloading Swift $version (about 1 GB)…"
    curl -fsSL --retry 3 "$url" | tar -xz -C "$folder" --strip-components=1
fi
"$folder/usr/bin/swift" --version | head -n 1
echo "export PATH=\"$folder/usr/bin:\$PATH\""
