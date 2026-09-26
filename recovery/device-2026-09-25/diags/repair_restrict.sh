#!/system/bin/sh
# One-time repair: restore the app_restrict/rom_bg_off values stranded by the
# 2026-09-25 21:27 grace-pass/deactivate race (records cleared before the
# restore could read them). Reads current state, undoes only what is still
# OURS (bucket 45 / op deny), to permissive defaults (10 ACTIVE / default).
exec > /data/local/tmp/repair.log 2>&1
cd /data/adb/spsm/scripts || exit 1
# shellcheck source=/dev/null
. ./lib.sh
# shellcheck source=/dev/null
. ./knobs.sh 2>/dev/null
L=/data/adb/spsm/spsm.log
D=/data/local/tmp
echo "=== REPAIR start $(date) ==="

# The log line is truncated; the journal snapshot has the FULL managed set.
tr ' ' '\n' < "$SPSM_DIR/journal/app_restrict.orig" 2>/dev/null | grep . | sort -u > "$D/fix_ar.pkgs"
awk '/restricted for this idle period:/{line=$0; sub(/.*period: /,"",line); print line}' "$L" | tail -1 | tr ' ' '\n' | grep . | sort -u > "$D/fix_rb.pkgs"
cat "$D/fix_ar.pkgs" "$D/fix_rb.pkgs" | sort -u > "$D/fix_all.pkgs"
echo "targets: ar=$(wc -l < "$D/fix_ar.pkgs") rb=$(wc -l < "$D/fix_rb.pkgs") all=$(wc -l < "$D/fix_all.pkgs")"

# If the rom_bg record survived, let the module's own guarded restore use it.
if [ -f "$ORIG_DIR/rom_bg.tsv" ]; then
  echo "rom_bg.tsv present ($(wc -l < "$ORIG_DIR/rom_bg.tsv") records) - running restore_rom_bg_off"
  restore_rom_bg_off
fi
[ -f "$ORIG_DIR/app_restrict.tsv" ] && echo "WARN app_restrict.tsv reappeared" 

awk '{ printf "activity\tget-standby-bucket\t%s\n", $1
       printf "appops\tget\t%s\tRUN_ANY_IN_BACKGROUND\n", $1 }' "$D/fix_all.pkgs" > "$D/fix_reads.in"

tool_ok && echo "tool ok" || echo "TOOL MISSING"
tool_shellbatch "$D/fix_reads.in" > "$D/fix_reads.out" 2>&1
echo "reads_frames=$(grep -c 'END' "$D/fix_reads.out")"
_batch_reads_parse "$D/fix_all.pkgs" "$D/fix_reads.out" > "$D/fix_parsed.tsv"
echo "parsed=$(wc -l < "$D/fix_parsed.tsv")"
echo "stranded_bucket45=$(awk -F'\t' '$2=="45"' "$D/fix_parsed.tsv" | wc -l)"
echo "stranded_deny=$(awk -F'\t' '$3=="deny"' "$D/fix_parsed.tsv" | wc -l)"

awk -F'\t' '
  $2=="45" { printf "activity\tset-standby-bucket\t%s\t10\n", $1 }
  $3=="deny" { printf "appops\tset\t%s\tRUN_ANY_IN_BACKGROUND\tdefault\n", $1 }
' "$D/fix_parsed.tsv" > "$D/fix_writes.in"
echo "writes=$(wc -l < "$D/fix_writes.in")"
if [ -s "$D/fix_writes.in" ]; then
  tool_shellbatch "$D/fix_writes.in" > "$D/fix_writes.out" 2>&1
  echo "write_frames=$(grep -c 'END' "$D/fix_writes.out")"
  echo "write_rc_nonzero=$(awk -F'\t' '$1=="###" && $2!="END" && $3!=0' "$D/fix_writes.out" | wc -l)"
fi

echo "=== VERIFY ==="
echo "remaining45=$(awk -F'\t' '$2=="45"' "$D/fix_parsed.tsv" | wc -l) (pre-fix count above was of reads BEFORE writes)"
for p in com.whatsapp com.google.android.gm.lite com.vivi.vivimusic dev.anilbeesetti.nextplayer.release com.instagram.lite org.lineageos.settings.doze com.android.edge.bar; do
  echo "$p bucket=$(su 2000 -c "cmd activity get-standby-bucket $p" 2>&1) op=$(su 2000 -c "cmd appops get $p RUN_ANY_IN_BACKGROUND" 2>&1 | head -1)"
done
rm -f "$D"/fix_*.in "$D"/fix_*.out "$D"/fix_*.pkgs "$D"/fix_parsed.tsv
echo "=== REPAIR done $(date) ==="
