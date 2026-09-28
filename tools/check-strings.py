#!/usr/bin/env python3
"""Prüft, dass jeder L("…")-Text im Code eine englische und französische Übersetzung hat – und keine verwaist ist."""
import glob, re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
keys = []
for f in sorted(glob.glob(str(root / "Sources/Steno/*.swift"))):
    for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', open(f, encoding="utf-8").read()):
        if m.group(1) not in keys:
            keys.append(m.group(1))
ok = True
for lang in ["en", "fr"]:
    have = dict(re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$',
                           open(root / f"Resources/{lang}.lproj/Localizable.strings", encoding="utf-8").read(), re.M))
    missing = [k for k in keys if k not in have]
    unused = [k for k in have if k not in keys]
    bad_format = [k for k in keys if k in have and sorted(re.findall(r"%(?:lld|@)", k)) != sorted(re.findall(r"%(?:lld|@)", have[k]))]
    for k in missing: print(f"[{lang}] fehlt: {k}")
    for k in unused: print(f"[{lang}] unbenutzt: {k}")
    for k in bad_format: print(f"[{lang}] Platzhalter passen nicht: {k}")
    ok &= not (missing or unused or bad_format)
print(f"{len(keys)} Texte geprüft – " + ("alles übersetzt" if ok else "siehe oben"))
sys.exit(0 if ok else 1)
