#!/system/bin/sh
# SukiSU / KernelSU "Action" button: toggle SPSM.
MODDIR=${0%/*}
SPSM_DIR=/data/adb/spsm
if [ -f "$SPSM_DIR/active" ]; then
  sh "$MODDIR/scripts/exit.sh"
else
  sh "$MODDIR/scripts/enter.sh"
fi
