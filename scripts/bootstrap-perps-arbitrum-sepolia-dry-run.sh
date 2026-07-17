#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

: "${ARB_SEPOLIA_RPC_URL:?ARB_SEPOLIA_RPC_URL must be set}"
: "${TEST_PRIVATE_KEY:?TEST_PRIVATE_KEY must be set}"
: "${PERPS_USDC:?PERPS_USDC must be set}"
: "${PERPS_HOUSE_POOL:?PERPS_HOUSE_POOL must be set}"
: "${PERPS_ORDER_ROUTER:?PERPS_ORDER_ROUTER must be set}"
: "${ACTIVATE_TRADING:?ACTIVATE_TRADING must be explicitly set to true or false}"

for dependency in curl jq forge git; do
  command -v "$dependency" >/dev/null || {
    echo "$dependency is required" >&2
    exit 1
  }
done

chain_id_hex="$(
  curl -sS "$ARB_SEPOLIA_RPC_URL" \
    -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
    | jq -er '.result'
)"
if [[ "$chain_id_hex" != "0x66eee" ]]; then
  echo "Expected Arbitrum Sepolia chain id 421614 (0x66eee), got ${chain_id_hex}" >&2
  exit 1
fi

for address in "$PERPS_USDC" "$PERPS_HOUSE_POOL" "$PERPS_ORDER_ROUTER"; do
  if [[ ! "$address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Invalid deployment address: ${address}" >&2
    exit 1
  fi

  code="$(
    curl -sS "$ARB_SEPOLIA_RPC_URL" \
      -H 'content-type: application/json' \
      --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"${address}\",\"latest\"]}" \
      | jq -er '.result'
  )"
  if [[ "$code" == "0x" ]]; then
    echo "No contract code at ${address}" >&2
    exit 1
  fi
done

if [[ "$ACTIVATE_TRADING" != "true" && "$ACTIVATE_TRADING" != "false" ]]; then
  echo "ACTIVATE_TRADING must be exactly true or false" >&2
  exit 1
fi

if [[ "${ALLOW_DIRTY_DEPLOYMENT:-false}" != "true" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to simulate from a dirty worktree. Commit/stash changes or set ALLOW_DIRTY_DEPLOYMENT=true." >&2
  exit 1
fi

echo "Commit: $(git rev-parse HEAD)"
echo "Network: Arbitrum Sepolia (421614)"
echo "ACTIVATE_TRADING=${ACTIVATE_TRADING}"
echo "Dry-running the perps bootstrap phase; no transactions will be broadcast."

forge script script/BootstrapPerpsArbitrumSepolia.s.sol \
  --tc BootstrapPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL"

echo "Bootstrap dry run complete. Review pauser, seed receivers, seed amounts, user mints, and activation state."
