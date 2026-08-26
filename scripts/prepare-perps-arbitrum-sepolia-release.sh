#!/usr/bin/env bash
set -euo pipefail

release_env_file="${PERPS_RELEASE_ENV_FILE:-.env.arbitrum-sepolia-perps}"
if [[ -f "$release_env_file" ]]; then
  # shellcheck disable=SC1090
  source "$release_env_file"
fi

: "${ARB_SEPOLIA_RPC_URL:?ARB_SEPOLIA_RPC_URL must be set}"
: "${TEST_PRIVATE_KEY:?TEST_PRIVATE_KEY must be set}"
: "${PYTH_API_KEY:?PYTH_API_KEY must be set}"
: "${RELEASE_COMMIT:?RELEASE_COMMIT must be set to the reviewed release commit}"

release_pyth="0x0B73614636C855Bf23F342F307FB981A3e47f42B"
hermes_url="${HERMES_BASE_URL:-https://pyth.dourolabs.app/hermes/v2/updates/price/latest}"
feed_ids=(
  "0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b"
  "0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52"
  "0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1"
  "0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca"
  "0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676"
  "0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8"
)

for command_name in git forge cast curl jq; do
  command -v "$command_name" >/dev/null || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

forge_version="$(forge --version | head -n 1)"
[[ "$forge_version" == "forge Version: 1.5.1-stable" ]] || {
  echo "Expected Forge 1.5.1-stable, found: $forge_version" >&2
  exit 1
}

git fetch --quiet origin master
[[ -z "$(git status --porcelain)" ]] || {
  echo "Release worktree must be clean" >&2
  exit 1
}
[[ "$(git rev-parse HEAD)" == "$RELEASE_COMMIT" ]] || {
  echo "HEAD does not match RELEASE_COMMIT" >&2
  exit 1
}
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/master)" ]] || {
  echo "HEAD is not the fetched origin/master" >&2
  exit 1
}
if git submodule status --recursive | grep -Eq '^[+-]'; then
  echo "Submodules are missing or do not match their pinned commits" >&2
  exit 1
fi

forge fmt --check
bash scripts/check-package-boundaries.sh

chain_id="$(cast chain-id --rpc-url "$ARB_SEPOLIA_RPC_URL")"
[[ "$chain_id" == "421614" ]] || {
  echo "Expected Arbitrum Sepolia chain id 421614, found $chain_id" >&2
  exit 1
}

pyth_code="$(cast code "$release_pyth" --rpc-url "$ARB_SEPOLIA_RPC_URL")"
[[ "$pyth_code" != "0x" ]] || {
  echo "Upgraded Pyth address has no code" >&2
  exit 1
}

deployer="$(cast wallet address --private-key "$TEST_PRIVATE_KEY")"
deployer_balance="$(cast balance "$deployer" --rpc-url "$ARB_SEPOLIA_RPC_URL")"
[[ "$deployer_balance" =~ ^[0-9]+$ && "$deployer_balance" -gt 0 ]] || {
  echo "Deployer has no Arbitrum Sepolia ETH" >&2
  exit 1
}

query=""
for feed_id in "${feed_ids[@]}"; do
  query+="&ids[]=${feed_id}"
done
query="${query:1}"

hermes_response="$(
  curl -fsS \
    -H "Authorization: Bearer ${PYTH_API_KEY}" \
    "${hermes_url}?${query}&encoding=hex&parsed=true"
)"
jq -e '.parsed | length == 6' >/dev/null <<<"$hermes_response"
jq -e '.binary.data | length > 0' >/dev/null <<<"$hermes_response"

update_csv="$(jq -r '.binary.data[] | "0x" + .' <<<"$hermes_response" | paste -sd, -)"
[[ -n "$update_csv" ]] || {
  echo "Hermes returned no binary update payload" >&2
  exit 1
}
cast call "$release_pyth" "getUpdateFee(bytes[])(uint256)" "[$update_csv]" \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" >/dev/null

echo "Running no-broadcast deployment simulation from $RELEASE_COMMIT..."
forge script script/DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL"

echo "Preflight and authenticated upgraded-Pyth dry run passed. No transactions were broadcast."
