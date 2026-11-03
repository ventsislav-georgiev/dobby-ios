#!/usr/bin/env bash
# Embedded CPython for the on-device lanes (#482): the Apple counterpart of Android's Chaquopy block
# (dobby-android app/build.gradle). Runs as a post-build phase, after Xcode has copied the
# resources and before it signs the app, and puts three things into the bundle:
#
#   Frameworks/Python.framework   BeeWare Python-Apple-support, pinned below, fetched once into
#                                 python-support/ (gitignored) and checked against its sha256.
#   <Resources>/python/app        The Python tree, copied whole from the private sibling dobby
#                                 checkout (scripts/python), entry module apple_entry.py included
#                                 (PythonRuntime.swift imports only that). Never committed here:
#                                 this repo is public.
#   <Resources>/python/app_packages  requests and beautifulsoup4 with their deps: exact pure-Python
#                                 wheels from PyPI, sha256-pinned, unzipped (no pip needed).
#
# plus, on iOS, the standard library under <Resources>/python/lib with every binary module moved
# into its own signed Frameworks/<module>.framework (Python-Apple-support's build/utils.sh, which
# the App Store requires: no loose .so outside Frameworks/).
#
# The framework is NOT a link-time dependency. PythonRuntime.swift dlopens it, so a build without
# the Python tree (no dobby checkout beside this one) gets a WARNING, no Python, and an app that works
# exactly as before: the same degrade-don't-fail rule as scripts/copy-app-shell.sh.
#
# By hand, with no Xcode environment, it only fetches and verifies the cache.
set -euo pipefail
cd "${SRCROOT:-$(dirname "$0")/..}"

PY_VER=3.14
PY_SUPPORT_TAG=3.14-b14   # Python 3.14.10, OpenSSL 3.5.9
SHA_macOS=4475ee12ea9e4bcba8bc2a74c9ab9c179bb240bb84d46eb4523dbc05c7d00d72
SHA_iOS=703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee
WHEELS=(
  "requests/requests-2.34.2-py3-none-any.whl 2a0d60c172f83ac6ab31e4554906c0f3b3588d37b5cb939b1c061f4907e278e0"
  "urllib3/urllib3-2.8.0-py3-none-any.whl 0cf3cae568d36aa9576b28dfb35f11328f1cb974ca7647d9475ebb86c75ac6e3"
  "idna/idna-3.20-py3-none-any.whl ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c"
  "certifi/certifi-2026.10.23-py3-none-any.whl e9b54de76e530bb6cf0ccd036787103acb58fd42ba930ea8bf948ddbaa2f61d1"
  "charset_normalizer/charset_normalizer-3.5.2-py3-none-any.whl b6b751274acb69d77b3323d6b7dbaa3c7fdfc1eb829b7eb61d262f32e1af9685"
  "beautifulsoup4/beautifulsoup4-4.15.0-py3-none-any.whl d6f88de62e1d4e38ecb1077eb9724cd0eff29d2a08ca16a401e9b9e93f117cf9"
  "soupsieve/soupsieve-3.0.4-py3-none-any.whl 8412826614f9c632227067d0985aeb9f584bd15efc852955430e097a9fe7afbf"
  "typing_extensions/typing_extensions-4.16.0-py3-none-any.whl 481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8"
)
# The canonical tree lives in the private dobby repo (#485), which CI checks out beside this one.
PYTHON_TREE_DIR="${PYTHON_TREE_DIR:-$PWD/../dobby/scripts/python}"
CACHE="$PWD/python-support"

fetch() {  # url sha256 dest
  [ -f "$3" ] && [ "$(/usr/bin/shasum -a 256 "$3" | cut -c1-64)" = "$2" ] && return 0
  mkdir -p "$(dirname "$3")"
  /usr/bin/curl -fsSL --retry 3 -o "$3.part" "$1"
  [ "$(/usr/bin/shasum -a 256 "$3.part" | cut -c1-64)" = "$2" ] || { echo "error: copy-python: sha256 mismatch for $1" >&2; exit 1; }
  mv "$3.part" "$3"
}

