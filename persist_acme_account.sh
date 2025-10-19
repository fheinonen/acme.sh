#!/usr/bin/env sh

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

LE_WORKING_DIR="${LE_WORKING_DIR:-$HOME/.acme.sh}"
config_dir="$LE_WORKING_DIR/config"
if ! az account show --output none; then
    az login --service-principal \
        --username "$AZURE_CLIENT_ID" \
        --password "$AZURE_CLIENT_SECRET" \
        --tenant "$AZURE_TENANT_ID" \
        --output none
fi

if [ -n "${CERT_PATH:-}" ] && [ -n "${Le_Domain:-}" ]; then
    "$LE_WORKING_DIR/acme.sh" \
        --deploy \
        --domain "$Le_Domain" \
        --deploy-hook azure_keyvault
fi

az storage blob upload-batch \
    --account-name "$AZURE_STORAGE_ACCOUNT" \
    --destination "$AZURE_STORAGE_CONTAINER" \
    --source "$config_dir" \
    --overwrite \
    --output none
printf '[%s] \33[1;32m%b\33[0m Persisted config from %s to container %s in account %s\n' \
    "$(date)" "Success" "$config_dir" "$AZURE_STORAGE_CONTAINER" "$AZURE_STORAGE_ACCOUNT"
