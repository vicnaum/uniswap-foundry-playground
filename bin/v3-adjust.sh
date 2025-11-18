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

RPC_URL="${V3_RPC_URL:-${ARBITRUM_RPC_URL:-}}"
if [ -z "$RPC_URL" ]; then
  echo "Set V3_RPC_URL or ARBITRUM_RPC_URL in the environment." >&2
  exit 1
fi

: "${V3_SWAP_ROUTER:?V3_SWAP_ROUTER is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

POOL_ADDRESS="${1:-}"
if [ -n "$POOL_ADDRESS" ]; then
  shift
elif [ -n "${V3_POOL_ADDRESS:-}" ]; then
  POOL_ADDRESS="$V3_POOL_ADDRESS"
else
  echo "Usage: $(basename "$0") <poolAddress> [forge options...]" >&2
  echo "Pass the pool address as the first argument or define V3_POOL_ADDRESS." >&2
  exit 1
fi

TARGET_TICK_INPUT="${TARGET_TICK:-}"
if [ -z "$TARGET_TICK_INPUT" ] && [ -t 0 ]; then
  read -r -p "Target tick (int24): " TARGET_TICK_INPUT </dev/tty || true
fi

if [ -z "$TARGET_TICK_INPUT" ]; then
  echo "Target tick is required (set TARGET_TICK for non-interactive runs)." >&2
  exit 1
fi

SIM_CMD=(
  forge script script/v3/V3AdjustPoolPrice.s.sol:V3AdjustPoolPriceScript
  --fork-url "$RPC_URL"
  "$@"
  --
  "$POOL_ADDRESS"
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
  DRY_RUN=0 forge script script/v3/V3AdjustPoolPrice.s.sol:V3AdjustPoolPriceScript --rpc-url "$RPC_URL" --broadcast "$@" -- "$POOL_ADDRESS" "$TARGET_TICK_INPUT"
else
  echo "Broadcast skipped."
fi

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
cd "$PROJECT_ROOT"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${ARBITRUM_RPC_URL:?ARBITRUM_RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${V3_ROUTER_ADDRESS:?V3_ROUTER_ADDRESS is required}"

POOL_ADDRESS_ARG="${1:-}"
if [ -n "$POOL_ADDRESS_ARG" ]; then
  shift
else
  if [ -n "${V3_POOL_ADDRESS:-}" ]; then
    POOL_ADDRESS_ARG="$V3_POOL_ADDRESS"
  else
    echo "Usage: $(basename "$0") <poolAddress> [forge options...]" >&2
    echo "Provide the pool address as the first argument or set V3_POOL_ADDRESS in the environment." >&2
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
  echo "Target tick is required (set TARGET_TICK env var when running non-interactively)." >&2
  exit 1
fi

SIM_CMD=(
  forge script script/v3/V3AdjustPoolPrice.s.sol
  --fork-url "$ARBITRUM_RPC_URL"
  "$@"
  --
  "$POOL_ADDRESS_ARG"
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
  DRY_RUN=0 forge script script/v3/V3AdjustPoolPrice.s.sol --rpc-url "$ARBITRUM_RPC_URL" --broadcast "$@" -- "$POOL_ADDRESS_ARG" "$TARGET_TICK_INPUT"
else
  echo "Broadcast skipped."
fi


