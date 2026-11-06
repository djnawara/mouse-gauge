#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

install_dir="${MOUSEGAUGE_INSTALL_DIR:-${WLMOUSE_INSTALL_DIR:-$HOME/Applications}}"
target="$install_dir/MouseGauge.app"
legacy_target="$install_dir/WLMouseMenuBar.app"
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

is_running() {
    pgrep -x MouseGauge >/dev/null || pgrep -x WLMouseMenuBar >/dev/null
}

was_running=false
if is_running; then
    was_running=true
    for process_name in MouseGauge WLMouseMenuBar; do
        if pgrep -x "$process_name" >/dev/null; then
            pkill -TERM -x "$process_name"
        fi
    done
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! is_running; then break; fi
        sleep 0.1
    done
    if is_running; then
        echo 'MouseGauge or WLMouse Menu Bar is still running; quit it before installing.' >&2
        exit 1
    fi
fi

if [[ "${1:-}" != "--repair-permissions" ]]; then
    mkdir -p "$(dirname "$target")"
    ditto "$source_app" "$target"
    codesign --verify --deep --strict "$target"

    if [[ -d "$legacy_target" ]]; then
        legacy_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_target/Contents/Info.plist")
        if [[ "$legacy_id" == local.wlmouse-menu-bar ]]; then
            # Retire the old app without deleting it or leaving a second launchable copy.
            backup_dir=$(mktemp -d "$install_dir/.MouseGauge-previous-install.XXXXXX")
            mv "$legacy_target" "$backup_dir/WLMouseMenuBar.app.previous"
            echo "Previous app saved at: $backup_dir/WLMouseMenuBar.app.previous"
            if ! tccutil reset ListenEvent "$legacy_id"; then
                echo 'Could not clear the old WLMouse permission entry; remove it in Settings if it remains.' >&2
            fi
            was_running=true # Open the renamed app to request its own permission.
        fi
    fi
fi

if [[ "$repair" == true ]]; then
    echo 'Clearing the old MouseGauge Input Monitoring decision.'
    tccutil reset ListenEvent "$bundle_id"
    echo 'Approve MouseGauge when macOS requests Input Monitoring access.'
fi

if [[ "$was_running" == true || "$repair" == true ]]; then
    open "$target"
fi
echo "Installed: $target"
