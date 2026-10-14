#!/bin/sh
# Checks the vendored tunnel contract against the live service document.
#
# Prints NOTHING and exits 0 when they match. On drift it prints the diff and
# exits 1. Meant for a scheduled job and for a human hand, never as a CI gate:
# builds must not depend on the network, but drift must not be discovered by
# users either. When it reports, refresh the vendored file and rerun the
# contract test - green means nothing the client depends on changed:
#
#   curl -s https://opentunnel.xyz/openapi.json -o tool/opentunnel-openapi.json
#   flutter test test/tunnel_contract_test.dart
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
curl -s --max-time 30 https://opentunnel.xyz/openapi.json -o "$tmp"
if cmp -s "$tmp" tool/opentunnel-openapi.json; then
  exit 0
fi
diff tool/opentunnel-openapi.json "$tmp" || true
exit 1
