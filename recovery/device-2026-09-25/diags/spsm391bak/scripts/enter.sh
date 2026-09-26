#!/system/bin/sh
# Axion SPSM v3 - turn the mode on.
# Kept as a thin wrapper so old callers (and the APK) keep working; all the
# logic lives in engine.sh.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec sh "$SCRIPT_DIR/engine.sh" activate