# One platform's support package, unpacked, pruned and byte-compiled once. The stamp names the
# tag, so a pin bump re-extracts. Pruned: the test suite, IDLE, Tk, ensurepip, pydoc topics, the
# test-only binary modules and the static libpython. The macOS package comes first even for an iOS
# build: its bin/python3.14 is the exact interpreter that writes the .pyc files (same magic as the
# embedded one, no host Python needed). Hash-based, unchecked: the bundle is signed and never
# changes after the build, and every build recompiles what it copied (Chaquopy precompiles too).
PYBIN="$CACHE/macOS/Python.xcframework/macos-arm64_x86_64/Python.framework/Versions/$PY_VER/bin/python$PY_VER"
compile() { "$PYBIN" -W ignore -m compileall -q -j0 --invalidation-mode unchecked-hash "$@" >/dev/null; }
support() {  # macOS|iOS
  local dir="$CACHE/$1" tgz="$CACHE/dl/Python-$PY_VER-$1-support.${PY_SUPPORT_TAG#*-}.tar.gz" sha
  [ "$1" = macOS ] && sha=$SHA_macOS || { support macOS; sha=$SHA_iOS; }
  [ "$(cat "$dir/.stamp" 2>/dev/null)" = "$PY_SUPPORT_TAG" ] && return 0
  fetch "https://github.com/beeware/Python-Apple-support/releases/download/$PY_SUPPORT_TAG/$(basename "$tgz")" "$sha" "$tgz"
  rm -rf "$dir" && mkdir -p "$dir" && /usr/bin/tar -xzf "$tgz" -C "$dir"
  /usr/bin/find "$dir" -depth \( -path "*/python$PY_VER/test" -o -path "*/python$PY_VER/idlelib" \
    -o -path "*/python$PY_VER/tkinter" -o -path "*/python$PY_VER/turtledemo" -o -path "*/python$PY_VER/ensurepip" \
    -o -path "*/python$PY_VER/pydoc_data" -o -name "config-$PY_VER-*" -o -name '_test*.so' -o -name '_ctypes_test*.so' \
    -o -name '_xxtestfuzz*.so' -o -name 'xxlimited*.so' -o -name 'xxsubtype*.so' \) -exec rm -rf {} +
  /usr/bin/find "$dir" -type d -path "*/lib*/python$PY_VER" -print0 | while IFS= read -r -d '' lib; do compile "$lib"; done
  echo "$PY_SUPPORT_TAG" > "$dir/.stamp"
}

packages() {
  local dir="$CACHE/app_packages" stamp
  stamp="$(printf '%s\n' "${WHEELS[@]}" | /usr/bin/shasum | cut -c1-40)"
  [ "$(cat "$dir/.stamp" 2>/dev/null)" = "$stamp" ] && return 0
  rm -rf "$dir" && mkdir -p "$dir"
  local w path sha
  for w in "${WHEELS[@]}"; do
    path=${w% *}; sha=${w#* }
    fetch "https://files.pythonhosted.org/packages/py3/${path:0:1}/$path" "$sha" "$CACHE/dl/${path#*/}"
    /usr/bin/unzip -qo "$CACHE/dl/${path#*/}" -d "$dir"
  done
  echo "$stamp" > "$dir/.stamp"
}

case "${PLATFORM_NAME:-}" in
  macosx) PLATFORM=macOS ;;
  iphoneos|iphonesimulator) PLATFORM=iOS ;;
  "") support macOS; support iOS; packages; echo "copy-python: cache ready in $CACHE"; exit 0 ;;
  *) echo "copy-python: skip ($PLATFORM_NAME)"; exit 0 ;;
esac

