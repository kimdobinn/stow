#!/bin/zsh
# Builds Stow.ipa (unsigned: SideStore or AltStore signs it with your Apple ID when installing),
# publishes it as a GitHub pre-release tagged ios-v<version>, and adds the version to the
# SideStore/AltStore source (ios/source.json), so the app updates from there.
#
#   ios/release.sh                  # notes: the commit subjects since the last iPhone release
#   ios/release.sh "What changed"   # your own notes
#
# Bump CFBundleShortVersionString and CFBundleVersion in project.yml and push that commit first.
# Pre-releases keep Obtainium on the Android releases (it skips pre-releases by default).
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
cd "$script_dir"

version=$(sed -nE 's/^ *CFBundleShortVersionString: "(.*)"/\1/p' project.yml)
build=$(sed -nE 's/^ *CFBundleVersion: "(.*)"/\1/p' project.yml)
[[ -n $version && -n $build ]] || { echo "Couldn't read the version from project.yml." >&2; exit 1; }
tag="ios-v$version"

if [[ -n $(git status --porcelain) ]]; then
  echo "Commit your changes first." >&2; exit 1
fi
git fetch --quiet origin
if [[ $(git rev-parse HEAD) != $(git rev-parse '@{upstream}') ]]; then
  echo "Push (or pull) first: this commit isn't the one on GitHub." >&2; exit 1
fi
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" >/dev/null 2>&1; then
  echo "$tag is already released. Bump CFBundleShortVersionString and CFBundleVersion in project.yml." >&2; exit 1
fi

./scripts/fetch-python.sh
./scripts/firebase-config.sh
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -quiet -project Stow.xcodeproj -scheme Stow -sdk iphoneos -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/release CODE_SIGNING_ALLOWED=NO clean build

ipa="$repo_root/Stow-$version.ipa"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/Payload"
ditto build/release/Build/Products/Release-iphoneos/Stow.app "$staging/Payload/Stow.app"
rm -f "$ipa"
(cd "$staging" && zip -qry "$ipa" Payload)

if (( $# > 0 )); then
  notes=$1
else
  previous=$(git describe --tags --abbrev=0 --match 'ios-v*' 2>/dev/null || true)
  notes=$(git log --format='- %s' ${previous:+$previous..}HEAD -- . | head -20)
fi

gh release create "$tag" "$ipa" --prerelease --target "$(git rev-parse HEAD)" \
  --title "Stow for iPhone $version" --notes "$notes"
git fetch --quiet --tags origin

# Add this version to the source SideStore and AltStore read.
url=$(gh release view "$tag" --json assets -q ".assets[] | select(.name == \"$(basename "$ipa")\") | .url")
python3 - "$script_dir/source.json" "$version" "$build" "$url" "$(stat -f %z "$ipa")" "$notes" <<'EOF'
import json, sys, datetime
path, version, build, url, size, notes = sys.argv[1:]
source = json.load(open(path))
app = source["apps"][0]
app["versions"] = [v for v in app["versions"] if v["version"] != version]
app["versions"].insert(0, {
    "version": version,
    "buildVersion": build,
    "date": datetime.date.today().isoformat(),
    "localizedDescription": notes,
    "downloadURL": url,
    "size": int(size),
    "minOSVersion": "17.0",
})
with open(path, "w") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")
EOF
git add source.json
git commit --quiet -m "iPhone $version in the SideStore source"
git push --quiet
echo "Released $tag with $(basename "$ipa"), and added it to ios/source.json."
