#!/usr/bin/env bash
# Re-extract the build JDK. Snapshots here cap around 128 MB and the extracted
# JDK (~300 MB) loses its lib/ tree across turns - java then dies with
# libjli.so missing. The wheel is kept as ONE file at /home/user/jdk4py.whl.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
J="$ROOT/sdk/jdk"
if [ -x "$J/bin/java" ] && "$J/bin/java" -version >/dev/null 2>&1; then exit 0; fi
W=/home/user/jdk4py.whl
[ -f "$W" ] || { python3 -m pip download jdk4py --no-deps -d /home/user -q; mv /home/user/jdk4py*.whl "$W"; }
rm -rf "$J"
python3 - "$W" "$J" <<'PY'
import zipfile, os, shutil, stat, sys
w, root = sys.argv[1], sys.argv[2]
for n in zipfile.ZipFile(w).namelist():
    if not n.startswith('jdk4py/java-runtime/'): continue
    rel = n[len('jdk4py/java-runtime/'):]
    if not rel or rel.endswith('/'): continue
    dst = os.path.join(root, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with zipfile.ZipFile(w).open(n) as f, open(dst, 'wb') as o: shutil.copyfileobj(f, o)
    if '/bin/' in '/'+rel or rel.endswith('.so') or os.path.basename(rel) in ('jexec','jspawnhelper'):
        os.chmod(dst, 0o755)
print("jdk re-extracted")
PY
"$J/bin/java" -version 2>&1 | head -1
