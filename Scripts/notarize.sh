#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_dir="$project_dir/dist/OpenConnect Sandbox.app"
archive="$project_dir/dist/OpenConnectSandbox.zip"

if [[ -z ${CODESIGN_IDENTITY:-} || -z ${NOTARYTOOL_PROFILE:-} ]]; then
    print -u2 "Set CODESIGN_IDENTITY and NOTARYTOOL_PROFILE before release notarization."
    exit 64
fi

"$project_dir/Scripts/build-app.sh" release
ditto -c -k --keepParent "$app_dir" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$app_dir"
xcrun stapler validate "$app_dir"
spctl --assess --type execute --verbose=2 "$app_dir"
