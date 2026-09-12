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
  --min-sdk-version 31 \
  --target-sdk-version 36 \
  --version-code 21 \
  --version-name 2.1 \
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
"$D8" --min-api 31 --lib "$ANDROID_JAR" --output "$OUT" @"$OUT/classes.txt"

echo "==> pack apk (resources.arsc must be STORED + 4-byte aligned for targetSdk 30+)"
python3 - "$OUT/res.apk" "$OUT/classes.dex" "$OUT/unsigned.apk" <<'PY'
import sys, zipfile
res_apk, dex, out = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(res_apk, "r") as zin, zipfile.ZipFile(out, "w") as zout:
    for info in zin.infolist():
        data = zin.read(info.filename)
        ni = zipfile.ZipInfo(filename=info.filename, date_time=info.date_time)
        ni.external_attr = info.external_attr
        ni.create_system = 0
        # Android R+ rejects compressed resources.arsc
        if info.filename.endswith((".arsc", ".so")):
            ni.compress_type = zipfile.ZIP_STORED
        else:
            ni.compress_type = zipfile.ZIP_DEFLATED
        zout.writestr(ni, data)
    with open(dex, "rb") as f:
        zout.writestr("classes.dex", f.read(), compress_type=zipfile.ZIP_DEFLATED)
PY

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
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT/AxionSPSM.apk" "$OUT/aligned.apk"
"$APKSIGNER" verify --verbose "$OUT/AxionSPSM.apk" | head -20
"$ZIPALIGN" -c -p 4 "$OUT/AxionSPSM.apk"
python3 - "$OUT/AxionSPSM.apk" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
info = z.getinfo("resources.arsc")
print("resources.arsc compress=%s size=%s" % (
    "STORED" if info.compress_type == zipfile.ZIP_STORED else "DEFLATED", info.file_size))
if info.compress_type != zipfile.ZIP_STORED:
    raise SystemExit("resources.arsc must be uncompressed")
PY

mkdir -p "$ROOT/module/app" "$ROOT/module/system/app/AxionSPSM"
cp -f "$OUT/AxionSPSM.apk" "$ROOT/module/app/AxionSPSM.apk"
cp -f "$OUT/AxionSPSM.apk" "$ROOT/module/system/app/AxionSPSM/AxionSPSM.apk"
echo "==> APK $(du -h "$OUT/AxionSPSM.apk" | awk '{print $1}')"
