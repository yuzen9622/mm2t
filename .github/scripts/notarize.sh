#!/bin/bash
# Usage: notarize.sh <file>
# Submits a .zip or .dmg to Apple's notary service and fails unless it is Accepted.
# Needs NOTARY_KEY (path to the .p8), APP_STORE_CONNECT_KEY_ID and APP_STORE_CONNECT_ISSUER_ID.
set -euo pipefail

file="$1"
auth=(--key "$NOTARY_KEY" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")

# A rejected submission can exit non-zero; read its status and log either way.
result=$(xcrun notarytool submit "$file" "${auth[@]}" --wait --timeout 1h --output-format json) || true
echo "$result"
id=$(plutil -extract id raw -o - - <<< "$result")
status=$(plutil -extract status raw -o - - <<< "$result")

if [[ "$status" != "Accepted" ]]; then
  echo "::error::Notarization of $(basename "$file") ended as $status"
  xcrun notarytool log "$id" "${auth[@]}" || true
  exit 1
fi
