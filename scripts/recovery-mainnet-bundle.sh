#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-simulate}"
if [[ "$MODE" != "prepare" && "$MODE" != "simulate" && "$MODE" != "send" ]]; then
    echo "Usage: $0 [prepare|simulate|send]" >&2
    exit 2
fi

if [[ "$MODE" == "send" && "${BROADCAST_RECOVERY_BUNDLE:-}" != "YES" ]]; then
    echo "ERROR: Set BROADCAST_RECOVERY_BUNDLE=YES to enable submission" >&2
    exit 1
fi

for command in cast curl jq; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Missing required command: $command" >&2
        exit 1
    fi
done

: "${MAINNET_RPC_URL:?Set MAINNET_RPC_URL}"
: "${PRIVATE_KEY:?Set PRIVATE_KEY}"

# These defaults are deliberately pinned to the verified Ethereum mainnet deployment.
OWNER="${RECOVERY_OWNER:-0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B}"
SPLITTER="${RECOVERY_SPLITTER:-0x81D7f6eE951f5272043de05E6EE25c58a440c2DF}"
REWARD_DISTRIBUTOR="${RECOVERY_REWARD_DISTRIBUTOR:-0x34558F6eC05F91773b7d269f50ce0bbeC4403760}"
PYTH_ADAPTER="${RECOVERY_PYTH_ADAPTER:-0xEf0e44465a18f848165Bf1A007BE51f628a6FC06}"
USDC="${RECOVERY_USDC:-0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48}"
PYTH_PRICE_ID="${RECOVERY_PYTH_PRICE_ID:-8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676}"

FLASHBOTS_RELAY="${FLASHBOTS_RELAY:-https://relay.flashbots.net}"
FLASHBOTS_AUTH_KEY="${FLASHBOTS_AUTH_KEY:-$PRIVATE_KEY}"
HERMES_URL="${HERMES_URL:-https://hermes.pyth.network}"
MAX_PYTH_AGE_SECONDS="${MAX_PYTH_AGE_SECONDS:-120}"
BUNDLE_ATTEMPTS="${BUNDLE_ATTEMPTS:-5}"
PRIORITY_FEE_WEI="${PRIORITY_FEE_WEI:-2000000000}"

GAS_UNPAUSE="${GAS_UNPAUSE:-100000}"
GAS_HARVEST="${GAS_HARVEST:-1500000}"
GAS_DISTRIBUTE="${GAS_DISTRIBUTE:-2500000}"
GAS_EJECT="${GAS_EJECT:-1200000}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

lower() {
    tr '[:upper:]' '[:lower:]' <<<"$1"
}

rpc() {
    cast rpc --rpc-url "$MAINNET_RPC_URL" "$@"
}

relay_request() {
    local body="$1"
    local body_hash auth_signature auth_address

    body_hash=$(cast keccak "$body")
    # Flashbots signs the ASCII representation of keccak256(body), EIP-191 prefixed.
    auth_signature=$(cast wallet sign "$(cast from-utf8 "$body_hash")" --private-key "$FLASHBOTS_AUTH_KEY")
    auth_address=$(cast wallet address --private-key "$FLASHBOTS_AUTH_KEY")

    curl --fail-with-body --silent --show-error \
        -X POST \
        -H "Content-Type: application/json" \
        -H "X-Flashbots-Signature: ${auth_address}:${auth_signature}" \
        --data-binary "$body" \
        "$FLASHBOTS_RELAY"
}

make_simulation_body() {
    local target_block_hex="$1"
    local timestamp="$2"
    jq -cn \
        --argjson txs "$TXS_JSON" \
        --arg block "$target_block_hex" \
        --argjson timestamp "$timestamp" \
        '{jsonrpc:"2.0",id:1,method:"eth_callBundle",params:[{txs:$txs,blockNumber:$block,stateBlockNumber:"latest",timestamp:$timestamp}]}'
}

make_send_body() {
    local target_block_hex="$1"
    jq -cn \
        --argjson txs "$TXS_JSON" \
        --arg block "$target_block_hex" \
        '{jsonrpc:"2.0",id:1,method:"eth_sendBundle",params:[{txs:$txs,blockNumber:$block}]}'
}

