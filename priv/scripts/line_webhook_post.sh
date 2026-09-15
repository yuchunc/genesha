#!/usr/bin/env bash
# Posts a correctly-signed LINE webhook delivery at a running server, and
# prints the HTTP status. This is the only part of the stack that the offline
# script (priv/scripts/line_smoke.exs) cannot reach: endpoint -> RawBodyPlug ->
# Plug.Parsers -> VerifySignaturePlug -> controller.
#
#   LINE_CHANNEL_SECRET=<same secret the server booted with> \
#     priv/scripts/line_webhook_post.sh event.json [url]
#
#   # read the body from stdin
#   ... | priv/scripts/line_webhook_post.sh - http://localhost:4000/line/webhook
#
#   # forge the signature to prove the plug is fail-closed (expects 403)
#   LINE_SIGNATURE_OVERRIDE=bogus priv/scripts/line_webhook_post.sh event.json
set -euo pipefail

: "${LINE_CHANNEL_SECRET:?set LINE_CHANNEL_SECRET to the value the server booted with}"

BODY_SRC="${1:--}"
URL="${2:-http://localhost:4000/line/webhook}"
BODY="$(cat -- "$BODY_SRC")"

if [ -n "${LINE_SIGNATURE_OVERRIDE:-}" ]; then
  SIG="$LINE_SIGNATURE_OVERRIDE"
else
  # LINE signs the exact request bytes: Base64(HMAC-SHA256(channel_secret, body))
  SIG="$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$LINE_CHANNEL_SECRET" -binary | base64)"
fi

curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST "$URL" \
  -H 'content-type: application/json' \
  -H "x-line-signature: $SIG" \
  --data-binary "$BODY"
