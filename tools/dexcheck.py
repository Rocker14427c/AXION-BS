#!/usr/bin/env python3
"""Read a built APK's dex and say whether the methods we expect are in it.

Why this exists
---------------
v3.4.0 shipped an APK whose Java was wrong in a way only a phone could see: the
slot layout's root had become a FrameLayout while the code still cast it to a
LinearLayout, so opening the app threw a ClassCastException on resume. The
source is audited (tests/audit-ids.py), but the source is not what the user
installs - the APK is. This reads the dex out of the APK and checks the method
signatures, so a build can be told "the APK really does carry the fix" instead of
"the source looked right".

    python3 tools/dexcheck.py <apk> "Ldev/axion/spsm/Apps;->bindSlot(Landroid/content/Context;Landroid/view/View;ILdev/axion/spsm/Apps$SlotClick;)V"

Exit 0 when every signature is present, 1 otherwise. No external tools: it walks
the dex header, string/type/proto/method id tables itself.
"""

import struct
import sys
import zipfile


def uleb(data, off):
    result = shift = 0
    while True:
        b = data[off]
        off += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, off
        shift += 7


class Dex:
    def __init__(self, data):
        self.d = data
        # Read by name, not by a run of eight: field_ids sits between proto_ids
        # and method_ids, and reading straight through picks up the field table
        # and silently reports field names as methods.
        get = lambda off: struct.unpack_from("<I", data, off)[0]
        self.string_ids_size, self.string_ids_off = get(56), get(60)
        self.type_ids_size, self.type_ids_off = get(64), get(68)
        self.proto_ids_size, self.proto_ids_off = get(72), get(76)
        self.method_ids_size, self.method_ids_off = get(88), get(92)
        self.strings = [self._string(i) for i in range(self.string_ids_size)]
        self.types = [self.strings[struct.unpack_from("<I", data, self.type_ids_off + 4 * i)[0]]
                      for i in range(self.type_ids_size)]

    def _string(self, i):
        off = struct.unpack_from("<I", self.d, self.string_ids_off + 4 * i)[0]
        _n, off = uleb(self.d, off)
        end = self.d.index(b"\x00", off)
        return self.d[off:end].decode("utf-8", "replace")

    def _proto(self, i):
        shorty_i, return_i, params_off = struct.unpack_from(
            "<3I", self.d, self.proto_ids_off + 12 * i)
        params = []
        if params_off:
            size = struct.unpack_from("<I", self.d, params_off)[0]
            params = [self.types[struct.unpack_from("<H", self.d, params_off + 4 + 2 * k)[0]]
                      for k in range(size)]
        return params, self.types[return_i]

    def methods(self):
        for i in range(self.method_ids_size):
            class_i, proto_i, name_i = struct.unpack_from(
                "<2HI", self.d, self.method_ids_off + 8 * i)
            params, ret = self._proto(proto_i)
            yield "%s->%s(%s)%s" % (self.types[class_i], self.strings[name_i],
                                    "".join(params), ret)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    apk, wanted = sys.argv[1], sys.argv[2:]
    found = set()
    with zipfile.ZipFile(apk) as z:
        names = sorted(n for n in z.namelist() if n.endswith(".dex"))
        for name in names:
            for sig in Dex(z.read(name)).methods():
                found.add(sig)

    missing = [w for w in wanted if w not in found]
    for w in wanted:
        print("  %-96s %s" % (w, "ok" if w in found else "MISSING"))
    print("  read %d methods from %d dex file(s) in %s"
          % (len(found), len(names), apk))
    if missing:
        print("%d signature(s) missing: the APK the user would install is not "
              "the one this source describes" % len(missing))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