simulate_bundle() {
    local target_block="$1"
    local latest_timestamp now simulation_timestamp target_block_hex body response result_count

    target_block_hex=$(cast to-hex "$target_block")
    latest_timestamp=$(cast block latest --field timestamp --rpc-url "$MAINNET_RPC_URL")
    now=$(date +%s)
    simulation_timestamp=$((latest_timestamp + 12))
    if (( simulation_timestamp < now + 12 )); then
        simulation_timestamp=$((now + 12))
    fi

    body=$(make_simulation_body "$target_block_hex" "$simulation_timestamp")
    response=$(relay_request "$body")

    if [[ "$(jq -r '.error // empty' <<<"$response")" != "" ]]; then
        jq . <<<"$response" >&2
        fail "Flashbots simulation request failed"
    fi

    result_count=$(jq '.result.results | length' <<<"$response")
    [[ "$result_count" == "4" ]] || {
        jq . <<<"$response" >&2
        fail "Simulation returned $result_count results instead of 4"
    }

    if jq -e '.result.results[] | select((.error // "") != "" or (.revert // "") != "")' <<<"$response" >/dev/null; then
        jq '.result.results | to_entries[] | {transaction:(.key + 1), value:.value}' <<<"$response" >&2
        fail "At least one bundled transaction reverts"
    fi

    echo "Simulation succeeded for block $target_block:"
    jq -r '
        .result.results
        | to_entries[]
        | "  tx\(.key + 1): gasUsed=\(.value.gasUsed) hash=\(.value.txHash)"
    ' <<<"$response"
    echo "  totalGasUsed=$(jq -r '.result.totalGasUsed' <<<"$response")"
}

receipt_json() {
    local tx_hash="$1"
    rpc eth_getTransactionReceipt "$tx_hash"
}

verify_inclusion() {
    local receipt status block_number expected_block="" final_paused final_adapter final_adapter_shares final_rd_usdc
    local tx_hash

    for tx_hash in "$TX1_HASH" "$TX2_HASH" "$TX3_HASH" "$TX4_HASH"; do
        receipt=$(receipt_json "$tx_hash")
        if [[ "$receipt" == "null" ]]; then
            return 1
        fi

        status=$(jq -r '.status' <<<"$receipt")
        [[ "$status" == "0x1" ]] || fail "Included transaction $tx_hash failed with status $status"
        block_number=$(jq -r '.blockNumber' <<<"$receipt")
        if [[ -z "$expected_block" ]]; then
            expected_block="$block_number"
        elif [[ "$block_number" != "$expected_block" ]]; then
            fail "Bundle transactions were not included in the same block"
        fi
    done

    final_paused=$(cast call "$SPLITTER" 'paused()(bool)' --rpc-url "$MAINNET_RPC_URL")
    final_adapter=$(cast call "$SPLITTER" 'yieldAdapter()(address)' --rpc-url "$MAINNET_RPC_URL")
    final_adapter_shares=$(cast call "$final_adapter" 'balanceOf(address)(uint256)' "$SPLITTER" \
        --rpc-url "$MAINNET_RPC_URL" | awk '{print $1}')
    final_rd_usdc=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$REWARD_DISTRIBUTOR" \
        --rpc-url "$MAINNET_RPC_URL" | awk '{print $1}')
    [[ "$final_paused" == "true" ]] || fail "Included bundle did not leave the splitter paused"
    [[ "$final_adapter_shares" == "0" ]] || fail "Included bundle left $final_adapter_shares splitter adapter shares"
    [[ "$final_rd_usdc" == "0" ]] || fail "Included bundle left $final_rd_usdc USDC base units in the distributor"

    echo "RECOVERY BUNDLE INCLUDED atomically in block $((expected_block))"
    echo "  unpause:     $TX1_HASH"
    echo "  harvest:     $TX2_HASH"
    echo "  distribution:$TX3_HASH"
    echo "  eject:       $TX4_HASH"
    return 0
}

chain_id=$(cast chain-id --rpc-url "$MAINNET_RPC_URL")
[[ "$chain_id" == "1" ]] || fail "RPC is chain $chain_id, expected Ethereum mainnet (1)"

signer=$(cast wallet address --private-key "$PRIVATE_KEY")
[[ "$(lower "$signer")" == "$(lower "$OWNER")" ]] || fail "PRIVATE_KEY signs for $signer, expected $OWNER"

splitter_owner=$(cast call "$SPLITTER" 'owner()(address)' --rpc-url "$MAINNET_RPC_URL")
[[ "$(lower "$splitter_owner")" == "$(lower "$OWNER")" ]] || fail "Splitter owner is $splitter_owner, expected $OWNER"

paused=$(cast call "$SPLITTER" 'paused()(bool)' --rpc-url "$MAINNET_RPC_URL")
[[ "$paused" == "true" ]] || fail "Splitter must be paused before this recovery bundle"

splitter_code=$(cast code "$SPLITTER" --rpc-url "$MAINNET_RPC_URL")
distributor_code=$(cast code "$REWARD_DISTRIBUTOR" --rpc-url "$MAINNET_RPC_URL")
[[ "$splitter_code" != "0x" && "$distributor_code" != "0x" ]] || fail "Pinned contract address has no code"

