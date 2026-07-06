#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  source .env
fi

: "${ARB_SEPOLIA_RPC_URL:?ARB_SEPOLIA_RPC_URL must be set}"
: "${TEST_PRIVATE_KEY:?TEST_PRIVATE_KEY must be set}"

export SPOT_USDC="${SPOT_USDC:-${PERPS_USDC:-0xf1e1B188b87525C51ECe4bae8627ae621D769651}}"

FEED_IDS=(
  "0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b"
  "0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52"
  "0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1"
  "0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca"
  "0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676"
  "0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8"
)

HERMES_URL="https://hermes.pyth.network/v2/updates/price/latest"

QUERY=""
for id in "${FEED_IDS[@]}"; do
  QUERY="${QUERY}&ids[]=${id}"
done
QUERY="${QUERY:1}"

echo "Fetching Pyth price updates from Hermes..."
RESPONSE=$(curl -s "${HERMES_URL}?${QUERY}&encoding=hex")
VAU_DATA=$(echo "$RESPONSE" | jq -r '.binary.data[]')
ENCODED=$(cast abi-encode "f(bytes[])" "[$(echo "$VAU_DATA" | sed 's/^/0x/' | paste -sd, -)]")

export PYTH_UPDATE_DATA="$ENCODED"
echo "PYTH_UPDATE_DATA set (${#ENCODED} chars)"
echo "Using SPOT_USDC=${SPOT_USDC}"
echo "Dry-running Plether spot deployment to Arbitrum Sepolia..."

forge script script/DeploySpotArbitrumSepolia.s.sol \
  --tc DeploySpotArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL"

echo "Dry run complete. No transactions were broadcast."
