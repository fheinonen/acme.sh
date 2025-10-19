#!/usr/bin/env sh

set -eu

require_env() {
  var_name="$1"
  eval "value=\${$var_name:-}"
  if [ -z "$value" ]; then
    printf 'Missing required environment variable: %s\n' "$var_name" >&2
    exit 1
  fi
}

require_env AZURE_CLIENT_ID
require_env AZURE_CLIENT_SECRET
require_env AZURE_TENANT_ID
require_env AZURE_STORAGE_ACCOUNT
require_env AZURE_STORAGE_CONTAINER
require_env AZURE_KEYVAULT_NAME
require_env AKV_ACCOUNT_KEY_SECRET

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_DIR="$SCRIPT_DIR/config"

mkdir -p "$CONFIG_DIR"

if ! az account show --output none; then
  az login --service-principal \
    --username "$AZURE_CLIENT_ID" \
    --password "$AZURE_CLIENT_SECRET" \
    --tenant "$AZURE_TENANT_ID" \
    --output none
fi

az storage blob download-batch \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --source "$AZURE_STORAGE_CONTAINER" \
  --destination "$CONFIG_DIR" \
  --overwrite \
  --output none

secret_tmp=$(mktemp)
trap 'rm -f "$secret_tmp"' EXIT

# az keyvault will not overwrite existing files; remove the placeholder path first
rm -f "$secret_tmp"

az keyvault secret download --vault-name "$AZURE_KEYVAULT_NAME" \
  --name "$AKV_ACCOUNT_KEY_SECRET" --file "$secret_tmp"

chmod 600 "$secret_tmp"
mv "$secret_tmp" "$SCRIPT_DIR/account.key"
trap - EXIT

az logout --username "$AZURE_CLIENT_ID" --output none || true