configured_splitter=$(cast call "$REWARD_DISTRIBUTOR" 'SPLITTER()(address)' --rpc-url "$MAINNET_RPC_URL")
configured_pyth_adapter=$(cast call "$REWARD_DISTRIBUTOR" 'PYTH_ADAPTER()(address)' --rpc-url "$MAINNET_RPC_URL")
configured_usdc=$(cast call "$REWARD_DISTRIBUTOR" 'USDC()(address)' --rpc-url "$MAINNET_RPC_URL")
configured_price_id=$(cast call "$PYTH_ADAPTER" 'PRICE_ID()(bytes32)' --rpc-url "$MAINNET_RPC_URL")
[[ "$(lower "$configured_splitter")" == "$(lower "$SPLITTER")" ]] || fail "Distributor points to a different splitter"
[[ "$(lower "$configured_pyth_adapter")" == "$(lower "$PYTH_ADAPTER")" ]] || fail "Distributor points to a different Pyth adapter"
[[ "$(lower "$configured_usdc")" == "$(lower "$USDC")" ]] || fail "Distributor points to a different USDC token"
[[ "$(lower "$configured_price_id")" == "0x$(lower "$PYTH_PRICE_ID")" ]] || fail "Pyth adapter uses a different price feed"

nonce_latest=$(cast nonce "$OWNER" --block latest --rpc-url "$MAINNET_RPC_URL")
nonce_pending=$(cast nonce "$OWNER" --block pending --rpc-url "$MAINNET_RPC_URL")
[[ "$nonce_latest" == "$nonce_pending" ]] || fail "Owner has a pending nonce ($nonce_latest latest, $nonce_pending pending); clear it before bundling"

now=$(date +%s)
last_distribution=$(cast call "$REWARD_DISTRIBUTOR" 'lastDistributionTime()(uint256)' --rpc-url "$MAINNET_RPC_URL" | awk '{print $1}')
(( now >= last_distribution + 3600 )) || fail "Reward distribution is still inside its one-hour cooldown"

rd_usdc=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$REWARD_DISTRIBUTOR" --rpc-url "$MAINNET_RPC_URL" | awk '{print $1}')
(( rd_usdc > 0 )) || fail "RewardDistributor has no USDC to distribute"

echo "Fetching a fresh USD/SEK update from Pyth Hermes..."
hermes_endpoint="${HERMES_URL%/}/v2/updates/price/latest?ids%5B%5D=0x${PYTH_PRICE_ID}&encoding=hex"
if [[ -n "${PYTH_API_KEY:-}" ]]; then
    hermes_json=$(curl --retry 5 --retry-all-errors --fail-with-body --silent --show-error \
        -H "Authorization: Bearer $PYTH_API_KEY" "$hermes_endpoint")
else
    hermes_json=$(curl --retry 5 --retry-all-errors --fail-with-body --silent --show-error "$hermes_endpoint")
fi

returned_price_id=$(jq -r '.parsed[0].id // empty' <<<"$hermes_json")
publish_time=$(jq -r '.parsed[0].price.publish_time // empty' <<<"$hermes_json")
pyth_update_hex=$(jq -r '.binary.data[0] // empty' <<<"$hermes_json")
[[ "$(lower "$returned_price_id")" == "$(lower "$PYTH_PRICE_ID")" ]] || fail "Hermes returned the wrong price feed"
[[ "$publish_time" =~ ^[0-9]+$ ]] || fail "Hermes response has no publish_time"
[[ "$pyth_update_hex" =~ ^[0-9a-fA-F]+$ ]] || fail "Hermes response has no hex update payload"

now=$(date +%s)
pyth_age=$((now - publish_time))
(( pyth_age >= -15 && pyth_age <= MAX_PYTH_AGE_SECONDS )) \
    || fail "Pyth update age is ${pyth_age}s; allowed range is -15s to ${MAX_PYTH_AGE_SECONDS}s"
PYTH_UPDATE="0x${pyth_update_hex}"
PYTH_FEE=$(cast call "$PYTH_ADAPTER" 'getUpdateFee(bytes[])(uint256)' "[$PYTH_UPDATE]" --rpc-url "$MAINNET_RPC_URL" | awk '{print $1}')

base_fee=$(cast block latest --field baseFeePerGas --rpc-url "$MAINNET_RPC_URL")
MAX_FEE_WEI="${MAX_FEE_WEI:-$((base_fee * 2 + PRIORITY_FEE_WEI))}"
(( MAX_FEE_WEI >= PRIORITY_FEE_WEI )) || fail "MAX_FEE_WEI must be at least PRIORITY_FEE_WEI"

