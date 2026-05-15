#!/usr/bin/env bash
set -euo pipefail

FEED_ID="${PYTH_REAL_FEED_ID:-0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b}"
HERMES_BASE_URL="${HERMES_BASE_URL:-https://hermes.pyth.network/v2/updates/price}"

latest_response="$(curl -fsS "${HERMES_BASE_URL}/latest?ids[]=${FEED_ID}&encoding=hex")"
latest_publish_time="$(jq -r '.parsed[0].price.publish_time' <<< "$latest_response")"

response=""
for offset in $(seq 0 120); do
  candidate="$((latest_publish_time - offset))"
  candidate_response="$(curl -fsS "${HERMES_BASE_URL}/${candidate}?ids[]=${FEED_ID}&encoding=hex")"
  candidate_publish_time="$(jq -r '.parsed[0].price.publish_time' <<< "$candidate_response")"
  candidate_prev_publish_time="$(jq -r '.parsed[0].metadata.prev_publish_time' <<< "$candidate_response")"
  if [ "$candidate_prev_publish_time" -lt "$candidate_publish_time" ]; then
    response="$candidate_response"
    break
  fi
done

if [ -z "$response" ]; then
  echo "No update with prev_publish_time < publish_time found in the last 120 seconds" >&2
  exit 1
fi

data="$(jq -r '.binary.data[]' <<< "$response")"
publish_time="$(jq -r '.parsed[0].price.publish_time' <<< "$response")"
prev_publish_time="$(jq -r '.parsed[0].metadata.prev_publish_time' <<< "$response")"
price="$(jq -r '.parsed[0].price.price' <<< "$response")"
conf="$(jq -r '.parsed[0].price.conf' <<< "$response")"
expo="$(jq -r '.parsed[0].price.expo' <<< "$response")"

encoded="$(cast abi-encode "f(bytes[])" "[$(sed 's/^/0x/' <<< "$data" | paste -sd, -)]")"

cat <<EOF
# EUR/USD real Hermes update fixture
# feed_id=${FEED_ID}
# price=${price}
# conf=${conf}
# expo=${expo}
export PYTH_REAL_UPDATE_DATA='${encoded}'
export PYTH_REAL_UPDATE_PUBLISH_TIME='${publish_time}'
export PYTH_REAL_UPDATE_PREV_PUBLISH_TIME='${prev_publish_time}'
EOF
