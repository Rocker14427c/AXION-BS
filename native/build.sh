#!/usr/bin/env bash
# Build the native helpers for the phone, and stage them into the module.
#
#   native/build.sh              build for the device (arm64 + arm)
#   native/build.sh --host       build a host copy too, for the test suite
#
# The module must install and run on a phone whose ABI we do not get to choose,
# so both 64-bit and 32-bit ARM are built and the installer picks. They are
# STATIC binaries: a module helper that depends on the ROM's libc is a helper
# that stops working after a system update, and the whole file is a few dozen
# kilobytes either way.
#
# Toolchain: an Android NDK if one is present (ANDROID_NDK_HOME / ANDROID_NDK_
# ROOT), otherwise `zig cc`, which cross-compiles to musl without needing a
# platform SDK installed. Either produces a static ELF that Android runs; if
# neither is available the build says so and the module ships without the
# helper, which is a supported state - the daemon falls back to polling.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native"
OUT="$ROOT/module/bin"
mkdir -p "$OUT"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

PROGRAMS=(spsm-screenmon)

# --------------------------------------------------------------- toolchain
CC_KIND=""
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [ -n "$NDK" ] && [ -d "$NDK/toolchains/llvm/prebuilt" ]; then
  CC_KIND=ndk
elif command -v zig >/dev/null 2>&1; then
  CC_KIND=zig
elif [ -x "$ROOT/sdk/zig/zig" ]; then
  CC_KIND=zig
  PATH="$ROOT/sdk/zig:$PATH"
fi

# The host build only needs a plain cc, so it is done BEFORE the cross-toolchain
# check rather than after it. It used to sit at the bottom of the file, which
# meant that on a machine with gcc but no NDK and no zig the script exited early
# and never produced it - and tests/run-daemon.sh, which drives the real binary
# through build/native/host, quietly skipped fourteen of its nineteen checks
# reporting "no host compiler". There was a host compiler; the build for it was
# just unreachable. A test that silently tests less is worse than one that
# fails, so the two builds are now independent.
build_host() {
  local prog
  local hout="$ROOT/build/native/host"
  command -v cc >/dev/null 2>&1 || { warn "no host cc: the suite's native checks will skip"; return 0; }
  mkdir -p "$hout"
  for prog in "${PROGRAMS[@]}"; do
    # Deliberately NOT under module/bin - that whole directory is packed into
    # the flashable zip, and a host x86 binary has no business on a phone.
    cc -Os -Wall -Wextra -o "$hout/$prog" "$SRC/$prog.c" || { warn "host build of $prog failed"; return 0; }
    say "host/$prog"
  done
}
[ "${1:-}" = "--host" ] && build_host

if [ -z "$CC_KIND" ]; then
  warn "no NDK and no zig: the native screen monitor will not be built."
  warn "the module still works - the daemon falls back to polling the panel."
  exit 0
fi
say "toolchain: $CC_KIND"

# Small and self-contained. -Os because this is a helper that spends its life
# blocked in epoll: its size costs pages on a phone, its speed costs nothing.
CFLAGS="-Os -Wall -Wextra -static -ffunction-sections -fdata-sections"
LDFLAGS="-Wl,--gc-sections -s"

build_one() { # build_one <abi-dir> <target-triple-or-ndk-prefix>
  local abi="$1" target="$2" prog cc
  mkdir -p "$OUT/$abi"
  for prog in "${PROGRAMS[@]}"; do
    if [ "$CC_KIND" = ndk ]; then
      local hosttag
      hosttag="$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)"
      cc="$NDK/toolchains/llvm/prebuilt/$hosttag/bin/${target}21-clang"
      [ -x "$cc" ] || { warn "no NDK compiler for $abi ($cc)"; return 0; }
      # shellcheck disable=SC2086
      "$cc" $CFLAGS $LDFLAGS -o "$OUT/$abi/$prog" "$SRC/$prog.c"
    else
      # shellcheck disable=SC2086
      zig cc -target "$target" $CFLAGS $LDFLAGS -o "$OUT/$abi/$prog" "$SRC/$prog.c"
    fi
    say "$abi/$prog ($(wc -c < "$OUT/$abi/$prog") bytes)"
  done
}

if [ "$CC_KIND" = ndk ]; then
  build_one arm64-v8a  aarch64-linux-android
  build_one armeabi-v7a armv7a-linux-androideabi
else
  build_one arm64-v8a  aarch64-linux-musl
  build_one armeabi-v7a arm-linux-musleabi
fi

say "native helpers staged into module/bin/"
