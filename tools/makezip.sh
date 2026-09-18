#!/usr/bin/env bash
# Build the flashable module zip from module/.
#
#   tools/makezip.sh            -> build/Axion-SPSM-vX.Y-RMX3430.zip
#
# The APK inside module/ is the one build.sh produced, so run build.sh first
# (or use --build to do both).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$ROOT/module"
OUT="$ROOT/release"
# The zip is written into release/, not build/, because release/ is tracked: the
# GitHub release assets endpoint is not always reachable (it is blocked from
# some CI/sandbox networks), so the flashable zip is also committed here and the
# release notes link to it. See release/README.md.

if [ "${1:-}" = "--build" ]; then
  "$ROOT/build.sh"
  shift
fi

VNAME="$(sed -n 's/^version=//p' "$MOD/module.prop" | tr -d '\r' | sed 's/^v//')"
[ -n "$VNAME" ] || { echo "no version in module.prop" >&2; exit 1; }

ZIP="$OUT/Axion-SPSM-v${VNAME}-RMX3430.zip"
mkdir -p "$OUT"
rm -f "$ZIP"

command -v zip >/dev/null || { echo "zip not installed" >&2; exit 1; }

# sanity: the module must actually contain the APK and the engine
[ -f "$MOD/system/app/AxionSPSM/AxionSPSM.apk" ] || { echo "APK missing - run ./build.sh" >&2; exit 1; }
[ -f "$MOD/scripts/engine.sh" ] || { echo "engine.sh missing" >&2; exit 1; }

( cd "$MOD" && zip -qr "$ZIP" \
    META-INF module.prop customize.sh service.sh post-fs-data.sh action.sh \
    uninstall.sh scripts system system.prop app README.md HOW_TO_USE.txt 2>/dev/null )

echo "==> $ZIP ($(du -h "$ZIP" | cut -f1))"
python3 - "$ZIP" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
for must in ("module.prop", "customize.sh", "system.prop", "META-INF/com/google/android/update-binary",
             "scripts/engine.sh", "scripts/lib.sh", "scripts/knobs.sh"):
    print("  %-46s %s" % (must, "ok" if must in names else "MISSING"))
apk = [n for n in names if n.endswith("AxionSPSM.apk")]
print("  %-46s %d" % ("bundled APKs", len(apk)))
PY
