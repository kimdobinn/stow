#!/bin/bash
# Xcode build phase (see project.yml): puts the embedded Python into the app bundle the way CPython's
# "Using Python on iOS" describes (and Python.xcframework/build/utils.sh does), with two changes:
# - it leaves out what the app never imports (tests, IDLE, Tk, ensurepip): about 40 MB;
# - it converts and signs only the extension modules that changed, so incremental builds stay fast.
#
# Layout inside Stow.app:
#   python/lib/python3.14/          standard library (+ lib-dynload/*.fwork placeholders)
#   python/site-packages/           yt-dlp, yt-dlp-ejs, certifi (from ios/Vendor/site-packages)
#   python/app/                     the app's own Python (ios/Stow/YtDlp/Python/*.py)
#   Frameworks/<module>.framework/  each binary extension module, as iOS only loads code from frameworks
set -euo pipefail

: "${CODESIGNING_FOLDER_PATH:?run this from Xcode}"
XCFRAMEWORK="$PROJECT_DIR/Vendor/Python.xcframework"
SITE_PACKAGES="$PROJECT_DIR/Vendor/site-packages"
APP_PYTHON="$PROJECT_DIR/Stow/YtDlp/Python"

if [ ! -d "$XCFRAMEWORK" ] || [ ! -d "$SITE_PACKAGES" ]; then
  echo "error: ios/Vendor is missing: run ios/scripts/fetch-python.sh" >&2
  exit 1
fi

case "$EFFECTIVE_PLATFORM_NAME" in
  -iphonesimulator) SLICE="ios-arm64_x86_64-simulator" ;;
  -iphoneos) SLICE="ios-arm64" ;;
  *) echo "error: unsupported platform $EFFECTIVE_PLATFORM_NAME" >&2; exit 1 ;;
esac
# Python's platform-specific files (sysconfig data, lib-dynload) are per architecture.
read -r -a ARCH_LIST <<< "$ARCHS"
if [ "${#ARCH_LIST[@]}" -ne 1 ]; then
  echo "error: build one architecture at a time (ARCHS=$ARCHS)" >&2
  exit 1
fi
ARCH="${ARCH_LIST[0]}"

PYTHON_VER=$(ls -1 "$XCFRAMEWORK/lib" | grep -E '^python3\.[0-9]+$')
DEST="$CODESIGNING_FOLDER_PATH/python"
mkdir -p "$DEST/lib" "$DEST/site-packages" "$DEST/app" "$CODESIGNING_FOLDER_PATH/Frameworks"

# Standard library. *.so and *.fwork are left alone here: the frameworks step below owns them.
EXCLUDES=(
  --exclude 'libpython*.dylib' --exclude '*.so' --exclude '*.fwork' --exclude '__pycache__'
  --exclude "/$PYTHON_VER/test/" --exclude "/$PYTHON_VER/idlelib/" --exclude "/$PYTHON_VER/tkinter/"
  --exclude "/$PYTHON_VER/turtledemo/" --exclude "/$PYTHON_VER/turtle.py" --exclude "/$PYTHON_VER/ensurepip/"
  --exclude "/$PYTHON_VER/pydoc_data/" --exclude "/$PYTHON_VER/__phello__/" --exclude "/$PYTHON_VER/venv/"
  --exclude "/$PYTHON_VER/site-packages/"
)
rsync -a --delete "${EXCLUDES[@]}" "$XCFRAMEWORK/lib/" "$XCFRAMEWORK/$SLICE/lib-$ARCH/" "$DEST/lib/"
rsync -a --delete --exclude '__pycache__' "$SITE_PACKAGES/" "$DEST/site-packages/"
rsync -a --delete --exclude '__pycache__' "$APP_PYTHON/" "$DEST/app/"

# Extension modules -> frameworks.
SIGN=0
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  SIGN=1
fi
DYNLOAD_SRC="$XCFRAMEWORK/$SLICE/lib-$ARCH/$PYTHON_VER/lib-dynload"
DYNLOAD_DEST="$DEST/lib/$PYTHON_VER/lib-dynload"
mkdir -p "$DYNLOAD_DEST"
# Test-only modules the app never loads.
SKIP_MODULES='^(_test.*|_xxtestfuzz|xxlimited.*|xxsubtype|_ctypes_test|_remote_debugging)$'
converted=0
for so in "$DYNLOAD_SRC"/*.so; do
  ext=$(basename "$so")
  module="${ext%%.*}"
  if [[ "$module" =~ $SKIP_MODULES ]]; then
    rm -f "$DYNLOAD_DEST/${ext%.so}.fwork"
    rm -rf "$CODESIGNING_FOLDER_PATH/Frameworks/$module.framework"
    continue
  fi
  framework="Frameworks/$module.framework"
  binary="$CODESIGNING_FOLDER_PATH/$framework/$module"
  fwork="$DYNLOAD_DEST/${ext%.so}.fwork"
  if [ -f "$binary" ] && [ -f "$fwork" ] && [ ! "$so" -nt "$binary" ]; then
    continue
  fi
  mkdir -p "$CODESIGNING_FOLDER_PATH/$framework"
  plist="$CODESIGNING_FOLDER_PATH/$framework/Info.plist"
  cp "$XCFRAMEWORK/build/iOS-dylib-Info-template.plist" "$plist"
  plutil -replace CFBundleExecutable -string "$module" "$plist"
  plutil -replace CFBundleIdentifier -string "$(echo "$PRODUCT_BUNDLE_IDENTIFIER.$module" | tr '_' '-')" "$plist"
  plutil -replace MinimumOSVersion -string "$IPHONEOS_DEPLOYMENT_TARGET" "$plist"
  cp "$so" "$binary"
  # Python's AppleFrameworkLoader follows .fwork to the framework; .origin points back for __file__.
  echo "$framework/$module" > "$fwork"
  echo "python/lib/$PYTHON_VER/lib-dynload/${ext%.so}.fwork" > "$CODESIGNING_FOLDER_PATH/$framework/$module.origin"
  if [ -e "$DYNLOAD_SRC/$module.xcprivacy" ]; then
    cp "$DYNLOAD_SRC/$module.xcprivacy" "$CODESIGNING_FOLDER_PATH/$framework/PrivacyInfo.xcprivacy"
  fi
  if [ $SIGN = 1 ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime \
      --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der \
      "$CODESIGNING_FOLDER_PATH/$framework"
  fi
  converted=$((converted + 1))
done
echo "Python $PYTHON_VER for $SLICE/$ARCH: $converted extension modules converted (signing: $SIGN)"
