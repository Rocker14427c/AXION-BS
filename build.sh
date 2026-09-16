#!/usr/bin/env bash
# Build AxionSPSM.apk and stage it into the module tree.
#
# Reproducible on any machine: every tool comes from tools/setup-toolchain.sh
# (or from your own SDK via ANDROID_HOME), never from a hardcoded path.
#
#   ./build.sh            # normal build
#   ./build.sh --bootstrap# fetch the toolchain first, then build
#
# Result: build/AxionSPSM.apk, copied to module/app/ and module/system/app/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/app"
OUT="$ROOT/build"

if [ "${1:-}" = "--bootstrap" ]; then
  "$ROOT/tools/setup-toolchain.sh"
  shift
fi

# ---------------------------------------------------------------- toolchain
ENV_FILE="$ROOT/sdk/toolchain.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
fi

JAVA="${SPSM_JAVA:-${JAVA_HOME:-/usr}/bin/java}"
AAPT2="${SPSM_AAPT2:-$(command -v aapt2 || true)}"
ANDROID_JAR="${SPSM_ANDROID_JAR:-${ANDROID_HOME:-}/platforms/android-36/android.jar}"
D8_JAR="${SPSM_D8_JAR:-}"
APKSIGNER_JAR="${SPSM_APKSIGNER_JAR:-}"
ECJ_JAR="${SPSM_ECJ_JAR:-}"
LAMBDA_STUB="${SPSM_LAMBDA_STUB:-}"
DEBUG_KEYSTORE="${SPSM_DEBUG_KEYSTORE:-}"

die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

for v in JAVA AAPT2 D8_JAR APKSIGNER_JAR ECJ_JAR; do
  eval "val=\$$v"
  [ -n "$val" ] || die "$v not set. Run: ./build.sh --bootstrap"
done
[ -x "$JAVA" ] || die "java not executable: $JAVA"
[ -x "$AAPT2" ] || die "aapt2 not executable: $AAPT2"
[ -f "$ANDROID_JAR" ] || die "android.jar not found: $ANDROID_JAR"

# Keystore: prefer a local release key, else the bundled debug key.
KEYSTORE="${SPSM_KEYSTORE:-}"
if [ -z "$KEYSTORE" ]; then
  if [ -f "$ROOT/spsm.jks" ]; then
    KEYSTORE="$ROOT/spsm.jks"
    KS_PASS="${SPSM_KEYSTORE_PASS:-android}"
    KS_ALIAS="${SPSM_KEY_ALIAS:-spsm}"
  else
    KEYSTORE="$DEBUG_KEYSTORE"
    KS_PASS="${SPSM_KEYSTORE_PASS:-android}"
    KS_ALIAS="${SPSM_KEY_ALIAS:-androiddebugkey}"
  fi
fi
[ -f "$KEYSTORE" ] || die "keystore not found: $KEYSTORE"

# Version: single source of truth is module/module.prop
VCODE="$(sed -n 's/^versionCode=//p' "$ROOT/module/module.prop" | tr -d '\r')"
VNAME="$(sed -n 's/^version=//p' "$ROOT/module/module.prop" | tr -d '\r' | sed 's/^v//')"
[ -n "$VCODE" ] || die "could not read versionCode from module/module.prop"
say "building AxionSPSM v$VNAME ($VCODE)"

rm -rf "$OUT"; mkdir -p "$OUT/res" "$OUT/gen" "$OUT/classes" "$OUT/dex"

# ------------------------------------------------------------ 1. resources
say "1/6 aapt2 compile"
"$AAPT2" compile --dir "$APP/res" -o "$OUT/res.zip"

say "2/6 aapt2 link"
# aapt2 lets attributes already present in the source manifest win over
# --version-code/--version-name, so stamp a copy and link that. module.prop
# stays the only place a version is written by hand.
MANIFEST="$OUT/AndroidManifest.xml"
sed -e "s/android:versionCode=\"[^\"]*\"/android:versionCode=\"$VCODE\"/" \
    -e "s/android:versionName=\"[^\"]*\"/android:versionName=\"$VNAME\"/" \
    "$APP/AndroidManifest.xml" > "$MANIFEST"
