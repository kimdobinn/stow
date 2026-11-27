#!/bin/sh
# Writes ios/Stow/Config/Firebase.plist (ProjectID, APIKey) from android/app/google-services.json,
# so the iPhone app talks to the same Firebase project as the Android app. The plist is
# git-ignored. The key is never printed.
#
#   ios/scripts/firebase-config.sh [path/to/google-services.json [output.plist]]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
source_json=${1:-"$repo/android/app/google-services.json"}
target=${2:-"$repo/ios/Stow/Config/Firebase.plist"}

if [ ! -f "$source_json" ]; then
    echo "No $source_json. Download google-services.json from the Firebase console (see firebase/SETUP.md)." >&2
    exit 1
fi

project_id=$(plutil -extract project_info.project_id raw -o - "$source_json" 2>/dev/null) || project_id=""
api_key=$(plutil -extract client.0.api_key.0.current_key raw -o - "$source_json" 2>/dev/null) || api_key=""
if [ -z "$project_id" ] || [ -z "$api_key" ]; then
    echo "$source_json has no project_info.project_id or client[0].api_key[0].current_key." >&2
    exit 1
fi

mkdir -p "$(dirname "$target")"
temp=$(mktemp "${TMPDIR:-/tmp}/firebase-plist.XXXXXX")
trap 'rm -f "$temp"' EXIT
# Written with a heredoc rather than plutil -insert, so the key never shows up in a process list.
# Both values are plain identifiers (letters, digits, '-' and '_'), so they need no XML escaping.
case "$project_id$api_key" in
    *[!A-Za-z0-9_-]*) echo "Unexpected characters in the project id or API key." >&2; exit 1 ;;
esac
cat > "$temp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ProjectID</key>
	<string>$project_id</string>
	<key>APIKey</key>
	<string>$api_key</string>
</dict>
</plist>
EOF
plutil -lint -s "$temp"
mv "$temp" "$target"
trap - EXIT
echo "Wrote $target for Firebase project $project_id."
