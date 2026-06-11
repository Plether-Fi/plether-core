#!/usr/bin/env bash
set -euo pipefail

NETWORK="${NETWORK:-arbitrum-sepolia}"

if [ -f .env ]; then
  source .env
fi

format_decimal() {
  local price="$1"
  local expo="$2"

  awk -v price="$price" -v expo="$expo" '
    BEGIN {
      value = price * (10 ^ expo)
      formatted = sprintf("%.10f", value)
      sub(/0+$/, "", formatted)
      sub(/\.$/, "", formatted)
      print formatted
    }
  '
}

log_hermes_prices() {
  echo "[$NETWORK] Hermes latest prices:"

  for i in "${!FEED_IDS[@]}"; do
    local id="${FEED_IDS[$i]}"
    local label="${FEED_LABELS[$i]}"
    local price
    local conf
    local expo
    local publish_time
    local formatted_price
    local formatted_conf

    price=$(echo "$RESPONSE" | jq -r --arg id "${id#0x}" '.parsed[] | select(.id == $id) | .price.price')
    conf=$(echo "$RESPONSE" | jq -r --arg id "${id#0x}" '.parsed[] | select(.id == $id) | .price.conf')
    expo=$(echo "$RESPONSE" | jq -r --arg id "${id#0x}" '.parsed[] | select(.id == $id) | .price.expo')
    publish_time=$(echo "$RESPONSE" | jq -r --arg id "${id#0x}" '.parsed[] | select(.id == $id) | .price.publish_time')

    if [ -z "$price" ] || [ "$price" = "null" ]; then
      echo "  - $label ($id): missing from Hermes response"
      continue
    fi

    formatted_price=$(format_decimal "$price" "$expo")
    formatted_conf=$(format_decimal "$conf" "$expo")
    echo "  - $label ($id): price=$formatted_price conf=$formatted_conf expo=$expo publish_time=$publish_time"
  done
}

log_onchain_prices() {
  echo "[$NETWORK] On-chain Pyth prices after broadcast:"

  for i in "${!FEED_IDS[@]}"; do
    local id="${FEED_IDS[$i]}"
    local label="${FEED_LABELS[$i]}"
    local raw

    raw=$(cast call "$PYTH_ADDRESS" "getPriceUnsafe(bytes32)((int64,uint64,int32,uint256))" "$id" --rpc-url "$RPC_URL")
    echo "  - $label ($id): $raw"
  done
}

case "$NETWORK" in
  arbitrum-sepolia|arbitrum)
    FEED_LABELS=(
      "EUR/USD"
      "USD/JPY"
      "GBP/USD"
      "USD/CAD"
      "USD/SEK"
      "USD/CHF"
    )
    FEED_IDS=(
      "0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b"
      "0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52"
      "0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1"
      "0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca"
      "0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676"
      "0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8"
    )
    RPC_URL_VAR="ARB_SEPOLIA_RPC_URL"
    PRIVATE_KEY_VAR="TEST_PRIVATE_KEY"
    export PYTH_ADDRESS="0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF"
    ;;
  *)
    echo "Unknown network: $NETWORK (expected 'arbitrum-sepolia')" >&2
    exit 1
    ;;
esac

if [ -z "${!PRIVATE_KEY_VAR+x}" ]; then
  echo "Missing env var: $PRIVATE_KEY_VAR" >&2
  exit 1
fi

if [ -z "${!RPC_URL_VAR+x}" ]; then
  echo "Missing env var: $RPC_URL_VAR" >&2
  exit 1
fi

export KEEPER_PRIVATE_KEY="${!PRIVATE_KEY_VAR}"
RPC_URL="${!RPC_URL_VAR}"

HERMES_URL="https://hermes.pyth.network/v2/updates/price/latest"

QUERY=""
for id in "${FEED_IDS[@]}"; do
  QUERY="${QUERY}&ids[]=${id}"
done
QUERY="${QUERY:1}" # strip leading &

echo "[$NETWORK] Fetching Pyth price updates from Hermes (${#FEED_IDS[@]} feeds)..."
RESPONSE=$(curl -s "${HERMES_URL}?${QUERY}&encoding=hex")
log_hermes_prices

VAU_DATA=$(echo "$RESPONSE" | jq -r '.binary.data[]')

ENCODED=$(cast abi-encode "f(bytes[])" "[$(echo "$VAU_DATA" | sed 's/^/0x/' | paste -sd, -)]")

export PYTH_UPDATE_DATA="$ENCODED"
echo "PYTH_UPDATE_DATA set (${#ENCODED} chars)"

if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "DRY_RUN=true; skipping broadcast."
  exit 0
fi

echo "[$NETWORK] Broadcasting Pyth price update..."
forge script script/PythKeeper.s.sol \
  --tc PythKeeper \
  --rpc-url "$RPC_URL" \
  --broadcast

log_onchain_prices

echo "Done."
