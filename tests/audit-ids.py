#!/usr/bin/env python3
"""Static audit of the app's view lookups against its layouts.

Why this exists
---------------
v3.4.0 changed the six app slots from a LinearLayout to a FrameLayout (so a slot
could carry its edit badge) and left two activities holding those slots as
LinearLayout. Neither the compiler nor the build caught it - it is a runtime cast,
and the phone found it instead: opening the app threw

    java.lang.ClassCastException: android.widget.FrameLayout cannot be cast to
    android.widget.LinearLayout   at SetupActivity.bindSlots(SetupActivity.java:79)

which, on a home screen, is the phone losing its home screen. So this walks every
`findViewById(R.id.x)` in the app, works out the type it is held in (from a cast,
from the declaration, or from the variable's own declaration in the same file),
reads the type the layout actually declares for that id, and reports:

  WRONG-TYPE  the id exists but is held as something the layout is not
  NO-LAYOUT   the id is not declared by any layout at all
  NO-SUCH-ID  R.id.x is mentioned in Java but no layout declares it

Anything it cannot resolve is skipped rather than guessed, so a clean run means
"no problem found", never "problem hidden".

    python3 tests/audit-ids.py            # exit 1 if anything is wrong
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

# An optional argument points the audit at another copy of the tree, which is how
# the test suite proves the audit still catches the bug it was written for.
ROOT = (os.path.abspath(sys.argv[1]) if len(sys.argv) > 1
        else os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAYOUTS = os.path.join(ROOT, "app", "res", "layout")
SOURCES = os.path.join(ROOT, "app", "src", "dev", "axion", "spsm")

# Android's widget hierarchy, for the parts this app uses: a view declared as the
# key can be held as any of its descendants.
DESCENDANTS = {
    "ViewGroup": [
        "FrameLayout", "LinearLayout", "RelativeLayout", "GridLayout", "TableLayout",
        "TableRow", "RadioGroup", "ScrollView", "HorizontalScrollView", "AdapterView",
        "AbsListView", "AbsSpinner", "ViewAnimator", "ViewFlipper", "ViewSwitcher",
        "ListView", "GridView", "Spinner", "Toolbar", "CalendarView", "DatePicker",
        "TimePicker", "MediaController", "GestureOverlayView",
    ],
    "FrameLayout": [
        "ScrollView", "HorizontalScrollView", "ViewAnimator", "ViewFlipper",
        "ViewSwitcher", "CalendarView", "DatePicker", "TimePicker", "MediaController",
        "GestureOverlayView", "ActionMenuView",
    ],
    "LinearLayout": ["RadioGroup", "TableRow", "NumberPicker", "ActionMenuView"],
    "TextView": [
        "Button", "CompoundButton", "CheckBox", "RadioButton", "Switch", "ToggleButton",
        "EditText", "AutoCompleteTextView", "MultiAutoCompleteTextView", "TextClock",
        "CheckedTextView",
    ],
    "Button": ["CompoundButton", "CheckBox", "RadioButton", "Switch", "ToggleButton"],
    "CompoundButton": ["CheckBox", "RadioButton", "Switch", "ToggleButton"],
    "ImageView": ["ImageButton"],
    "AbsListView": ["ListView", "GridView"],
    "AbsSpinner": ["Spinner"],
    "AdapterView": ["AbsListView", "AbsSpinner"],
    "AbsSeekBar": ["SeekBar", "RatingBar"],
    "ProgressBar": ["AbsSeekBar", "SeekBar", "RatingBar"],
}

# Anything held as one of these accepts anything.
UNIVERSAL = {"View", "ViewGroup", "Object"}

# Every widget name this audit understands; a cast to anything else is left alone
# rather than guessed at.
KNOWN_WIDGETS = set(UNIVERSAL)
KNOWN_WIDGETS.update(DESCENDANTS.keys())
for _kids in DESCENDANTS.values():
    KNOWN_WIDGETS.update(_kids)
KNOWN_WIDGETS.update({
    "TextView", "ImageView", "Button", "ImageButton", "ListView", "GridView",
    "ScrollView", "HorizontalScrollView", "FrameLayout", "LinearLayout",
    "RelativeLayout", "EditText", "CheckBox", "Switch", "Spinner", "ProgressBar",
})


def short(name):
    return name.rsplit(".", 1)[-1]


def descendants(cls):
    seen, stack = set(), [short(cls)]
    while stack:
        cur = stack.pop()
        for child in DESCENDANTS.get(cur, []):
            if child not in seen:
                seen.add(child)
                stack.append(child)
    return seen


def compatible(declared, held):
    """Can something the layout declares as `declared` be held as `held`?"""
    declared, held = short(declared), short(held)
    if declared == held:
        return True
    if held in UNIVERSAL or declared in UNIVERSAL:
        return True
    if declared in UNIVERSAL:
        return True
    return declared in descendants(held)


def layout_types():
    """id -> list of (layout name, declared element type), and include roots."""
    roots = {}
    for name in sorted(os.listdir(LAYOUTS)):
        if not name.endswith(".xml"):
            continue
        try:
            tree = ET.parse(os.path.join(LAYOUTS, name))
        except ET.ParseError as e:
            print("PARSE-ERROR %s: %s" % (name, e))
            continue
        roots[name[:-4]] = short(tree.getroot().tag)

    ids = {}
    for name in sorted(os.listdir(LAYOUTS)):
        if not name.endswith(".xml"):
            continue
        base = name[:-4]
        try:
            tree = ET.parse(os.path.join(LAYOUTS, name))
        except ET.ParseError:
            continue
        for elem in tree.getroot().iter():
            tag = short(elem.tag)
            the_id = elem.get("{http://schemas.android.com/apk/res/android}id")
            if the_id is None:
                continue
            # "@+id/slot0" -> "slot0"
            the_id = the_id.rsplit("/", 1)[-1]
            if tag == "include":
                inc = elem.get("layout") or ""
                inc = inc.rsplit("/", 1)[-1]
                tag = roots.get(inc, "include")
            ids.setdefault(the_id, []).append((base, tag))
    return ids


DECL = re.compile(r"\b(?:final\s+)?([A-Za-z_][\w.]*)\s+(\w+)\s*(?:=|;)")


ARRAY = re.compile(r"int\[\]\s+(\w+)\s*=\s*\{([^}]*)\}", re.S)


def java_usages():
    """(file, line, id, held-as-or-None) for every findViewById and R.id mention."""
    out = []
    for name in sorted(os.listdir(SOURCES)):
        if not name.endswith(".java"):
            continue
        path = os.path.join(SOURCES, name)
        text = open(path, encoding="utf-8", errors="replace").read()
        lines = text.split("\n")
        # Arrays of ids, so `findViewById(slotIds[i])` resolves to each of them.
        # This is the form that crashed on the phone: the loop looked like a plain
        # getElementById call and the cast was invisible to a grep.
        arrays = {}
        for arr, body in ARRAY.findall(text):
            arrays[arr] = re.findall(r"R\.id\.(\w+)", body)
        # Variable types declared anywhere in the file, so `x = findViewById(...)`
        # with x declared as a field is still resolved.
        vartype = {}
        for line in lines:
            for typ, var in DECL.findall(line):
                if typ in ("return", "new", "if", "else", "case", "import", "package"):
                    continue
                vartype.setdefault(var, typ)

        # Variables that hold a view from a known id, so a later CAST of that
        # variable can be checked against the layout too:
        #   editButton = findViewById(R.id.btn_edit);  ...  (ImageButton) editButton
        # That cast is invisible to the compiler and would throw on a phone whose
        # layout declares something else.
        var_id = {}
        for num, line in enumerate(lines, 1):
            for m in re.finditer(r"(\w+)\s*=\s*findViewById\(\s*R\.id\.(\w+)\s*\)", line):
                var_id[m.group(1)] = m.group(2)
            for m in re.finditer(r"findViewById\(\s*(\w+)\s*\[", line):
                for one in arrays.get(m.group(1), []):
                    var_id.setdefault("__array__" + m.group(1), one)
            for m in re.finditer(r"(\w+)\s*=\s*findViewById\(\s*(\w+)\s*\[", line):
                ids_here = arrays.get(m.group(2))
                if ids_here:
                    var_id[m.group(1)] = ids_here[0]

        for num, line in enumerate(lines, 1):
            # findViewById(<array>[i]) - the id comes from the array, and the
            # held type is the variable the result is assigned to.
            for m in re.finditer(r"findViewById\(\s*(\w+)\s*\[", line):
                arr = m.group(1)
                ids_here = arrays.get(arr)
                if not ids_here:
                    continue
                before = line[:m.start()]
                held = None
                decl = re.search(r"([A-Za-z_][\w.]*)\s+\w+\s*=\s*$", before)
                if decl:
                    held = decl.group(1)
                for one in ids_here:
                    out.append((name, num, one, held))

            for m in re.finditer(r"findViewById\(\s*R\.id\.(\w+)\s*\)", line):
                the_id = m.group(1)
                before = line[:m.start()]
                held = None
                cast = re.search(r"\(\s*([A-Za-z_][\w.]*)\s*\)\s*$", before)
                if cast:
                    held = cast.group(1)
                else:
                    decl = re.search(r"([A-Za-z_][\w.]*)\s+(\w+)\s*=\s*$", before)
                    if decl:
                        held = decl.group(1)
                    else:
                        assign = re.search(r"(\w+)\s*=\s*$", before)
                        if assign:
                            held = vartype.get(assign.group(1))
                        else:
                            chain = re.search(r"(\w+)\.findViewById\(\s*R\.id\.\w+\s*\)\s*$", before)
                            if chain:
                                held = None      # a chained lookup: type unknown
                out.append((name, num, the_id, held))

            # A cast of a variable that holds a view: is that cast even possible?
            for m in re.finditer(r"\(\s*([A-Za-z_][\w.]*)\s*\)\s*(\w+)\b", line):
                cast_type, var = m.group(1), m.group(2)
                the_id = var_id.get(var)
                if not the_id or short(cast_type) not in KNOWN_WIDGETS:
                    continue
                out.append((name, num, the_id, cast_type, "cast of " + var))
    return out


def main():
    ids = layout_types()
    problems = 0
    checked = 0
    for usage in java_usages():
        name, num, the_id, held = usage[0], usage[1], usage[2], usage[3]
        what = usage[4] if len(usage) > 4 else "holds"
        decls = ids.get(the_id)
        where = "%s:%d" % (name, num)
        if not decls:
            print("NO-SUCH-ID  %s mentions R.id.%s, which no layout declares"
                  % (where, the_id))
            problems += 1
            continue
        if held is None:
            continue
        checked += 1
        if not any(compatible(t, held) for _layout, t in decls):
            print("WRONG-TYPE  %s %s R.id.%s as %s, but the layout declares %s"
                  % (where, what, the_id, short(held),
                     " / ".join("%s (%s)" % (t, l) for l, t in decls)))
            problems += 1

    print("checked %d typed view lookups against %d declared ids in %d layouts"
          % (checked, len(ids), len([f for f in os.listdir(LAYOUTS) if f.endswith(".xml")])))
    if problems:
        print("%d problem(s): each one is a crash waiting for the right screen"
              % problems)
        return 1
    print("no view is held as something its layout is not")
    return 0


if __name__ == "__main__":
    sys.exit(main())
