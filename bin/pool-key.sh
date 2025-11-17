#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") POOL_ID [--from-block BLOCK] [--to-block BLOCK]

Fetch the Initialize event for a given Uniswap v4 pool id and decode the PoolKey.
Requires MAINNET_RPC_URL and POOL_MANAGER in the environment (loaded automatically from .env if present).

Options:
  --from-block BLOCK   Optional starting block (default: 0)
  --to-block BLOCK     Optional ending block (default: latest)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
cd "$PROJECT_ROOT"

if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
fi

: "${MAINNET_RPC_URL:?MAINNET_RPC_URL is required}"
: "${POOL_MANAGER:?POOL_MANAGER is required}"

POOL_ID="${1:-}"
if [ -z "$POOL_ID" ]; then
  usage
  exit 1
fi
shift

FROM_BLOCK=0
TO_BLOCK=latest

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-block)
      FROM_BLOCK="$2"
      shift 2
      ;;
    --to-block)
      TO_BLOCK="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

EVENT="Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)"

output="$(cast logs \
  --rpc-url "$MAINNET_RPC_URL" \
  --address "$POOL_MANAGER" \
  --from-block "$FROM_BLOCK" \
  --to-block "$TO_BLOCK" \
  --json \
  "$EVENT" \
  "$POOL_ID")"

if [[ "$output" == "[]" ]]; then
  echo "No Initialize logs found for poolId $POOL_ID in [${FROM_BLOCK}, ${TO_BLOCK}]." >&2
  exit 1
fi

blockNumber="$(echo "$output" | jq -r '.[0].blockNumber')"
txHash="$(echo "$output" | jq -r '.[0].transactionHash')"
dataHex="$(echo "$output" | jq -r '.[0].data')"
poolIdTopic="$(echo "$output" | jq -r '.[0].topics[1]')"
currency0="$(echo "$output" | jq -r '.[0].topics[2] | sub("^0x0{24}";"0x")')"
currency1="$(echo "$output" | jq -r '.[0].topics[3] | sub("^0x0{24}";"0x")')"

decoded="$(cast abi-decode \
  'f()(uint24,int24,address,uint160,int24)' \
  "$dataHex")"

mapfile -t decoded_lines <<<"$(echo "$decoded" | sed 's/^f() //')"
fee="${decoded_lines[0]%% *}"
tickSpacing="${decoded_lines[1]%% *}"
hooks="${decoded_lines[2]%% *}"
sqrtPriceX96="${decoded_lines[3]%% *}"
tick="${decoded_lines[4]%% *}"

if [[ "$hooks" == "0x0000000000000000000000000000000000000000" ]]; then
  hooks="(none)"
fi

if [[ "$sqrtPriceX96" == "" ]]; then
  sqrtPriceX96="0"
fi

if [[ "$tick" == "" ]]; then
  tick="0"
fi

if [[ "$blockNumber" =~ ^0x ]]; then
  blockNumberDec=$(printf "%d" "$blockNumber")
else
  blockNumberDec="$blockNumber"
fi

cat <<EOF
Pool Initialize Event:
  poolId        : $poolIdTopic
  currency0     : $currency0
  currency1     : $currency1
  fee           : $fee
  tickSpacing   : $tickSpacing
  hooks         : $hooks
  sqrtPriceX96  : $sqrtPriceX96
  tick          : $tick
  blockNumber   : $blockNumberDec ($blockNumber)
  transaction   : $txHash
EOF
