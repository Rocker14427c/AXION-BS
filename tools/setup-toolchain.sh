#!/usr/bin/env bash
# Fetch a self-contained Android build toolchain into ./sdk (gitignored).
#
# Why this exists: the old build.sh hardcoded /home/user/sdk/build-tools/android-14
# and /usr/lib/jvm/jdk-11, so the APK could only be rebuilt on one machine. This
# pulls every piece from a public registry and works anywhere with network:
#
#   JDK        -> PyPI   (jdk4py: real Temurin OpenJDK, java + keytool)
#   aapt2      -> npm    (aaptjs3: aapt2 Linux x64 binary)
#   d8, ecj,
#   apksigner  -> npm    (@drxiaozhi/minapk: official d8.jar + apksigner.jar,
#                         Eclipse Java Compiler, debug keystore)
#   android.jar-> GitHub (Sable/android-platforms, android-36 platform stubs)
#
# If ANDROID_HOME / ANDROID_SDK_ROOT is set with build-tools and platforms
# installed, those are preferred and nothing is downloaded for them. Same for a
# JDK already on PATH.
#
# Usage:  tools/setup-toolchain.sh [--clean]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/sdk"
WORK="$SDK/.work"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

clean() { rm -rf "$SDK"; }
[ "${1:-}" = "--clean" ] && clean

mkdir -p "$SDK" "$SDK/bin" "$WORK"

need() { command -v "$1" >/dev/null 2>&1 || { warn "missing required command: $1"; exit 1; }; }
need curl

