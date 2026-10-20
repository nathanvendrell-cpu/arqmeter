#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
products="$project_dir/Products.noindex"
scratch="$products/UpdaterBuild"
candidate="$products/Arqmeter-UpdaterCandidate.app"
stage=""
cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$stage" && "$stage" == "$products"/.updater-stage.* && -d "$stage" ]]; then
        /bin/rm -r -- "$stage"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
[[ ! -e "$candidate" && ! -L "$candidate" ]] || { print -u2 "Candidate already exists; preserved. Select/review its task-owned replacement explicitly."; exit 1; }
/bin/mkdir -p "$products"
cd "$project_dir"
swift build --scratch-path "$scratch" -c release --product Arqmeter
bin_dir=$(swift build --scratch-path "$scratch" -c release --show-bin-path)
framework="$scratch/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$framework" && -x "$bin_dir/Arqmeter" ]] || { print -u2 "Pinned framework or executable missing"; exit 1; }
stage=$(/usr/bin/mktemp -d "$products/.updater-stage.XXXXXX")
app="$stage/Arqmeter.app"
/bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
/bin/cp "$bin_dir/Arqmeter" "$app/Contents/MacOS/Arqmeter"
/bin/cp "$project_dir/Resources/Info.plist" "$app/Contents/Info.plist"
for file in claude-statusline-fragment.sh claude-official-usage.js; do
    /bin/cp "$project_dir/Resources/$file" "$app/Contents/Resources/$file"
done
/usr/bin/ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
embedded="$app/Contents/Frameworks/Sparkle.framework"
while IFS= read -r link; do
    target=$(/bin/realpath "$link")
    [[ "$target" == "$embedded"/* ]] || { print -u2 "Escaping or broken framework symlink refused"; exit 1; }
done < <(/usr/bin/find "$embedded" -type l)
# Test-only ad-hoc signing, inside this new product only. No hardened-runtime
# exception, security setting, quarantine removal, credential or identity lookup.
/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/bin/mv "$app" "$candidate"
print "$candidate"
# No open/LaunchServices registration, LaunchAgent mutation or installation.
