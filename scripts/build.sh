#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
source "$project_dir/scripts/update-lib.sh"

build_dir="$project_dir/build"
app_dir="$project_dir/build/Arqmeter.app"
binary="$project_dir/.build/release/Arqmeter"
stage_root=""
rollback_app=""
transaction_started=0
promoted=0

finish() {
    local exit_code=$?
    trap - EXIT INT TERM HUP
    set +e

    if (( exit_code != 0 && transaction_started )); then
        if (( promoted )) && [[ -e "$app_dir" || -L "$app_dir" ]]; then
            /bin/rm -rf "$app_dir"
        fi
        if [[ -n "$rollback_app" && ( -e "$rollback_app" || -L "$rollback_app" ) ]]; then
            /bin/mv "$rollback_app" "$app_dir"
        fi
    fi

    [[ -n "$stage_root" && -d "$stage_root" ]] && /bin/rm -rf "$stage_root"
    if (( exit_code == 0 )) && [[ -n "$rollback_app" && ( -e "$rollback_app" || -L "$rollback_app" ) ]]; then
        /bin/rm -rf "$rollback_app"
    fi
    exit "$exit_code"
}

trap finish EXIT
trap 'exit 130' INT TERM HUP

cd "$project_dir"
swift build -c release

/bin/mkdir -p "$build_dir"
stage_root=$(/usr/bin/mktemp -d "$build_dir/.arqmeter-build.XXXXXX")
stage_app="$stage_root/Arqmeter.app"
/bin/mkdir -p "$stage_app/Contents/MacOS"
/bin/cp "$binary" "$stage_app/Contents/MacOS/Arqmeter"
/bin/cp "$project_dir/Resources/Info.plist" "$stage_app/Contents/Info.plist"
/bin/mkdir -p "$stage_app/Contents/Resources"
/bin/cp "$project_dir/Resources/claude-statusline-fragment.sh" "$stage_app/Contents/Resources/claude-statusline-fragment.sh"
/bin/cp "$project_dir/Resources/claude-official-usage.js" "$stage_app/Contents/Resources/claude-official-usage.js"
/usr/bin/codesign --force --deep --sign - "$stage_app"
arqmeter_validate_bundle "$stage_app"

rollback_app="$build_dir/.Arqmeter.app.rollback.$$.${RANDOM}"
transaction_started=1
if [[ -e "$app_dir" || -L "$app_dir" ]]; then
    /bin/mv "$app_dir" "$rollback_app"
fi
/bin/mv "$stage_app" "$app_dir"
promoted=1
arqmeter_validate_bundle "$app_dir"
transaction_started=0

echo "$app_dir"