total_gas_limit=$((GAS_UNPAUSE + GAS_HARVEST + GAS_DISTRIBUTE + GAS_EJECT))
owner_eth=$(cast balance "$OWNER" --rpc-url "$MAINNET_RPC_URL")
worst_case_cost=$((total_gas_limit * MAX_FEE_WEI + PYTH_FEE))
(( owner_eth >= worst_case_cost )) || fail "Owner ETH balance is below the bundle's worst-case gas reservation"

common_tx_args=(
    --chain 1
    --gas-price "$MAX_FEE_WEI"
    --priority-gas-price "$PRIORITY_FEE_WEI"
    --private-key "$PRIVATE_KEY"
    --rpc-url "$MAINNET_RPC_URL"
)

TX1=$(cast mktx "$SPLITTER" 'unpause()' \
    --nonce "$nonce_latest" --gas-limit "$GAS_UNPAUSE" "${common_tx_args[@]}")
TX2=$(cast mktx "$SPLITTER" 'harvestYield()' \
    --nonce "$((nonce_latest + 1))" --gas-limit "$GAS_HARVEST" "${common_tx_args[@]}")
TX3=$(cast mktx "$REWARD_DISTRIBUTOR" 'distributeRewardsWithPriceUpdate(bytes[])' "[$PYTH_UPDATE]" \
    --value "$PYTH_FEE" --nonce "$((nonce_latest + 2))" --gas-limit "$GAS_DISTRIBUTE" "${common_tx_args[@]}")
TX4=$(cast mktx "$SPLITTER" 'ejectLiquidity()' \
    --nonce "$((nonce_latest + 3))" --gas-limit "$GAS_EJECT" "${common_tx_args[@]}")

TXS_JSON=$(jq -cn --arg tx1 "$TX1" --arg tx2 "$TX2" --arg tx3 "$TX3" --arg tx4 "$TX4" '[$tx1,$tx2,$tx3,$tx4]')
TX1_HASH=$(cast keccak "$TX1")
TX2_HASH=$(cast keccak "$TX2")
TX3_HASH=$(cast keccak "$TX3")
TX4_HASH=$(cast keccak "$TX4")

echo "Prepared recovery bundle:"
echo "  signer:        $signer"
echo "  nonce range:   $nonce_latest-$((nonce_latest + 3))"
echo "  distributor:   $rd_usdc USDC base units"
echo "  Pyth age/fee:  ${pyth_age}s / $PYTH_FEE wei"
echo "  max/priority:  $MAX_FEE_WEI / $PRIORITY_FEE_WEI wei"

if [[ "$MODE" == "prepare" ]]; then
    echo "PREPARE ONLY: transactions were signed locally but not shared or submitted."
    exit 0
fi

latest_block=$(cast block-number --rpc-url "$MAINNET_RPC_URL")
simulate_bundle "$((latest_block + 1))"

if [[ "$MODE" == "simulate" ]]; then
    echo "SIMULATION ONLY: the bundle was not submitted for inclusion."
    echo "The signed transactions were shared only with the configured relay's simulation endpoint."
    echo "Run with BROADCAST_RECOVERY_BUNDLE=YES and the send argument to submit."
    exit 0
fi

for ((attempt = 1; attempt <= BUNDLE_ATTEMPTS; attempt++)); do
    if verify_inclusion; then
        exit 0
    fi

    current_nonce=$(cast nonce "$OWNER" --block latest --rpc-url "$MAINNET_RPC_URL")
    [[ "$current_nonce" == "$nonce_latest" ]] || fail "Owner nonce changed before inclusion; refusing to continue"

    latest_block=$(cast block-number --rpc-url "$MAINNET_RPC_URL")
    target_block=$((latest_block + 1))
    target_block_hex=$(cast to-hex "$target_block")

    simulate_bundle "$target_block"
    send_body=$(make_send_body "$target_block_hex")
    send_response=$(relay_request "$send_body")
    if [[ "$(jq -r '.error // empty' <<<"$send_response")" != "" ]]; then
        jq . <<<"$send_response" >&2
        fail "Flashbots rejected bundle submission"
    fi

    bundle_hash=$(jq -r '.result.bundleHash // empty' <<<"$send_response")
    [[ -n "$bundle_hash" ]] || {
        jq . <<<"$send_response" >&2
        fail "Flashbots did not return a bundle hash"
    }
    echo "Submitted attempt $attempt/$BUNDLE_ATTEMPTS for block $target_block: $bundle_hash"

    while (( $(cast block-number --rpc-url "$MAINNET_RPC_URL") < target_block )); do
        sleep 2
    done
done

if verify_inclusion; then
    exit 0
fi

fail "Bundle was not included after $BUNDLE_ATTEMPTS attempts; no protocol state changed"
