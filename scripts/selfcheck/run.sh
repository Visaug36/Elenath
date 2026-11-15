#!/bin/bash
# CI's crash check. Launches the -demo build with -demoSelfCheck, which walks through the app's screens and
# actions and quits (Elenath/App/DemoSelfCheck.swift). Fails when the app crashes, hangs, reports an error,
# doesn't print "SELF-CHECK PASSED", or doesn't quit afterwards. Demo mode never touches real data.
#
#   scripts/selfcheck/run.sh path/to/Elenath.app
set -euo pipefail

app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out="$PWD/build/selfcheck"
mkdir -p "$out"
log="$out/selfcheck.log"
: > "$log"
reports="$HOME/Library/Logs/DiagnosticReports"
marker="$out/started"
touch "$marker"
limit=600

pkill -x Elenath 2> /dev/null || true
sleep 1
open -n -F -a "$app" --stdout "$log" --stderr "$log" \
    --args -demo -demoSelfCheck -ApplePersistenceIgnoreState YES -AppleLocale en_GB -AppleLanguages '(en)'

finished=""
for second in $(seq 1 "$limit"); do
    sleep 1
    if [[ $second -eq 8 ]]; then
        # On the runner SwiftUI opens the main window only when the app is reopened, as a Dock click does.
        open -a "$app" || true
    fi
    if grep -q -e "SELF-CHECK PASSED" -e "SELF-CHECK FAILED" "$log"; then
        finished="yes"
        break
    fi
    if [[ $second -gt 15 ]] && ! pgrep -x Elenath > /dev/null; then
        break
    fi
done

status=0
if [[ -z "$finished" ]]; then
    if pgrep -x Elenath > /dev/null; then
        echo "::error::The self-check didn't finish within $limit seconds"
        sample "$(pgrep -x Elenath | head -n 1)" 3 -file "$out/hang-sample.txt" > /dev/null 2>&1 || true
    else
        echo "::error::Elenath ended before the self-check finished"
    fi
    status=1
elif grep -q "SELF-CHECK FAILED" "$log"; then
    echo "::error::$(grep "SELF-CHECK FAILED" "$log" | head -n 1)"
    status=1
else
    # Quitting must work too.
    for _ in $(seq 1 30); do
        pgrep -x Elenath > /dev/null || break
        sleep 1
    done
    if pgrep -x Elenath > /dev/null; then
        echo "::error::Elenath didn't quit after the self-check"
        status=1
    fi
fi
pkill -x Elenath 2> /dev/null || true

crashes=$(find "$reports" -newer "$marker" \( -name 'Elenath*' -o -name '*Elenath*.ips' \) 2> /dev/null || true)
if [[ -n "$crashes" ]]; then
    echo "::error::Elenath crashed during the self-check"
    while IFS= read -r report; do
        cp "$report" "$out/" || true
        head -n 80 "$report" || true
    done <<< "$crashes"
    status=1
fi

echo "::group::Self-check log"
cat "$log"
echo "::endgroup::"
exit $status