RES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
FW="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
if [ ! -f "$PYTHON_TREE_DIR/apple_entry.py" ]; then
  echo "warning: copy-python: no Python tree at $PYTHON_TREE_DIR (set PYTHON_TREE_DIR); this build ships without Python and without the on-device lanes." >&2
  # Wipe, or an incremental build that lost the sibling keeps a stale interpreter.
  # On iOS that includes the per-module frameworks, each marked by the .origin file utils.sh writes.
  rm -rf "$RES/python" "$FW/Python.framework"
  for origin in "$FW"/*.framework/*.origin; do [ -f "$origin" ] && rm -rf "$(dirname "$origin")"; done
  exit 0
fi

support "$PLATFORM"
packages
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"   # unsigned builds: ad hoc, so every binary still carries a signature

mkdir -p "$RES/python" "$FW"
/usr/bin/rsync -a --delete --exclude __pycache__ --exclude '*.pyc' "$PYTHON_TREE_DIR/" "$RES/python/app/"
/usr/bin/rsync -a --delete --exclude .stamp --exclude __pycache__ "$CACHE/app_packages/" "$RES/python/app_packages/"
compile "$RES/python/app" "$RES/python/app_packages"

if [ "$PLATFORM" = macOS ]; then
  # Stdlib and binary modules live inside the framework on macOS. Each Mach-O in it is signed on
  # its own (codesign does not descend into lib/), then the framework seals over them.
  # Not the build tools: headers, bin/ (the compiler above) and the nested Python.app launcher.
  excludes=(--exclude /Python.framework/Headers)
  for x in bin include Headers _CodeSignature lib/pkgconfig Resources/Python.app; do
    excludes+=(--exclude "/Python.framework/Versions/$PY_VER/$x")
  done
  /usr/bin/rsync -a --delete --delete-excluded "${excludes[@]}" "$CACHE/macOS/Python.xcframework/macos-arm64_x86_64/Python.framework" "$FW/"
  # A real identity also gets a secure timestamp: notarization refuses any Mach-O without one.
  ts=--timestamp; [ "$SIGN_ID" = - ] && ts=--timestamp=none
  /usr/bin/find "$FW/Python.framework/Versions/$PY_VER/lib" -type f \( -name '*.so' -o -name '*.dylib' \) \
    -exec /usr/bin/codesign --force --sign "$SIGN_ID" -o runtime "$ts" {} +
  /usr/bin/codesign --force --sign "$SIGN_ID" -o runtime "$ts" "$FW/Python.framework/Versions/$PY_VER"
else
  /usr/bin/rsync -a --delete "$CACHE/iOS/Python.xcframework/$( [ "$PLATFORM_NAME" = iphoneos ] && echo ios-arm64 || echo ios-arm64_x86_64-simulator)/Python.framework" "$FW/"
  /usr/bin/codesign --force --sign "$SIGN_ID" -o runtime --timestamp=none "$FW/Python.framework"
  # Upstream's helper copies lib/ and turns every .so into a signed framework with a .fwork stub
  # where the .so was (the import system follows the stub). It reads these from the environment.
  export EXPANDED_CODE_SIGN_IDENTITY="$SIGN_ID" EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-ad hoc}"
  export CODESIGNING_FOLDER_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME" PROJECT_DIR="$PWD"
  # The helper reads lib-$ARCHS, one slice only; a generic simulator build lists two.
  # ponytail: binary modules for the native arch only, an x86_64 simulator on Apple silicon misses them.
  case " $ARCHS " in *" ${NATIVE_ARCH:-arm64} "*) export ARCHS="${NATIVE_ARCH:-arm64}" ;; esac
  # shellcheck source=/dev/null
  # #509: the module binaries are dylibs, but utils.sh copies a template that types every module
  # framework APPL, and altool took the first APPL Info.plist in the ipa (Frameworks/_zstd.framework)
  # for the app. FMWK leaves the app the only APPL bundle; set before install_python signs them.
  /usr/bin/plutil -replace CFBundlePackageType -string FMWK "$CACHE/iOS/Python.xcframework/build/iOS-dylib-Info-template.plist"
  source "$CACHE/iOS/Python.xcframework/build/utils.sh"
  install_python python-support/iOS/Python.xcframework python/app_packages >/dev/null
fi
echo "copy-python: Python $PY_VER ($PY_SUPPORT_TAG) and the Python tree -> $WRAPPER_NAME"
