#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="${1:?entitlements template path required}"
PROFILE="${2:?provisioning profile path required}"
OUTPUT="${3:?resolved entitlements output path required}"
CONTAINER_ID="${4:?iCloud container identifier required}"

PROFILE_PLIST="$(mktemp)"
trap 'rm -f "$PROFILE_PLIST"' EXIT
/usr/bin/security cms -D -i "$PROFILE" > "$PROFILE_PLIST"

TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
[ -n "$TEAM_ID" ] || { echo "provisioning profile has no team identifier" >&2; exit 1; }

/usr/libexec/PlistBuddy \
  -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$PROFILE_PLIST" \
  | /usr/bin/grep -Fq "$CONTAINER_ID" \
  || { echo "provisioning profile does not allow $CONTAINER_ID" >&2; exit 1; }

/bin/cp "$TEMPLATE" "$OUTPUT"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.developer.ubiquity-container-identifiers:0 $TEAM_ID.$CONTAINER_ID" "$OUTPUT"
/usr/bin/plutil -lint "$OUTPUT" >/dev/null
