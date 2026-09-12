#!/usr/bin/env python3
"""Pack and zip-align an unsigned APK without external tools.

Why this exists: the platform needs `resources.arsc` stored uncompressed and
mapped straight out of the APK, and `zipalign` is not always available (the
Android build-tools copy is a Windows .exe in the toolchain we bootstrap, and
the old build.sh relied on a host install). Doing it in Python keeps the build
reproducible everywhere.

`pack`   builds an APK-shaped zip with the right compression types.
`align`  rewrites it so every entry's data starts on a multiple of 4
         (4096 for .so), the way Android's zipalign does: patch the local
         header's extra field, then fix up the central directory and EOCD.
`verify` re-reads the result and asserts compression + alignment.
"""
import struct
import sys
import zipfile

ALIGN = 4
PAGE = 4096
STORED_SUFFIXES = (".arsc", ".so")

LFH_SIG = 0x04034B50
CDH_SIG = 0x02014B50
EOCD_SIG = 0x06054B50


def want_for(name):
    return PAGE if name.endswith(".so") else ALIGN


def pack(res_apk, dex, out, extra_entries=()):
    """Write `out` from aapt2 output + classes.dex (+ arbitrary extra files)."""
    entries = []
    with zipfile.ZipFile(res_apk, "r") as zin:
        for info in zin.infolist():
            entries.append((info.filename, zin.read(info.filename)))
    for path, arcname in extra_entries:
        with open(path, "rb") as fh:
            entries.append((arcname, fh.read()))
    with open(dex, "rb") as fh:
        entries.append(("classes.dex", fh.read()))

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        for name, data in entries:
            stored = name.endswith(STORED_SUFFIXES)
            ni = zipfile.ZipInfo(filename=name, date_time=(2009, 1, 1, 0, 0, 0))
            ni.create_system = 3
            ni.external_attr = (0o100644 & 0xFFFF) << 16
            ni.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
            ni.extra = b""
            zout.writestr(ni, data)
    return out


def _pad_for(base, want):
    """Padding bytes so that (base + pad) lands on a `want` boundary.

    `base` must be the data offset the entry will actually have in the OUTPUT
    file, not its offset in the input - padding chosen from a stale offset is
    what makes a zipalign implementation silently produce a misaligned APK.

    Returns 0, or >= 4, because a ZIP extra field cannot be 1-3 bytes long.
    """
    need = (-base) % want          # 0..want-1
    if need == 0:
        return 0
    return need if need >= 4 else need + 4


def align(path_in, path_out):
    """Zipalign: rewrite so each entry's data offset is aligned."""
    data = bytearray(open(path_in, "rb").read())

    out = bytearray()
    # old local-header offset -> (new offset, new extra)
    fix = {}

    off = 0
    while off < len(data) and struct.unpack_from("<I", data, off)[0] == LFH_SIG:
        flags, method = struct.unpack_from("<HH", data, off + 6)
        csize = struct.unpack_from("<I", data, off + 18)[0]
        nlen, xlen = struct.unpack_from("<HH", data, off + 26)
        if flags & 0x08:
            raise SystemExit("apkpack: data descriptors are not supported")
        name = bytes(data[off + 30:off + 30 + nlen])
        old_extra = bytes(data[off + 30 + nlen:off + 30 + nlen + xlen])
        data_off = off + 30 + nlen + xlen

        new_off = len(out)
        # Pad against the offset this entry WILL have, not the one it has now.
        pad = _pad_for(new_off + 30 + nlen, want_for(name.decode("utf-8", "replace")))
        new_extra = old_extra + (
            b"\x35\xd9" + (pad - 4).to_bytes(2, "little") + b"\x00" * (pad - 4)
            if pad else b"")
        header = bytearray(data[off:off + 30])
        struct.pack_into("<H", header, 28, xlen + pad)  # xlen grows by pad
        out += header + name + new_extra
        out += data[data_off:data_off + csize]
        fix[off] = (new_off, xlen + pad, new_extra)
        off = data_off + csize

    # ---- central directory ----
    cd_start = off
    cd_out_start = len(out)
    cd = data[cd_start:]
    p = 0
    while p < len(cd) and struct.unpack_from("<I", cd, p)[0] == CDH_SIG:
        nlen, xlen, clen = struct.unpack_from("<HHH", cd, p + 28)
        local_off = struct.unpack_from("<I", cd, p + 42)[0]
        name = bytes(cd[p + 46:p + 46 + nlen])
        entry = bytearray(cd[p:p + 46 + nlen + xlen + clen])
        if local_off in fix:
            new_local, new_xlen, new_extra = fix[local_off]
            struct.pack_into("<H", entry, 30, new_xlen)
            struct.pack_into("<I", entry, 42, new_local)
            tail = bytes(entry[46 + nlen + xlen:])
            del entry[46 + nlen:]
            entry += new_extra + tail
        out += entry
        p += 46 + nlen + xlen + clen
    cd_out_size = len(out) - cd_out_start

    # ---- EOCD ----
    e = len(data) - 22
    while e >= 0 and struct.unpack_from("<I", data, e)[0] != EOCD_SIG:
        e -= 1
    eocd = bytearray(data[e:])
    struct.pack_into("<I", eocd, 12, cd_out_size)
    struct.pack_into("<I", eocd, 16, cd_out_start)
    out += eocd

    with open(path_out, "wb") as fh:
        fh.write(out)
    return path_out


