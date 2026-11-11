"""Usage: check_appcast.py <appcast.xml> <version> <dmg-name>

Prints the EdDSA signature of the appcast item for <version>. Exits non-zero when that item is
missing, points at another file, or has no signature: generate_appcast writes an unsigned item
without failing when the private key does not match the app's SUPublicEDKey.
"""
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

path, version, dmg = sys.argv[1:4]
items = [
    item for item in ET.parse(path).getroot().iter("item")
    if item.findtext(f"{SPARKLE}version") == version
]
if len(items) != 1:
    sys.exit(f"expected one appcast item for {version}, found {len(items)}")
enclosure = items[0].find("enclosure")
if enclosure is None or not enclosure.get("url", "").endswith("/" + dmg):
    sys.exit(f"the {version} item does not point at {dmg}")
signature = enclosure.get(f"{SPARKLE}edSignature")
if not signature:
    sys.exit(f"the {version} item has no sparkle:edSignature; SPARKLE_ED_PRIVATE_KEY does not match SUPublicEDKey")
print(signature)
