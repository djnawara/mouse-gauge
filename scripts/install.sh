#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

target="${WLMOUSE_INSTALL_DIR:-$HOME/Applications}/WLMouseMenuBar.app"
repair=false
if [[ "${1:-}" == "--repair-permissions" ]]; then
    repair=true
    source_app="$target"
else
    source_app="${1:?Usage: install.sh APP_BUNDLE | --repair-permissions}"
fi

codesign --verify --deep --strict "$source_app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")
new_requirement=$(codesign -d -r- "$source_app" 2>&1 | sed -n 's/^# designated => //p')
if [[ "$repair" == false && -d "$target" ]]; then
    old_requirement=$(codesign -d -r- "$target" 2>&1 | sed -n 's/^# designated => //p')
    if [[ "$new_requirement" == cdhash\ * && "$new_requirement" != "$old_requirement" ]]; then
        repair=true
    fi
fi

was_running=false
if pgrep -x WLMouseMenuBar >/dev/null; then
    was_running=true
    pkill -TERM -x WLMouseMenuBar
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! pgrep -x WLMouseMenuBar >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x WLMouseMenuBar >/dev/null; then
        echo 'WLMouse Menu Bar is still running; quit it before installing.' >&2
        exit 1
    fi
fi

if [[ "${1:-}" != "--repair-permissions" ]]; then
    mkdir -p "$(dirname "$target")"
    ditto "$source_app" "$target"
fi

if [[ "$repair" == true ]]; then
    echo 'Clearing the old WLMouse Input Monitoring decision.'
    tccutil reset ListenEvent "$bundle_id"
    echo 'Approve WLMouse Menu Bar when macOS requests Input Monitoring access.'
fi

if [[ "$was_running" == true || "$repair" == true ]]; then
    open "$target"
fi
echo "Installed: $target"
