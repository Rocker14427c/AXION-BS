#!/system/bin/sh
# Axion SPSM v3 - turn the mode off and put every change back.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec sh "$SCRIPT_DIR/engine.sh" deactivate
