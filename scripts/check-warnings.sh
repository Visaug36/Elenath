#!/bin/bash
# Fails when an xcodebuild log contains any warning. Elenath builds with zero warnings.
# Usage: scripts/check-warnings.sh build.log [more.log ...]
set -euo pipefail

# Notices Xcode prints for every project that has nothing to do with our code.
ignored='Metadata extraction skipped\. No AppIntents\.framework dependency found\.'

warnings=$(grep -hE '(^|: )warning: ' "$@" | grep -vE "$ignored" | sort -u || true)
if [[ -n "$warnings" ]]; then
    echo "::error::The build produced warnings:"
    echo "$warnings"
    exit 1
fi
echo "No warnings."
