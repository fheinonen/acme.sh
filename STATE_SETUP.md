# ACME State Bootstrap & Usage Guide

This repository contains helper scripts that let you hydrate the acme.sh working
state from Azure before each run and persist it afterwards. Follow the sequence
below to get started.

## 1. Register the Account Locally

1. Export the Azure-related environment variables in the shell you will use
   for the remaining steps. Using `"$PWD"` keeps the paths relative to your ACME
   workspace.
   ```sh
   export AZURE_CLIENT_ID="<app-id>"
   export AZURE_CLIENT_SECRET="<client-secret>"
   export AZURE_TENANT_ID="<tenant-id>"
   export AZURE_STORAGE_ACCOUNT="<storage-account-name>"
   export AZURE_STORAGE_CONTAINER="<container-name>"
   export AZURE_KEYVAULT_NAME="<key-vault-name>"
   export AKV_ACCOUNT_KEY_SECRET="acme-account-key-<project>"

   export ACCOUNT_JSON_PATH="$PWD/config/config/account.json"
   export ACCOUNT_CONF_PATH="$PWD/config/config/account.conf"
   export DOMAIN_CONF="$PWD/config/config/domain.conf"
   export CA_CONF="$PWD/config/config/ca.conf"
   ```
2. Ensure the acme.sh script is executable.
   ```sh
   chmod +x acme.sh
   ```
3. Register an account and create the initial `account.key` locally. Use the
   appropriate CA server (staging or production) for your environment.
   ```sh
   ./acme.sh --register-account \
     --server letsencrypt_test \
     --accountkey account.key
   ```
   The registration creates or updates `account.key`, `account.json`, `account.conf`,
   and `ca.conf` under your working directory. `account.key`, `account.json`, and
   `ca.conf` represent the ACME account itself and can be reused across multiple
   domains. `account.conf` stores domain-specific settings (webroot, hooks, etc.),
   so keep a separate copy per certificate.

## 2. Upload Persistent State to Azure

### 2.1 Upload `account.key` to Azure Key Vault

1. Sign in to Azure with any identity (regular user, service principal, or
   managed identity) that has permission to set secrets in your target Key
   Vault. The built-in `Key Vault Secrets Officer` role (or any role that grants
   `set` on secrets) is sufficient.
   ```sh
   az login --service-principal \
     --username "$AZURE_CLIENT_ID" \
     --password "$AZURE_CLIENT_SECRET" \
     --tenant "$AZURE_TENANT_ID"
   ```
2. Store the account key as a secret. A regular Azure AD user with `set`
   permission on the Key Vault is sufficient—administrator privileges are not
   required.
   ```sh
   az keyvault secret set \
     --vault-name "$AZURE_KEYVAULT_NAME" \
     --name "acme-account-key-letsencrypt" \
     --file account.key
   ```

### 2.2 Upload Config Files to Azure Storage

Upload the rest of the ACME state files (`account.json`, `account.conf`,
`ca.conf`) to a blob container so they can be restored in future runs. Any
signed-in identity (interactive user, service principal, or managed identity)
works as long as it has read/write permissions on the container (the built-in
`Storage Blob Data Contributor` role is sufficient). Allocate a dedicated
container per certificate to keep domain-specific state isolated.

```sh
az storage blob upload-batch \
  --auth-mode login \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --destination "$AZURE_STORAGE_CONTAINER" \
  --source ./config
```

> **Note:** Keep `account.key` out of the container. It is securely stored in
> Key Vault and retrieved by the hydration script.
> Avoid copy/pasting the PEM into the portal — the editor collapses newlines and
> corrupts the key. Always upload the file directly.

## 3. Issue/Deploy Certificates with the Helper Scripts

### 3.1 Run acme.sh via the Wrapper

The `run_acme_with_state.sh` wrapper hydrates the Azure state before invoking
acme.sh. It passes all original arguments through unchanged.

```sh
chmod +x run_acme_with_state.sh hydrate_acme_account.sh persist_acme_account.sh

./run_acme_with_state.sh --staging --issue \
  -d acme.fheinonen.eu \
  --dns dns_azure \
  --server letsencrypt_test \
  --post-hook "$PWD/persist_acme_account.sh"
```

The execution order is:

1. `run_acme_with_state.sh` runs `hydrate_acme_account.sh`, which restores the
   Key Vault secret and downloads the latest config files from blob storage.
2. The wrapper then execs `acme.sh` with your original parameters.
3. `acme.sh` performs issuance/renewal. When a new certificate is produced, the
   `persist_acme_account.sh` post hook re-invokes `acme.sh --deploy` with the
   bundled `azure_keyvault` hook on your behalf before uploading the refreshed
   config files back to the storage container (excluding `account.key`).

## 4. Subsequent Runs

On the next invocation of `run_acme_with_state.sh`, the hydration step restores
exactly the same account state, so acme.sh will not try to register or renew
unless a renewal is actually due. This keeps issuance idempotent across pipeline
runs while allowing the deploy hook to push the certificates into Azure Key Vault.

**Tip:** If you are running in CI, make sure your pipeline has permissions to
access the Key Vault secret and the storage container using the exported
credentials or a managed identity. At minimum, grant it `Key Vault Secrets
Officer` on the vault and `Storage Blob Data Contributor` on the container.
