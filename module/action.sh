#!/system/bin/sh
# ResukiSU / KernelSU "Action" button: toggle the mode.
MODDIR=${0%/*}
SPSM_DIR=${SPSM_DIR:-/data/adb/spsm}

if [ -f "$SPSM_DIR/scripts/engine.sh" ]; then
  sh "$SPSM_DIR/scripts/engine.sh" toggle
else
  sh "$MODDIR/scripts/engine.sh" toggle
fi
