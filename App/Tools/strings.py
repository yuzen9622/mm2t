"""Builds MM2T/Localizable.xcstrings from the keys the compiler extracted and Tools/zh-Hant.json.

Run after an Xcode build (SWIFT_EMIT_LOC_STRINGS=YES):
    python3 App/Tools/strings.py <derived-data-path>
Exits non-zero, listing them, when an extracted key has no translation or a translation is unused.
"""
import glob
import json
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
derived = pathlib.Path(sys.argv[1])
intermediates = derived / "Build/Intermediates.noindex"
# The app target, plus this repo's Swift package targets (their error text is looked up in the app's catalog).
# Searched recursively: Xcode versions name the package targets' intermediate folders differently.
patterns = ["MM2T.build/**/*.stringsdata", "MM2TCore.build/**/*.stringsdata"]
keys = set()
sources = set()
for path in (path for pattern in patterns for path in glob.glob(str(intermediates / pattern), recursive=True)):
    sources.add(str(pathlib.Path(path).parent.relative_to(intermediates)))
    for entries in json.load(open(path)).get("tables", {}).values():
        keys.update(entry["key"] for entry in entries)
for source in sorted(sources):
    print(f"read {source}")
if not keys:
    sys.exit(f"no .stringsdata under {derived}; build the app first")

translations = json.loads((here / "zh-Hant.json").read_text())
missing = sorted(keys - translations.keys())
unused = sorted(translations.keys() - keys)
catalog = {
    "sourceLanguage": "en",
    "version": "1.0",
    "strings": {
        key: {"localizations": {"zh-Hant": {"stringUnit": {"state": "translated", "value": translations[key]}}}}
        for key in sorted(keys) if key in translations
    },
}
(here.parent / "MM2T/Localizable.xcstrings").write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
print(f"{len(catalog['strings'])} strings written")
for key in missing:
    print(f"missing translation: {key!r}")
for key in unused:
    print(f"unused translation: {key!r}")
sys.exit(1 if missing or unused else 0)
