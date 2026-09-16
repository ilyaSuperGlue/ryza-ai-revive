#!/usr/bin/env bash
# macOS/Linux port of scripts/build_apk.ps1.
#
# Upstream build_apk.ps1 downloads its own Windows-only toolchain into
# $RYZA_ANDROID_TOOLS (jdk17/, android-sdk/) and shells out to aapt2.exe,
# d8.bat, apksigner.bat, etc. Those binaries don't exist on macOS.
#
# This script does the exact same aapt2 -> javac -> d8 -> zipalign ->
# apksigner pipeline, but against YOUR OWN existing Android SDK/JDK via
# $ANDROID_HOME / $JAVA_HOME (the ones already exported in your .zshrc),
# using the non-.exe/.bat binaries that ship in build-tools on macOS.
#
# Output: output/android/RyzaChat-<version>.apk (self-signed; sideload via
# adb install, uninstalls like any other app).
#
# Usage: ./scripts/build_apk.sh
#   (run from anywhere inside the repo checkout, or set REPO_ROOT below)

set -euo pipefail

# ---- locate the repo -------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

# ---- toolchain: use your existing SDK/JDK, not RYZA_ANDROID_TOOLS ----------
: "${ANDROID_HOME:?ANDROID_HOME is not set (expected e.g. ~/Library/Android/sdk)}"
: "${JAVA_HOME:?JAVA_HOME is not set (expected e.g. the Zulu 17 JDK)}"

BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-34.0.0}"
ANDROID_API="${ANDROID_API:-34}"

BT="$ANDROID_HOME/build-tools/$BUILD_TOOLS_VERSION"
AJ="$ANDROID_HOME/platforms/android-$ANDROID_API/android.jar"
JDK="$JAVA_HOME"

for p in "$JDK/bin/javac" "$BT/aapt2" "$AJ"; do
  if [[ ! -e "$p" ]]; then
    echo "missing $p" >&2
    echo "  - check ANDROID_HOME/JAVA_HOME, and that 'platforms;android-$ANDROID_API' and 'build-tools;$BUILD_TOOLS_VERSION' are installed via sdkmanager" >&2
    exit 1
  fi
done

export JAVA_HOME="$JDK"
export PATH="$JDK/bin:$PATH"

AND="$ROOT/android"
WEB="$ROOT/web"
WORK="$ROOT/output/apk-work"
OUT="$ROOT/output/android"

echo "== version from config/version.json =="
VER=$(node -e "console.log(require('$ROOT/config/version.json').version)")
VC=$(node -e "console.log(require('$ROOT/config/version.json').code)")
node "$SCRIPT_DIR/stamp_version.js" "$VER" "$VC"
echo "Building RyzaChat-$VER.apk (versionCode $VC)"

echo "== privacy gate on the tree that is about to be packed =="
python3 "$SCRIPT_DIR/privacy_check.py" "$WEB" "$AND/app/src/main"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

echo "== compile resources =="
"$BT/aapt2" compile --dir "$AND/app/src/main/res" -o "$WORK/res.zip"

echo "== link base apk (manifest + resources) =="
"$BT/aapt2" link \
  -o "$WORK/base.apk" \
  --manifest "$AND/app/src/main/AndroidManifest.xml" \
  -I "$AJ" \
  "$WORK/res.zip" \
  --auto-add-overlay \
  --min-sdk-version 24 --target-sdk-version "$ANDROID_API" \
  --version-code "$VC" --version-name "$VER"

echo "== javac =="
CLS="$WORK/classes"
mkdir -p "$CLS"
SRCS=()
while IFS= read -r -d '' f; do SRCS+=("$f"); done < <(find "$AND/app/src/main/java" -name '*.java' -print0)
"$JDK/bin/javac" -nowarn -encoding UTF-8 --release 11 -classpath "$AJ" -d "$CLS" "${SRCS[@]}"

echo "== d8 =="
CLASSFILES=()
while IFS= read -r -d '' f; do CLASSFILES+=("$f"); done < <(find "$CLS" -name '*.class' -print0)
"$BT/d8" --release --lib "$AJ" --output "$WORK" "${CLASSFILES[@]}"
[[ -f "$WORK/classes.dex" ]] || { echo "classes.dex missing" >&2; exit 1; }

echo "== add dex into apk =="
( cd "$WORK" && "$BT/aapt" add base.apk classes.dex )

echo "== pack web assets (forward slashes) =="
python3 "$SCRIPT_DIR/pack_apk_assets.py" "$WORK/base.apk" "$WEB"

echo "== zipalign =="
"$BT/zipalign" -f 4 "$WORK/base.apk" "$WORK/aligned.apk"

echo "== sign =="
# Self-signed for sideloading. Keystore lives in android/keystore (gitignored):
# reuse the SAME key for every release, or Android refuses in-place upgrades.
KSDIR="$AND/keystore"
mkdir -p "$KSDIR"
KS="$KSDIR/ryza.keystore"
if [[ ! -f "$KS" ]]; then
  "$JDK/bin/keytool" -genkeypair -v -keystore "$KS" -alias ryza \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Ryza Chat, OU=offline rebuild" -storepass ryza-chat -keypass ryza-chat >/dev/null
fi
APK="$OUT/RyzaChat-$VER.apk"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:ryza-chat --key-pass pass:ryza-chat --out "$APK" "$WORK/aligned.apk"

echo "== verify =="
"$BT/apksigner" verify "$APK"

echo "== privacy gate on the signed APK (member names + text members) =="
python3 "$SCRIPT_DIR/privacy_check.py" --quiet "$APK"

MB=$(node -e "console.log((require('fs').statSync('$APK').size/1048576).toFixed(1))")
echo "Built: $APK  ($MB MB)"
