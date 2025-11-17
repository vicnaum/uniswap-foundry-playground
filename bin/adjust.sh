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
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

POOL_ID_ARG="${1:-}"
if [ -n "$POOL_ID_ARG" ]; then
  shift
else
  if [ -n "${POOL_ID:-}" ]; then
    POOL_ID_ARG="$POOL_ID"
  else
    echo "Usage: $(basename "$0") <poolId> [forge options...]" >&2
    echo "Pass the poolId as the first argument or define POOL_ID in the environment." >&2
    exit 1
  fi
fi

TARGET_TICK_INPUT="${TARGET_TICK:-}"
if [ -z "$TARGET_TICK_INPUT" ]; then
  if [ -t 0 ]; then
    read -r -p "Target tick (int24): " TARGET_TICK_INPUT </dev/tty || true
  fi
fi

if [ -z "$TARGET_TICK_INPUT" ]; then
  echo "Target tick is required (provide TARGET_TICK env var when running non-interactively)." >&2
  exit 1
fi

SIM_CMD=(
  forge script script/AdjustPoolPrice.s.sol
  --fork-url "$MAINNET_RPC_URL"
  "$@"
  --
  "$POOL_ID_ARG"
  "$TARGET_TICK_INPUT"
)

echo "Simulating swap..."
if ! DRY_RUN=1 "${SIM_CMD[@]}"; then
  echo "Simulation failed. Aborting." >&2
  exit 1
fi

CONFIRM=""
if [ -t 0 ]; then
  read -r -p "Broadcast transaction? [y/N] " CONFIRM </dev/tty || CONFIRM=""
fi
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  DRY_RUN=0 forge script script/AdjustPoolPrice.s.sol --rpc-url "$MAINNET_RPC_URL" --legacy --broadcast "$@" -- "$POOL_ID_ARG" "$TARGET_TICK_INPUT"
else
  echo "Broadcast skipped."
fi
