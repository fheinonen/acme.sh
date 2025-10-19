#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HYDRATE_SCRIPT="$SCRIPT_DIR/hydrate_acme_account.sh"
ACME_BIN="$SCRIPT_DIR/acme.sh"

if [ ! -x "$ACME_BIN" ]; then
  printf 'acme.sh not found or not executable at %s\n' "$ACME_BIN" >&2
  exit 1
fi

if [ ! -x "$HYDRATE_SCRIPT" ]; then
  printf 'hydrate script not found or not executable at %s\n' "$HYDRATE_SCRIPT" >&2
  exit 1
fi

if ! "$HYDRATE_SCRIPT"; then
  printf 'Hydration of account state failed\n' >&2
  exit 1
fi

exec "$ACME_BIN" "$@"
