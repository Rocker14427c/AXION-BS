#!/system/bin/sh
# Census shim generator - run ON THE DEVICE as root.
# Creates /data/local/tmp/census/shims/<cmd> wrappers that log
# start, end, rc and args of every spawned service command, using mksh's
# EPOCHREALTIME so the shim itself adds no forks beyond the one process
# it already is. Real binaries are resolved to absolute paths at generation
# time, so shims never recurse.
set -e
CDIR=/data/local/tmp/census
SDIR=$CDIR/shims
rm -rf "$SDIR"
mkdir -p "$SDIR"
# Tier 1: everything that is a JVM start (app_process wrapper) or a root hop.
CMDS="settings pm am appops svc input dumpsys cmd su service wm content ime getprop setprop deviceidle"
for c in $CMDS; do
  real=$(command -v "$c" 2>/dev/null || true)
  [ -n "$real" ] || continue
  cat > "$SDIR/$c" <<EOF
#!/system/bin/sh
_s=\${EPOCHREALTIME:-0}
"$real" "\$@"; _rc=\$?
_e=\${EPOCHREALTIME:-0}
printf '%s\t%s\t$c\t%s\t%s\n' "\$_s" "\$_e" "\$_rc" "\$*" >> "\${CENSUS_LOG:-$CDIR/fallback.log}" 2>/dev/null
exit \$_rc
EOF
  chmod 755 "$SDIR/$c"
  echo "shimmed $c -> $real"
done
echo "shims: $(ls "$SDIR" | wc -l)"
