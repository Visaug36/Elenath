#!/bin/bash
# Takes the screenshots from the -demo build: each scene is a fresh launch with throwaway settings (your
# own notes and settings are never touched), in British English (24-hour times, weeks from Monday).
#
#   scripts/screenshots/capture.sh path/to/Elenath.app docs/images
set -euo pipefail

app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out="$2"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$out" build/screenshot-logs
swiftc -O "$here/window-bounds.swift" -o build/window-bounds

debug_dump() {
    local name="$1"
    local pid="$2"
    echo "::group::Debug for $name"
    build/window-bounds --list | grep -v -e "^Window Server" -e "^Dock" -e "^Control Center" || true
    screencapture -x "build/screenshot-logs/$name-screen.png" || true
    ls -la ~/Library/Logs/DiagnosticReports 2> /dev/null | tail -n 5 || true
    cat "build/screenshot-logs/$name.log" 2> /dev/null | tail -n 40 || true
    if [[ -n "$pid" ]]; then
        ps -o pid,stat,etime,command -p "$pid" || true
        lsappinfo info "$pid" || true
        sample "$pid" 2 -file "build/screenshot-logs/$name-sample.txt" > /dev/null 2>&1 || true
        sed -n '1,/^Total number in stack/p' "build/screenshot-logs/$name-sample.txt" 2> /dev/null | head -n 120 || true
    fi
    log show --last 2m --style compact --predicate 'process == "Elenath"' 2> /dev/null | tail -n 60 || true
    echo "::endgroup::"
}

shot() {
    local name="$1"
    shift
    pkill -x Elenath 2> /dev/null || true
    sleep 1
    open -n -F -a "$app" --stdout "$PWD/build/screenshot-logs/$name.log" --stderr "$PWD/build/screenshot-logs/$name.log" \
        --args -demo -demoWindowSize 1280x800 -ApplePersistenceIgnoreState YES \
        -AppleLocale en_GB -AppleLanguages '(en)' "$@"
    local pid=""
    local bounds=""
    for attempt in $(seq 1 60); do
        sleep 0.5
        pid=$(pgrep -n -x Elenath || true)
        [[ -n "$pid" ]] || continue
        bounds=$(build/window-bounds "$pid" 2> /dev/null || true)
        [[ -n "$bounds" ]] && break
        if [[ $attempt -eq 10 ]]; then
            # On the CI runner SwiftUI doesn't open the main window at launch. Reopening the app (what
            # clicking its Dock icon does) makes it open one.
            echo "$name: no window after 5 s, reopening"
            open -a "$app"
        fi
    done
    if [[ -z "$bounds" ]]; then
        echo "::error::No window for $name (pid ${pid:-none})"
        debug_dump "$name" "$pid"
        pkill -x Elenath 2> /dev/null || true
        return 1
    fi
    sleep 4  # let the scene settle (the window is resized once it is on screen)
    bounds=$(build/window-bounds "$pid")
    screencapture -x -R"$bounds" "$out/$name.png"
    echo "$name: $bounds"
    pkill -x Elenath 2> /dev/null || true
    sleep 1
}

# The demo's clock is pinned, so the dates in the shots don't change from one run to the next.
now=(-demoNow 2026-11-10T14:30)
shot today-night -demoAppearance night -demoScene today "${now[@]}"
shot today-dawn -demoAppearance dawn -demoScene today "${now[@]}"
shot note-night -demoAppearance night -demoScene note "${now[@]}"
shot note-dawn -demoAppearance dawn -demoScene note "${now[@]}"
shot inbox-night -demoAppearance night -demoScene inbox "${now[@]}"
shot space-night -demoAppearance night -demoScene space "${now[@]}"
shot search-night -demoAppearance night -demoScene search "${now[@]}"
shot sealed-night -demoAppearance night -demoScene sealed "${now[@]}"
shot capture-night -demoAppearance night -demoScene capture "${now[@]}"
shot onboarding-night -demoAppearance night -demoScene onboarding "${now[@]}"
shot settings-night -demoAppearance night -demoScene settings "${now[@]}"