# ---------------------------------------------------------------- android.jar
AJAR="$SDK/android.jar"
if [ ! -f "$AJAR" ]; then
  if [ -n "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ]; then
    for cand in "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"/platforms/android-*/android.jar; do
      [ -f "$cand" ] && cp "$cand" "$AJAR" && break
    done
  fi
fi
if [ ! -f "$AJAR" ]; then
  # Sable/android-platforms, the old source, is gone from GitHub. The same
  # npm package that supplies d8/apksigner/ecj ships the platform jar.
  say "android.jar <- npm @drxiaozhi/minapk (platform stubs)"
  rm -rf "$WORK/minapk"
  mkdir -p "$WORK/minapk"
  _try=0
  while [ "$_try" -lt 3 ]; do
    ( cd "$WORK" && npm pack --silent @drxiaozhi/minapk >/dev/null 2>&1 ) && break
    _try=$((_try + 1))
    sleep 3
  done
  PKG="$(ls -t "$WORK"/drxiaozhi-minapk-*.tgz 2>/dev/null | head -1)"
  [ -n "$PKG" ] || { warn "npm pack @drxiaozhi/minapk failed"; exit 1; }
  tar xzf "$PKG" -C "$WORK/minapk"
  if [ -f "$WORK/minapk/package/tools/android.jar" ]; then
    cp "$WORK/minapk/package/tools/android.jar" "$AJAR"
  else
    warn "android.jar missing from @drxiaozhi/minapk"; exit 1
  fi
fi
say "android.jar: $(du -h "$AJAR" | cut -f1)"

# ------------------------------------------------------------------------ JDK
JAVA_BIN="${JAVA_HOME:-}/bin/java"
if [ ! -x "$JAVA_BIN" ] && ! command -v java >/dev/null 2>&1; then
  say "JDK <- PyPI jdk4py"
  python3 -m pip download --no-deps -q -d "$WORK/jdk" jdk4py \
    || { warn "pip download jdk4py failed"; exit 1; }
  python3 -m zipfile -e "$WORK"/jdk/*.whl "$WORK/jdkx/"
  RT="$(find "$WORK/jdkx" -maxdepth 3 -type d -name 'java-runtime' | head -1)"
  [ -n "$RT" ] || { warn "no java-runtime in jdk4py wheel"; exit 1; }
  rm -rf "$SDK/jdk"; mkdir -p "$SDK/jdk"
  cp -a "$RT"/. "$SDK/jdk/"
  chmod -R u+rwX "$SDK/jdk"; chmod +x "$SDK/jdk"/bin/* 2>/dev/null || true
  JAVA_BIN="$SDK/jdk/bin/java"
  export JAVA_HOME="$SDK/jdk"
fi
[ -x "$JAVA_BIN" ] || JAVA_BIN="$(command -v java)"
"$JAVA_BIN" -version 2>&1 | head -1 | sed 's/^/    /'

# ----------------------------------------------------------------------- aapt2
if [ ! -x "$SDK/bin/aapt2" ]; then
  if [ -n "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ]; then
    for cand in "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"/build-tools/*/aapt2; do
      [ -x "$cand" ] && cp "$cand" "$SDK/bin/aapt2" && break
    done
  fi
fi
if [ ! -x "$SDK/bin/aapt2" ]; then
  say "aapt2 <- npm aaptjs3"
  ( cd "$WORK" && npm pack --silent aaptjs3 >/dev/null 2>&1 )
  PKG="$(ls -t "$WORK"/aaptjs3-*.tgz 2>/dev/null | head -1)"
  [ -n "$PKG" ] || { warn "npm pack aaptjs3 failed"; exit 1; }
  rm -rf "$WORK/aaptjs3"; mkdir -p "$WORK/aaptjs3"
  tar xzf "$PKG" -C "$WORK/aaptjs3"
  cp "$WORK/aaptjs3/package/bin/x64/linux/aapt2" "$SDK/bin/aapt2"
  chmod +x "$SDK/bin/aapt2"
fi
"$SDK/bin/aapt2" version | sed 's/^/    /'

# ------------------------------------------------- d8 / ecj / apksigner / ks
if [ ! -f "$SDK/jar/d8.jar" ]; then
  say "d8.jar, apksigner.jar, ecj, keystore <- npm @drxiaozhi/minapk"
  ( cd "$WORK" && npm pack --silent @drxiaozhi/minapk >/dev/null 2>&1 )
  PKG="$(ls -t "$WORK"/drxiaozhi-minapk-*.tgz 2>/dev/null | head -1)"
  [ -n "$PKG" ] || { warn "npm pack @drxiaozhi/minapk failed"; exit 1; }
  rm -rf "$WORK/minapk"; mkdir -p "$WORK/minapk"
  tar xzf "$PKG" -C "$WORK/minapk"
  mkdir -p "$SDK/jar"
  cp "$WORK/minapk/package/tools/d8.jar" "$SDK/jar/d8.jar"
  cp "$WORK/minapk/package/tools/apksigner.jar" "$SDK/jar/apksigner.jar"
  cp "$WORK/minapk/package/tools/ecj-3.45.0.jar" "$SDK/jar/ecj.jar"
  cp "$WORK/minapk/package/tools/debug.keystore" "$SDK/jar/debug.keystore"
fi
for j in d8.jar apksigner.jar ecj.jar; do
  [ -f "$SDK/jar/$j" ] || { warn "missing $SDK/jar/$j"; exit 1; }
done
say "jars: $(ls "$SDK/jar" | tr '\n' ' ')"

# --------------------------------------------------------- lambda stub jar
# android.jar declares MethodHandle/MethodType/CallSite/MethodHandles.Lookup but
# NOT LambdaMetafactory, and the compiler needs it to resolve the `invokedynamic`
# that lambdas and method references compile to. Without it ECJ fails with
# "The type java.lang.invoke.LambdaMetafactory cannot be resolved" and the only
# alternative is dropping -bootclasspath, which would let the build silently
# compile against the host JDK's java.* API instead of Android's.
if [ ! -f "$SDK/jar/lambda-stub.jar" ]; then
  say "lambda compile stub"
  STUB="$WORK/stub"
  mkdir -p "$STUB/src/java/lang/invoke" "$STUB/classes"
  cat > "$STUB/src/java/lang/invoke/LambdaMetafactory.java" <<'JAVA'
package java.lang.invoke;

/**
 * Compile-time ONLY stub, never packaged into the APK and never referenced on
 * the device: d8 desugars lambdas down to ordinary classes.
 */
public final class LambdaMetafactory {
    private LambdaMetafactory() {}

    public static CallSite metafactory(MethodHandles.Lookup caller,
                                       String interfaceMethodName,
                                       MethodType factoryType,
                                       MethodType interfaceMethodType,
                                       MethodHandle implementation,
                                       MethodType dynamicMethodType) {
        return null;
    }

    public static CallSite altMetafactory(MethodHandles.Lookup caller,
                                          String interfaceMethodName,
                                          MethodType factoryType,
                                          Object... args) {
        return null;
    }
}
JAVA
  "$JAVA_BIN" -jar "$SDK/jar/ecj.jar" -source 8 -target 8 -nowarn \
    -d "$STUB/classes" "$STUB/src/java/lang/invoke/LambdaMetafactory.java" \
    || { warn "lambda stub failed to compile"; exit 1; }
  python3 - "$STUB/classes" "$SDK/jar/lambda-stub.jar" <<'PY'
import os, sys, zipfile
classes, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk(classes):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, classes))
print("    wrote %s (%d bytes)" % (out, os.path.getsize(out)))
PY
fi

# --------------------------------------------------------------------- report
cat > "$SDK/toolchain.env" <<EOF
# Generated by tools/setup-toolchain.sh - sourced by build.sh
export SPSM_JAVA="$JAVA_BIN"
export SPSM_AAPT2="$SDK/bin/aapt2"
export SPSM_ANDROID_JAR="$AJAR"
export SPSM_D8_JAR="$SDK/jar/d8.jar"
export SPSM_APKSIGNER_JAR="$SDK/jar/apksigner.jar"
export SPSM_ECJ_JAR="$SDK/jar/ecj.jar"
export SPSM_LAMBDA_STUB="$SDK/jar/lambda-stub.jar"
export SPSM_DEBUG_KEYSTORE="$SDK/jar/debug.keystore"
EOF
say "toolchain ready -> $SDK/toolchain.env"
