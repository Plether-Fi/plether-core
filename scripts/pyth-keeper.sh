#!/usr/bin/env bash
set -euo pipefail

NETWORK="${NETWORK:-sepolia}"

case "$NETWORK" in
  sepolia)
    FEED_IDS=(
      "0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca"  # CAD
      "0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8"  # CHF
      "0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676"  # SEK
    )
    RPC_URL_VAR="SEPOLIA_RPC_URL"
    PRIVATE_KEY_VAR="TEST_PRIVATE_KEY"
    export PYTH_ADDRESS="0xDd24F84d36BF92C65F92307595335bdFab5Bbd21"
    ;;
  mainnet)
    FEED_IDS=(
      "0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676"  # SEK
    )
    RPC_URL_VAR="MAINNET_RPC_URL"
    PRIVATE_KEY_VAR="PRIVATE_KEY"
    export PYTH_ADDRESS="0x4305FB66699C3B2702D4d05CF36551390A4c69C6"
    ;;
  *)
    echo "Unknown network: $NETWORK (expected 'sepolia' or 'mainnet')" >&2
    exit 1
    ;;
esac

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

VAU_DATA=$(echo "$RESPONSE" | jq -r '.binary.data[]')

ENCODED=$(cast abi-encode "f(bytes[])" "[$(echo "$VAU_DATA" | sed 's/^/0x/' | paste -sd, -)]")

export PYTH_UPDATE_DATA="$ENCODED"
echo "PYTH_UPDATE_DATA set (${#ENCODED} chars)"

if [ -f .env ]; then
  source .env
fi

echo "[$NETWORK] Broadcasting Pyth price update..."
forge script script/PythKeeper.s.sol \
  --tc PythKeeper \
  --rpc-url "$RPC_URL" \
  --broadcast

echo "Done."
