#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/app"
BT="/home/user/sdk/build-tools/android-14"
ANDROID_JAR="/home/user/sdk/platforms/android-34/android.jar"
AAPT2="$BT/aapt2"
D8="$BT/d8"
ZIPALIGN="$BT/zipalign"
APKSIGNER="$BT/apksigner"
OUT="$ROOT/build"
mkdir -p "$OUT" "$OUT/res" "$OUT/gen" "$OUT/classes" "$OUT/apk"

echo "==> compile resources"
"$AAPT2" compile --dir "$APP/res" -o "$OUT/res.zip"
"$AAPT2" link -o "$OUT/res.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$APP/AndroidManifest.xml" \
  --java "$OUT/gen" \
  --min-sdk-version 26 \
  --target-sdk-version 34 \
  --version-code 16 \
  --version-name 1.6 \
  --auto-add-overlay \
  "$OUT/res.zip"

echo "==> javac"
find "$APP/src" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
rm -rf "$OUT/classes"
mkdir -p "$OUT/classes"
STUBS="$BT/core-lambda-stubs.jar"
javac -encoding UTF-8 -source 8 -target 8 -Xlint:-options \
  -bootclasspath "$ANDROID_JAR:$STUBS" \
  -d "$OUT/classes" \
  @"$OUT/sources.txt"

echo "==> d8"
find "$OUT/classes" -name '*.class' > "$OUT/classes.txt"
"$D8" --min-api 26 --lib "$ANDROID_JAR" --output "$OUT" @"$OUT/classes.txt"

echo "==> pack apk"
rm -rf "$OUT/apk"
mkdir -p "$OUT/apk"
unzip -q "$OUT/res.apk" -d "$OUT/apk"
cp "$OUT/classes.dex" "$OUT/apk/"
( cd "$OUT/apk" && zip -q -r "$OUT/unsigned.apk" . )

echo "==> zipalign + sign"
"$ZIPALIGN" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
if [ ! -f "$ROOT/spsm.jks" ]; then
  /usr/lib/jvm/jdk-11/bin/keytool -genkeypair -keystore "$ROOT/spsm.jks" -alias spsm \
    -storepass android -keypass android \
    -dname "CN=Axion SPSM, O=Axion, C=IN" \
    -keyalg RSA -keysize 2048 -validity 10000 -noprompt
fi
"$APKSIGNER" sign --ks "$ROOT/spsm.jks" --ks-key-alias spsm \
  --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/AxionSPSM.apk" "$OUT/aligned.apk"
"$APKSIGNER" verify --verbose "$OUT/AxionSPSM.apk" | head -20

mkdir -p "$ROOT/module/app"
cp -f "$OUT/AxionSPSM.apk" "$ROOT/module/app/AxionSPSM.apk"
echo "==> APK $(du -h "$OUT/AxionSPSM.apk" | awk '{print $1}')"
