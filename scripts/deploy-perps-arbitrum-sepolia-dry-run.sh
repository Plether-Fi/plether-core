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

if [[ "${ALLOW_DIRTY_DEPLOYMENT:-false}" != "true" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to simulate from a dirty worktree. Commit/stash changes or set ALLOW_DIRTY_DEPLOYMENT=true." >&2
  exit 1
fi

echo "Commit: $(git rev-parse HEAD)"
echo "Network: Arbitrum Sepolia (421614)"
echo "Dry-running the perps-only deploy phase; no transactions will be broadcast."

forge script script/DeployPerpsArbitrumSepolia.s.sol \
  --tc DeployPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL"

echo "Deploy dry run complete. Review every create and wiring call before broadcast."
