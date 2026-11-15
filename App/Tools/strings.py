"""Validates the app's and the widget's Localizable.xcstrings against compiler-extracted keys without modifying them.

Run after an Xcode build (SWIFT_EMIT_LOC_STRINGS=YES):
    python3 App/Tools/strings.py <derived-data-path>
Exits non-zero when a key lacks a completed zh-Hant translation or a catalog key is unused.
"""
import glob
import json
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
derived = pathlib.Path(sys.argv[1])
intermediates = derived / "Build/Intermediates.noindex"
widget = "/mm2tWidget.build/"
# Each catalog with the targets whose strings it translates. The app's covers the app target plus this
# repo's Swift package targets (their error text is looked up in the app's catalog); the widget
# extension is a separate bundle with its own catalog. Searched recursively: Xcode versions name the
# package targets' intermediate folders differently.
checks = [
    ("MM2T/Localizable.xcstrings", ["MM2T.build/**/*.stringsdata", "MM2TCore.build/**/*.stringsdata"], lambda path: widget not in path),
    ("Widget/Localizable.xcstrings", ["MM2T.build/**/*.stringsdata"], lambda path: widget in path),
]
failed = False
for catalog_path, patterns, belongs in checks:
    keys = set()
    sources = set()
    for path in (path for pattern in patterns for path in glob.glob(str(intermediates / pattern), recursive=True)):
        if not belongs(path):
            continue
        sources.add(str(pathlib.Path(path).parent.relative_to(intermediates)))
        for entries in json.load(open(path)).get("tables", {}).values():
            keys.update(entry["key"] for entry in entries)
    for source in sorted(sources):
        print(f"read {source}")
    if not keys:
        sys.exit(f"no .stringsdata for {catalog_path} under {derived}; build the app first")

    catalog = json.loads((here.parent / catalog_path).read_text())["strings"]
    missing = []
    for key in sorted(keys):
        unit = catalog.get(key, {}).get("localizations", {}).get("zh-Hant", {}).get("stringUnit", {})
        if unit.get("state") != "translated" or not unit.get("value", "").strip():
            missing.append(key)
    unused = sorted(catalog.keys() - keys)
    print(f"{catalog_path}: {len(keys)} extracted strings checked")
    for key in missing:
        print(f"missing translation: {key!r}")
    for key in unused:
        print(f"unused translation: {key!r}")
    failed = failed or bool(missing or unused)
sys.exit(1 if failed else 0)
