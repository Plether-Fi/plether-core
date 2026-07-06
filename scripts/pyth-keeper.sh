#!/usr/bin/env bash
set -euo pipefail

NETWORK="${NETWORK:-sepolia}"

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
  sepolia)
    FEED_LABELS=(
      "USD/CAD"
      "USD/CHF"
      "USD/SEK"
    )
    FEED_IDS=(
      "0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca"
      "0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8"
      "0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676"
    )
    RPC_URL_VAR="SEPOLIA_RPC_URL"
    FALLBACK_PRIVATE_KEY_VAR="TEST_PRIVATE_KEY"
    export PYTH_ADDRESS="0xDd24F84d36BF92C65F92307595335bdFab5Bbd21"
    ;;
  mainnet)
    FEED_LABELS=(
      "USD/SEK"
    )
    FEED_IDS=(
      "0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676"
    )
    RPC_URL_VAR="MAINNET_RPC_URL"
    FALLBACK_PRIVATE_KEY_VAR="PRIVATE_KEY"
    export PYTH_ADDRESS="0x4305FB66699C3B2702D4d05CF36551390A4c69C6"
    ;;
  *)
    echo "Unknown network: $NETWORK (expected 'sepolia' or 'mainnet')" >&2
    exit 1
    ;;
esac

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

if [ -z "${!RPC_URL_VAR+x}" ]; then
  echo "Missing env var: $RPC_URL_VAR" >&2
  exit 1
fi
RPC_URL="${!RPC_URL_VAR}"

if [ -z "${KEEPER_PRIVATE_KEY+x}" ]; then
  fallback_private_key="${!FALLBACK_PRIVATE_KEY_VAR:-}"
  if [ -n "$fallback_private_key" ]; then
    export KEEPER_PRIVATE_KEY="$fallback_private_key"
  fi
fi

if [ -z "${KEEPER_PRIVATE_KEY+x}" ]; then
  echo "Missing env var: KEEPER_PRIVATE_KEY (or fallback $FALLBACK_PRIVATE_KEY_VAR)" >&2
  exit 1
fi

echo "[$NETWORK] Broadcasting Pyth price update..."
forge script script/PythKeeper.s.sol \
  --tc PythKeeper \
  --rpc-url "$RPC_URL" \
  --broadcast

log_onchain_prices

echo "Done."
