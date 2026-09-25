#!/usr/bin/env bash
# Build module/bin/spsm-tool.jar - the batch tool (tool/src).
#
#   tools/build-tool.sh   -> module/bin/spsm-tool.jar
#
# A jar with classes.dex at its root is what app_process wants on CLASSPATH -
# the same shape as the platform's own /system/framework/pm.jar. No manifest,
# no resources, no signing: it is not an APK, it is a dex the runtime loads
# for a uid-2000 process the module starts through su.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$ROOT/sdk/toolchain.env" ] || { echo "run tools/setup-toolchain.sh first" >&2; exit 1; }
source "$ROOT/sdk/toolchain.env"

OUT="$ROOT/build/tool"
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

echo "==> 1/3 ecj (compile java)"
find "$ROOT/tool/src" -name '*.java' > "$OUT/sources.txt"
[ -s "$OUT/sources.txt" ] || { echo "no sources under tool/src" >&2; exit 1; }
"$SPSM_JAVA" -jar "$SPSM_ECJ_JAR" \
  -source 8 -target 8 -encoding UTF-8 -nowarn \
  -bootclasspath "$SPSM_ANDROID_JAR:$SPSM_LAMBDA_STUB" -classpath "$SPSM_ANDROID_JAR" \
  -d "$OUT/classes" \
  @"$OUT/sources.txt"

echo "==> 2/3 d8 (dex)"
find "$OUT/classes" -name '*.class' > "$OUT/classes.txt"
# shellcheck disable=SC2046
"$SPSM_JAVA" -cp "$SPSM_D8_JAR" com.android.tools.r8.D8 \
  --min-api 31 --lib "$SPSM_ANDROID_JAR" \
  --output "$OUT/dex" \
  --release \
  $(cat "$OUT/classes.txt")
[ -f "$OUT/dex/classes.dex" ] || { echo "d8 produced no classes.dex" >&2; exit 1; }

echo "==> 3/3 jar"
# A jar is a zip with classes.dex at its root; the minimal JDK in sdk/ has no
# jar tool, and python's zipfile writes the same bytes. STORED, not DEFLATED:
# the runtime maps the dex straight out of the archive.
rm -f "$ROOT/module/bin/spsm-tool.jar"
python3 - "$OUT/dex/classes.dex" "$ROOT/module/bin/spsm-tool.jar" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_STORED) as z:
    z.write(sys.argv[1], "classes.dex")
print("   contents:", zipfile.ZipFile(sys.argv[2]).namelist())
PY

echo "==> module/bin/spsm-tool.jar ($(du -h "$ROOT/module/bin/spsm-tool.jar" | cut -f1))"
