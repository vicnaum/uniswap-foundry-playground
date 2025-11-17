#!/usr/bin/env bash
set -euo pipefail

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

POOL_ID_ARG="${1:-}"
if [ -n "$POOL_ID_ARG" ]; then
  shift
else
  if [ -n "${POOL_ID:-}" ]; then
    POOL_ID_ARG="$POOL_ID"
  else
    echo "Usage: $(basename "$0") <poolId> [additional forge args...]" >&2
    echo "Either pass the poolId as the first argument or set POOL_ID in the environment." >&2
    exit 1
  fi
fi

forge script script/ViewPoolState.s.sol --rpc-url "$MAINNET_RPC_URL" "$@" -- "$POOL_ID_ARG"
