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

# ------------------------------------------------------------------ audit
# Every view this app asks for must be one the layout actually declares, and must
# be held as a type the layout's view can be. This is not a lint: v3.4.0 shipped a
# slot layout whose root changed from LinearLayout to FrameLayout while two
# activities went on casting it, and the phone found it - a ClassCastException on
# resume, which on the home screen means no home screen. It compiles, and no test
# of the scripts can see it, so it is checked here, and the build stops on it.
if command -v python3 >/dev/null 2>&1; then
  if ! python3 "$ROOT/tests/audit-ids.py"; then
    die "the app's view lookups do not match its layouts (see above)"
  fi
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

# -------------------------------------------------- 5b. check the APK itself
# The source audit above reads the app; this reads what the user would install.
# v3.4.0's crash was a Java type problem that the compiler accepted, so the last
# thing to do before staging is to prove the methods in this dex are the fixed
# ones - and that the one that crashed is not in it any more.
_SLOT="ILdev/axion/spsm/Apps\$SlotClick;)V"
if ! python3 "$ROOT/tools/dexcheck.py" "$OUT/AxionSPSM.apk" \
    "Ldev/axion/spsm/Apps;->bindSlot(Landroid/content/Context;Landroid/view/View;$_SLOT" \
    "Ldev/axion/spsm/SetupActivity;->bindSlots()V" \
    "Ldev/axion/spsm/SpsmHomeActivity;->bindSlots()V" \
    "Ldev/axion/spsm/SpsmHomeActivity;->confirmExit()V"; then
  die "the APK does not carry the methods this source says it does"
fi
if python3 "$ROOT/tools/dexcheck.py" "$OUT/AxionSPSM.apk" \
    "Ldev/axion/spsm/Apps;->bindSlot(Landroid/content/Context;Landroid/widget/LinearLayout;$_SLOT" \
    >/dev/null 2>&1; then
  die "the APK still carries the slot method that crashed on the phone"
fi

# ------------------------------------------------------------ 6. stage
mkdir -p "$ROOT/module/app" "$ROOT/module/system/app/AxionSPSM"
cp -f "$OUT/AxionSPSM.apk" "$ROOT/module/app/AxionSPSM.apk"
cp -f "$OUT/AxionSPSM.apk" "$ROOT/module/system/app/AxionSPSM/AxionSPSM.apk"

# ---------------------------------------------------------------- staged = built
# A stale APK in the module tree is the one mistake this pipeline must never
# make twice: an APK that predates the current resources installs, starts, and
# then crashes the first time it opens a screen whose layout it does not carry.
# So the STAGED file is read back and every resource file in app/res must be
# in it - layouts, drawables, everything. One missing file fails the build.
python3 - "$OUT/AxionSPSM.apk" "$APP/res" <<'PYGUARD'
import os, re, sys, zipfile
apk, res = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(apk)
names = set(z.namelist())
missing = []
for root, _dirs, files in os.walk(res):
    # values/*.xml are COMPILED into resources.arsc - they correctly never
    # appear as file entries. Everything else (layouts, drawables, mipmaps)
    # must be in the APK by its own path.
    if os.path.basename(root) == "values":
        continue
    for f in files:
        p = os.path.join(root, f)
        rel = os.path.relpath(p, res)
        arc = "res/" + rel
        # aapt2 auto-versions bitmap configs (-v4) so they can sit beside an
        # anydpi-v26 XML; accept either name.
        alt = re.sub(r"^res/([^/]+)/", r"res/\1-v4/", arc)
        if arc not in names and alt not in names:
            missing.append(arc)
if missing:
    print("STALE APK: %d resource file(s) missing:" % len(missing), file=sys.stderr)
    for m in missing:
        print("  " + m, file=sys.stderr)
    sys.exit(1)
print("staged APK carries every resource (%d entries)" % len(names))
PYGUARD

# ------------------------------------------------------------ 7. assert version
# Cheap insurance: the APK and module.prop must agree, or the phone shows one
# version and the manager shows another.
# Written to a file first: aapt2 is a JVM that prints a lot, and piping it into
# `head -1` lets head close the pipe while aapt2 is still writing. Under
# pipefail that kills the build with a SIGPIPE (141) at the very last step, on
# some runs and not others - a flaky build is worse than no build.
"$AAPT2" dump badging "$OUT/AxionSPSM.apk" 2>/dev/null > "$OUT/badging.txt" || true
BADGE="$(head -1 "$OUT/badging.txt")"
[ -n "$BADGE" ] || die "could not read the built APK back with aapt2"
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

# -------------------------------------------------- 6. the native helpers
# The event-driven screen monitor (native/spsm-screenmon.c). Deliberately NOT
# fatal if it cannot be built: it is an optimisation, the daemon falls back to
# polling without it, and a contributor with no cross-compiler must still be
# able to build a working module. native/build.sh says which it did.
# bash, not sh: native/build.sh uses arrays and pipefail. Invoking it with `sh`
# made it fail instantly on a dash host, which is exactly the machine that most
# needs to be told the helper was not built.
bash "$ROOT/native/build.sh" || true
