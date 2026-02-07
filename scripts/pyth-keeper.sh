#!/usr/bin/env bash
set -euo pipefail

# Pyth feed IDs for CAD, CHF, SEK (USD/X pairs)
FEED_IDS=(
  "0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca"
  "0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8"
  "0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676"
)

HERMES_URL="https://hermes.pyth.network/v2/updates/price/latest"

# Build query string
QUERY=""
for id in "${FEED_IDS[@]}"; do
  QUERY="${QUERY}&ids[]=${id}"
done
QUERY="${QUERY:1}" # strip leading &

echo "Fetching Pyth price updates from Hermes..."
RESPONSE=$(curl -s "${HERMES_URL}?${QUERY}&encoding=hex")

# Extract binary update data from response
VAU_DATA=$(echo "$RESPONSE" | jq -r '.binary.data[]')

# ABI-encode as bytes[] for Forge's vm.envBytes
# Each element is 0x-prefixed hex; we need abi.encode(bytes[])
ENCODED=$(cast abi-encode "f(bytes[])" "[$(echo "$VAU_DATA" | sed 's/^/0x/' | paste -sd, -)]")

export PYTH_UPDATE_DATA="$ENCODED"
echo "PYTH_UPDATE_DATA set (${#ENCODED} chars)"

# Load .env for RPC URL and private key
source .env

echo "Broadcasting Pyth price update to Sepolia..."
forge script script/PythKeeper.s.sol \
  --tc PythKeeper \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast

echo "Done."