def verify(path):
    """Check what the platform actually enforces.

    Hard requirements (fail): resources.arsc / .so stored uncompressed, and any
    STORED entry 4-byte aligned, so the platform can mmap it.

    Soft (warn): a DEFLATE entry that is not aligned. Normal apksigner output
    looks like this for its own META-INF/*.SF|RSA entries - they are written
    after alignment and cannot be moved afterwards without breaking the v2/v3
    signatures, which cover the file byte-for-byte. Android does not require
    them to be aligned.
    """
    lines, ok, warns = [], True, 0
    with zipfile.ZipFile(path) as z:
        bad = z.testzip()
        if bad is not None:
            ok = False
            lines.append("  CRC FAILURE in %s" % bad)
        for info in z.infolist():
            with open(path, "rb") as fh:
                fh.seek(info.header_offset)
                hdr = fh.read(30)
                if len(hdr) < 30 or struct.unpack_from("<I", hdr, 0)[0] != LFH_SIG:
                    ok = False
                    lines.append("  BAD LOCAL HEADER at %d" % info.header_offset)
                    continue
                nlen, xlen = struct.unpack_from("<HH", hdr, 26)
            data_off = info.header_offset + 30 + nlen + xlen
            want = want_for(info.filename)
            stored = info.compress_type == zipfile.ZIP_STORED
            must_store = info.filename.endswith(STORED_SUFFIXES)
            if must_store and not stored:
                flag, ok = "FAIL compressed", False
            elif stored and data_off % want != 0:
                flag, ok = "FAIL misaligned", False
            elif data_off % want != 0:
                flag = "warn (deflated, not mmapped)"
                warns += 1
            else:
                flag = "ok"
            lines.append("  %-38s %-8s off=%-9d %%%-4d %s"
                         % (info.filename, "STORED" if stored else "DEFLATE",
                            data_off, want, flag))
    lines.append("  (%d deflated entries not aligned - harmless)" % warns if warns else "")
    return ok, lines


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    flags = [a for a in argv[2:] if a.startswith("--")]
    args = [a for a in argv[2:] if not a.startswith("--")]
    if cmd in ("pack", "align"):
        if cmd == "pack":
            res_apk, dex, out = args[0], args[1], args[2]
            pack(res_apk, dex, out, [tuple(p.split("=", 1)) for p in args[3:]])
            # pack() output is never aligned; always follow with align()
            if "--no-align" not in flags:
                align(out, out)
        else:
            align(args[0], args[1])
        return 0
    if cmd == "verify":
        ok, lines = verify(args[0])
        print("\n".join(l for l in lines if l))
        print("ALIGN/COMPRESSION: %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok else 1
    print("unknown command: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