grep -q "android:versionCode=\"$VCODE\"" "$MANIFEST" \
  || die "could not stamp versionCode into the manifest"
grep -q "android:versionName=\"$VNAME\"" "$MANIFEST" \
  || die "could not stamp versionName into the manifest"

"$AAPT2" link -o "$OUT/res.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$MANIFEST" \
  --java "$OUT/gen" \
  --min-sdk-version 31 \
  --target-sdk-version 36 \
  --version-code "$VCODE" \
  --version-name "$VNAME" \
  --auto-add-overlay \
  "$OUT/res.zip"

# ------------------------------------------------------------ 2. java -> class
say "3/6 ecj (compile java)"
find "$APP/src" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
# shellcheck disable=SC2046
"$JAVA" -jar "$ECJ_JAR" \
  -source 8 -target 8 -encoding UTF-8 -nowarn \
  -bootclasspath "$ANDROID_JAR:$LAMBDA_STUB" -classpath "$ANDROID_JAR" \
  -d "$OUT/classes" \
  @"$OUT/sources.txt"

# ------------------------------------------------------------ 3. class -> dex
say "4/6 d8 (dex)"
find "$OUT/classes" -name '*.class' > "$OUT/classes.txt"
# shellcheck disable=SC2046
"$JAVA" -cp "$D8_JAR" com.android.tools.r8.D8 \
  --min-api 31 --lib "$ANDROID_JAR" \
  --output "$OUT/dex" \
  --release \
  $(cat "$OUT/classes.txt")
[ -f "$OUT/dex/classes.dex" ] || die "d8 produced no classes.dex"

# ------------------------------------------------------------ 4. pack
say "5/6 pack + align"
python3 "$ROOT/tools/apkpack.py" pack "$OUT/res.apk" "$OUT/dex/classes.dex" "$OUT/unsigned.apk"
python3 "$ROOT/tools/apkpack.py" verify "$OUT/unsigned.apk" | tail -3

# ------------------------------------------------------------ 5. sign
say "6/6 sign (v1+v2+v3)"
"$JAVA" -jar "$APKSIGNER_JAR" sign \
  --ks "$KEYSTORE" --ks-key-alias "$KS_ALIAS" \
  --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT/AxionSPSM.apk" "$OUT/unsigned.apk"

"$JAVA" -jar "$APKSIGNER_JAR" verify --verbose "$OUT/AxionSPSM.apk" | sed 's/^/    /'

python3 "$ROOT/tools/apkpack.py" verify "$OUT/AxionSPSM.apk" | tail -1

# ------------------------------------------------------------ 6. stage
mkdir -p "$ROOT/module/app" "$ROOT/module/system/app/AxionSPSM"
cp -f "$OUT/AxionSPSM.apk" "$ROOT/module/app/AxionSPSM.apk"
cp -f "$OUT/AxionSPSM.apk" "$ROOT/module/system/app/AxionSPSM/AxionSPSM.apk"

# ------------------------------------------------------------ 7. assert version
# Cheap insurance: the APK and module.prop must agree, or the phone shows one
# version and the manager shows another.
BADGE="$("$AAPT2" dump badging "$OUT/AxionSPSM.apk" 2>/dev/null | head -1)"
case "$BADGE" in
  *"versionCode='$VCODE'"*) ;;
  *) die "APK versionCode does not match module.prop ($VCODE): $BADGE" ;;
esac
case "$BADGE" in
  *"versionName='$VNAME'"*) ;;
  *) die "APK versionName does not match module.prop ($VNAME): $BADGE" ;;
esac

say "APK: $OUT/AxionSPSM.apk ($(du -h "$OUT/AxionSPSM.apk" | cut -f1)) v$VNAME ($VCODE)"
say "staged into module/app/ and module/system/app/AxionSPSM/"
