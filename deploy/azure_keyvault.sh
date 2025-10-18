#!/usr/bin/env sh

# Deploy ACME artifacts to Azure Key Vault using either PEM secrets or a PFX import.
#
# Required environment variables (client credentials flow):
#
# AZURE_TENANT_ID            Azure AD tenant ID used for token acquisition
# AZURE_CLIENT_ID            Application (client) ID used for token acquisition
# AZURE_CLIENT_SECRET        Client secret for the application (client credentials flow)
# AZURE_KEYVAULT_NAME        Name of the target Key Vault (without FQDN)
#
# Optional environment variables:
#
# AZURE_KEYVAULT_CERT_NAME   Target certificate name (defaults to the sanitized domain)
# AZURE_KEYVAULT_FORMAT      "pem" (default) or "pfx"
# AZURE_KEYVAULT_PFX_FILE    Pre-built PFX bundle to upload when AZURE_KEYVAULT_FORMAT=pfx
# AZURE_KEYVAULT_PFX_PASSWORD Password used to protect the PFX bundle (defaults to empty)
# AZURE_MANAGED_IDENTITY     Set to "system" or "user" to use a managed identity instead of client credentials
# AZURE_MANAGED_IDENTITY_CLIENT_ID Client ID of a user-assigned managed identity (when AZURE_MANAGED_IDENTITY=user)
# AZURE_MANAGED_IDENTITY_RESOURCE_ID Resource ID of a user-assigned managed identity (alternative to client ID)
#                              When AZURE_MANAGED_IDENTITY is used the tenant/client/secret values are not required
# Returns 0 on success, 1 otherwise.

######## Public functions #####################

#domain keyfile certfile cafile fullchain
azure_keyvault_deploy() {

  _cdomain="$1"
  _ckey_file="$2"
  _ccert_file="$3"
  _cca_file="$4"
  _cfullchain_file="$5"

  _debug _cdomain "$_cdomain"
  _debug _ckey "$_ckey_file"
  _debug _ccert "$_ccert_file"
  _debug _cca "$_cca_file"
  _debug _cfullchain "$_cfullchain_file"
  _debug DOMAIN_CONF "$DOMAIN_CONF"

  __AKV_MI_MODE=""

  _getdeployconf AZURE_KEYVAULT_NAME
  if [ -z "$AZURE_KEYVAULT_NAME" ]; then
    _err "AZURE_KEYVAULT_NAME needs to be defined"
    return 1
  fi
  _savedeployconf AZURE_KEYVAULT_NAME "$AZURE_KEYVAULT_NAME"

  _getdeployconf AZURE_MANAGED_IDENTITY
  _getdeployconf AZURE_MANAGED_IDENTITY_CLIENT_ID
  _getdeployconf AZURE_MANAGED_IDENTITY_RESOURCE_ID

  _mi_value=$(printf "%s" "$AZURE_MANAGED_IDENTITY" | tr '[:upper:]' '[:lower:]')
  case "$_mi_value" in
  ""|false|no|0|off)
    AZURE_MANAGED_IDENTITY=""
    ;;
  user|user-assigned)
    __AKV_MI_MODE="user"
    AZURE_MANAGED_IDENTITY="user"
    ;;
  system|system-assigned)
    __AKV_MI_MODE="system"
    AZURE_MANAGED_IDENTITY="system"
    ;;
  *)
    if [ -n "$_mi_value" ]; then
      _err "AZURE_MANAGED_IDENTITY must be either 'system' or 'user'"
      return 1
    fi
    ;;
  esac

  _getdeployconf AZURE_TENANT_ID
  _getdeployconf AZURE_CLIENT_ID
  _getdeployconf AZURE_CLIENT_SECRET

  if [ "$__AKV_MI_MODE" = "user" ]; then
    if [ -z "$AZURE_MANAGED_IDENTITY_CLIENT_ID" ] && [ -z "$AZURE_MANAGED_IDENTITY_RESOURCE_ID" ]; then
      _err "AZURE_MANAGED_IDENTITY=user requires AZURE_MANAGED_IDENTITY_CLIENT_ID or AZURE_MANAGED_IDENTITY_RESOURCE_ID"
      return 1
    fi
  fi

  if [ -z "$__AKV_MI_MODE" ]; then
    if [ -z "$AZURE_TENANT_ID" ]; then
      _err "AZURE_TENANT_ID needs to be defined"
      return 1
    fi
    _savedeployconf AZURE_TENANT_ID "$AZURE_TENANT_ID"

    if [ -z "$AZURE_CLIENT_ID" ]; then
      _err "AZURE_CLIENT_ID needs to be defined"
      return 1
    fi
    _savedeployconf AZURE_CLIENT_ID "$AZURE_CLIENT_ID"

    if [ -z "$AZURE_CLIENT_SECRET" ]; then
      _err "AZURE_CLIENT_SECRET needs to be defined"
      return 1
    fi
    _savedeployconf AZURE_CLIENT_SECRET "$AZURE_CLIENT_SECRET"
  else
    _info "Using Azure managed identity ($__AKV_MI_MODE)"
    _debug AZURE_MANAGED_IDENTITY "$AZURE_MANAGED_IDENTITY"
    _debug AZURE_MANAGED_IDENTITY_CLIENT_ID "$AZURE_MANAGED_IDENTITY_CLIENT_ID"
    _debug AZURE_MANAGED_IDENTITY_RESOURCE_ID "$AZURE_MANAGED_IDENTITY_RESOURCE_ID"
    if [ -n "$AZURE_CLIENT_SECRET" ]; then
      _debug "discarding_client_secret" "managed identity in use"
    fi
    AZURE_CLIENT_SECRET=""
    _savedeployconf AZURE_CLIENT_SECRET ""
  fi

  _savedeployconf AZURE_MANAGED_IDENTITY "$AZURE_MANAGED_IDENTITY"
  _savedeployconf AZURE_MANAGED_IDENTITY_CLIENT_ID "$AZURE_MANAGED_IDENTITY_CLIENT_ID"
  _savedeployconf AZURE_MANAGED_IDENTITY_RESOURCE_ID "$AZURE_MANAGED_IDENTITY_RESOURCE_ID"

  _getdeployconf AZURE_KEYVAULT_CERT_NAME
  if [ -z "$AZURE_KEYVAULT_CERT_NAME" ]; then
    AZURE_KEYVAULT_CERT_NAME=$(_azure_keyvault_normalize_name "$_cdomain")
  else
    AZURE_KEYVAULT_CERT_NAME=$(_azure_keyvault_normalize_name "$AZURE_KEYVAULT_CERT_NAME")
  fi
  _savedeployconf AZURE_KEYVAULT_CERT_NAME "$AZURE_KEYVAULT_CERT_NAME"

  _getdeployconf AZURE_KEYVAULT_FORMAT
  if [ -z "$AZURE_KEYVAULT_FORMAT" ]; then
    AZURE_KEYVAULT_FORMAT="pem"
  fi
  AZURE_KEYVAULT_FORMAT=$(printf "%s" "$AZURE_KEYVAULT_FORMAT" | tr '[:upper:]' '[:lower:]')
  case "$AZURE_KEYVAULT_FORMAT" in
  pem | pfx) ;;
  *)
    _err "AZURE_KEYVAULT_FORMAT must be either 'pem' or 'pfx'"
    return 1
    ;;
  esac
  _savedeployconf AZURE_KEYVAULT_FORMAT "$AZURE_KEYVAULT_FORMAT"

  _getdeployconf AZURE_KEYVAULT_KEY_TYPE
  _savedeployconf AZURE_KEYVAULT_KEY_TYPE "$AZURE_KEYVAULT_KEY_TYPE"

  _getdeployconf AZURE_KEYVAULT_KEY_CURVE
  _savedeployconf AZURE_KEYVAULT_KEY_CURVE "$AZURE_KEYVAULT_KEY_CURVE"

  KV_BASE_URL="https://${AZURE_KEYVAULT_NAME}.vault.azure.net"

  AZURE_ACCESS_TOKEN=$(_azure_keyvault_obtain_token) || return 1

  export _H1="Authorization: Bearer $AZURE_ACCESS_TOKEN"

  if [ "$AZURE_KEYVAULT_FORMAT" = "pem" ]; then
    if ! _azure_keyvault_import_pem_certificate "$_ckey_file" "$_ccert_file" "$_cca_file" "$_cfullchain_file"; then
      return 1
    fi
  else
    _getdeployconf AZURE_KEYVAULT_PFX_FILE
    _savedeployconf AZURE_KEYVAULT_PFX_FILE "$AZURE_KEYVAULT_PFX_FILE"
    _getdeployconf AZURE_KEYVAULT_PFX_PASSWORD

    _pfx_key_type="$AZURE_KEYVAULT_KEY_TYPE"
    _pfx_key_curve="$AZURE_KEYVAULT_KEY_CURVE"
    _detected_bits=""
    _detected_type=""
    _detected_curve=""
    if command -v openssl >/dev/null 2>&1; then
      _detected_bits=$(_azure_keyvault_detect_key_size "$_ccert_file")
      if [ -n "$_detected_bits" ]; then
        _debug "pfx_detected_key_bits" "$_detected_bits"
      fi
      _algo_line=$(openssl x509 -in "$_ccert_file" -noout -text 2>/dev/null | grep -m1 'Public Key Algorithm:')
      case "$_algo_line" in
      *RSA*) _detected_type="RSA" ;;
      *EC* | *id-ecPublicKey*) _detected_type="EC" ;;
      esac
    fi
    if [ -n "$_detected_type" ]; then
      _debug "pfx_detected_key_type" "$_detected_type"
    fi
    _pfx_key_bits="$_detected_bits"
    if [ -z "$_pfx_key_type" ] && [ -n "$_detected_type" ]; then
      _pfx_key_type="$_detected_type"
    fi
    case "$_pfx_key_type" in
    EC | EC-HSM)
      if [ -z "$_pfx_key_curve" ]; then
        if [ -z "$_detected_curve" ] && command -v openssl >/dev/null 2>&1; then
          _detected_curve=$(_azure_keyvault_detect_curve "$_ccert_file")
        fi
        if [ -n "$_detected_curve" ]; then
          _pfx_key_curve="$_detected_curve"
        fi
      fi
      ;;
    esac
    if [ -n "$_detected_curve" ]; then
      _debug "pfx_detected_key_curve" "$_detected_curve"
    fi

    if [ -n "$AZURE_KEYVAULT_PFX_FILE" ]; then
      if [ ! -f "$AZURE_KEYVAULT_PFX_FILE" ]; then
        _err "Provided AZURE_KEYVAULT_PFX_FILE '$AZURE_KEYVAULT_PFX_FILE' does not exist"
        return 1
      fi
      _pfx_path="$AZURE_KEYVAULT_PFX_FILE"
    else
      if ! command -v openssl >/dev/null 2>&1; then
        _err "openssl is required to generate a PFX bundle"
        return 1
      fi
      _pfx_path=$(mktemp /tmp/akv_certXXXXXX.pfx)
      _info "Building temporary PFX bundle for Azure Key Vault"
      _chain_file="$_ccert_file"
      if [ -s "$_cfullchain_file" ]; then
        _chain_file="$_cfullchain_file"
      fi
      if [ -s "$_cca_file" ]; then
        set -- -certfile "$_cca_file"
      else
        set --
      fi
      if ! openssl pkcs12 -export -out "$_pfx_path" -inkey "$_ckey_file" -in "$_chain_file" "$@" -passout "pass:${AZURE_KEYVAULT_PFX_PASSWORD:-}" >/dev/null 2>&1; then
        _err "openssl pkcs12 export failed"
        rm -f "$_pfx_path"
        set --
        return 1
      fi
      set --
    fi

    _pfx_payload=$(cat "$_pfx_path" | base64 | tr -d '\n')
    if [ -z "$AZURE_KEYVAULT_PFX_FILE" ]; then
      rm -f "$_pfx_path"
    fi

    if ! _azure_keyvault_import_certificate "pfx" "$_pfx_payload" "${AZURE_KEYVAULT_PFX_PASSWORD:-}" "$_pfx_key_type" "$_pfx_key_bits" "$_pfx_key_curve"; then
      return 1
    fi
  fi

  return 0
}

######## Helper functions #####################

_azure_keyvault_normalize_name() {
  _akn_input="$1"
  _akn_norm=$(printf "%s" "$_akn_input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
  _akn_norm=$(printf "%s" "$_akn_norm" | sed 's/^-*//; s/-*$//; s/--*/-/g')
  if [ -z "$_akn_norm" ]; then
    _akn_norm="cert"
  fi
  _akn_first=$(printf "%s" "$_akn_norm" | cut -c1)
  case "$_akn_first" in
  [a-z]) ;;
  *) _akn_norm="cert-$_akn_norm" ;;
  esac
  printf "%s" "$_akn_norm"
}

_azure_keyvault_obtain_msi_token() {
  _resource="https://vault.azure.net"
  _encoded_resource=$(printf "%s" "$_resource" | _url_encode)
  _url=""

  export _H1=""
  export _H2=""

  if [ -n "$IDENTITY_ENDPOINT" ]; then
    if [ -z "$IDENTITY_HEADER" ]; then
      _err "IDENTITY_ENDPOINT is set but IDENTITY_HEADER is missing"
      return 1
    fi
    _url="${IDENTITY_ENDPOINT}?api-version=2019-08-01&resource=${_encoded_resource}"
    if [ "$__AKV_MI_MODE" = "user" ]; then
      if [ -n "$AZURE_MANAGED_IDENTITY_CLIENT_ID" ]; then
        _url="${_url}&client_id=$(printf "%s" "$AZURE_MANAGED_IDENTITY_CLIENT_ID" | _url_encode)"
      elif [ -n "$AZURE_MANAGED_IDENTITY_RESOURCE_ID" ]; then
        _url="${_url}&mi_res_id=$(printf "%s" "$AZURE_MANAGED_IDENTITY_RESOURCE_ID" | _url_encode)"
      fi
    fi
    export _H1="X-IDENTITY-HEADER: $IDENTITY_HEADER"
    export _H2="Metadata: true"
    _debug "managed_identity_endpoint" "IDENTITY_ENDPOINT"
  elif [ -n "$MSI_ENDPOINT" ]; then
    if [ -z "$MSI_SECRET" ]; then
      _err "MSI_ENDPOINT is set but MSI_SECRET is missing"
      return 1
    fi
    _url="${MSI_ENDPOINT}?resource=${_encoded_resource}&api-version=2017-09-01"
    if [ "$__AKV_MI_MODE" = "user" ]; then
      if [ -n "$AZURE_MANAGED_IDENTITY_CLIENT_ID" ]; then
        _url="${_url}&clientid=$(printf "%s" "$AZURE_MANAGED_IDENTITY_CLIENT_ID" | _url_encode)"
      elif [ -n "$AZURE_MANAGED_IDENTITY_RESOURCE_ID" ]; then 
        _url="${_url}&mi_res_id=$(printf "%s" "$AZURE_MANAGED_IDENTITY_RESOURCE_ID" | _url_encode)"
      fi
    fi
    export _H1="secret: $MSI_SECRET"
    export _H2="Metadata: true"
    _debug "managed_identity_endpoint" "MSI_ENDPOINT"
  else
    _url="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${_encoded_resource}"
    if [ "$__AKV_MI_MODE" = "user" ]; then
      if [ -n "$AZURE_MANAGED_IDENTITY_CLIENT_ID" ]; then
        _url="${_url}&client_id=$(printf "%s" "$AZURE_MANAGED_IDENTITY_CLIENT_ID" | _url_encode)"
      elif [ -n "$AZURE_MANAGED_IDENTITY_RESOURCE_ID" ]; then
        _url="${_url}&mi_res_id=$(printf "%s" "$AZURE_MANAGED_IDENTITY_RESOURCE_ID" | _url_encode)"
      fi
    fi
    export _H1="Metadata: true"
    _debug "managed_identity_endpoint" "IMDS"
  fi

  _debug "managed_identity_request_url" "$_url"

  _response=$(_get "$_url")
  _ret="$?"
  export _H1=""
  export _H2=""
  if [ "$_ret" != "0" ]; then
    _err "Failed to request managed identity token"
    return 1
  fi

  _azure_access_token=$(printf "%s" "$_response" | sed -n 's/.*"access_token":"\([^"\\]*\)".*/\1/p')
  if [ -z "$_azure_access_token" ]; then
    _err "Managed identity response did not contain an access_token"
    _debug2 "managed_identity_response" "$_response"
    return 1
  fi

  printf "%s" "$_azure_access_token"
  return 0
}

_azure_keyvault_obtain_token() {
  if [ -n "$__AKV_MI_MODE" ]; then
    _azure_msi_token=$(_azure_keyvault_obtain_msi_token)
    if [ "$?" != "0" ] || [ -z "$_azure_msi_token" ]; then
      return 1
    fi
    printf "%s" "$_azure_msi_token"
    return 0
  fi

  _token_url="https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token"
  _encoded_client_id=$(printf "%s" "$AZURE_CLIENT_ID" | _url_encode)
  _encoded_client_secret=$(printf "%s" "$AZURE_CLIENT_SECRET" | _url_encode)
  _token_body="client_id=${_encoded_client_id}&scope=https%3A%2F%2Fvault.azure.net%2F.default&grant_type=client_credentials"
  _token_body="${_token_body}&client_secret=${_encoded_client_secret}"

  export _H1=""

  _token_response=$(_post "$_token_body" "$_token_url" "" "POST" "application/x-www-form-urlencoded")
  if [ "$?" != "0" ]; then
    _err "Failed to request Azure AD token"
    return 1
  fi

  _azure_access_token=$(printf "%s" "$_token_response" | sed -n 's/.*"access_token":"\([^"\\]*\)".*/\1/p')
  if [ -z "$_azure_access_token" ]; then
    _err "Azure AD token response did not contain an access_token"
    _debug2 "token_response" "$_token_response"
    return 1
  fi

  printf "%s" "$_azure_access_token"
  return 0
}

_azure_keyvault_api_call() {
  _body="$1"
  _url="$2"
  _method="$3"
  _content_type="$4"
  _attempt="$5"

  if [ -z "$_method" ]; then
    _method="POST"
  fi
  if [ -z "$_content_type" ]; then
    _content_type="application/json"
  fi

  _response=$(_post "$_body" "$_url" "" "$_method" "$_content_type")
  _ret="$?"
  if [ "$_ret" != "0" ]; then
    printf "%s" "$_response"
    return $_ret
  fi

  if echo "$_response" | grep -q 'TokenExpired\|"code":"Unauthorized"'; then
    if [ "$_attempt" != "retry" ]; then
      _info "Azure token expired, requesting a new token"
      AZURE_ACCESS_TOKEN=$(_azure_keyvault_obtain_token) || return 1
      export _H1="Authorization: Bearer $AZURE_ACCESS_TOKEN"
      _response=$(_azure_keyvault_api_call "$_body" "$_url" "$_method" "$_content_type" "retry")
      _ret="$?"
      printf "%s" "$_response"
      return $_ret
    fi
  fi

  printf "%s" "$_response"
  return 0
}

_azure_keyvault_build_policy() {
  _content_type="$1"
  _key_type="$2"
  _key_bits="$3"
  _key_curve="$4"

  _policy_secret="{\"contentType\":\"$_content_type\"}"
  _policy_json="{\"secret_props\":${_policy_secret}}"

  case "$_key_type" in
  RSA | RSA-HSM)
    _exportable="true"
    case "$_key_type" in
    *-HSM) _exportable="false" ;;
    esac
    _policy_key="{\"exportable\":${_exportable},\"kty\":\"$_key_type\",\"reuse_key\":false"
    if [ -n "$_key_bits" ]; then
      _policy_key="${_policy_key},\"key_size\":$_key_bits"
    fi
    _policy_key="${_policy_key}}"
    _policy_json="{\"secret_props\":${_policy_secret},\"key_props\":${_policy_key}}"
    ;;
  EC | EC-HSM)
    if [ -n "$_key_curve" ]; then
      _exportable="true"
      case "$_key_type" in
      *-HSM) _exportable="false" ;;
      esac
      _policy_key="{\"exportable\":${_exportable},\"kty\":\"$_key_type\",\"reuse_key\":false,\"crv\":\"$_key_curve\"}"
      _policy_json="{\"secret_props\":${_policy_secret},\"key_props\":${_policy_key}}"
    fi
    ;;
  oct | oct-HSM)
    _exportable="true"
    case "$_key_type" in
    *-HSM) _exportable="false" ;;
    esac
    _policy_key="{\"exportable\":${_exportable},\"kty\":\"$_key_type\",\"reuse_key\":false}"
    _policy_json="{\"secret_props\":${_policy_secret},\"key_props\":${_policy_key}}"
    ;;
  esac

  printf "%s" "$_policy_json"
}

_azure_keyvault_import_certificate() {
  _format="$1"
  _payload="$2"
  _password="$3"
  _key_type="$4"
  _key_bits="$5"
  _key_curve="$6"

  case "$_format" in
  pem) _content_type="application/x-pem-file" ;;
  pfx) _content_type="application/x-pkcs12" ;;
  *)
    _err "Unsupported certificate format '$_format'"
    return 1
    ;;
  esac

  _policy_json=$(_azure_keyvault_build_policy "$_content_type" "$_key_type" "$_key_bits" "$_key_curve") || return 1

  case "$_format" in
  pem)
    _info "Importing PEM certificate ${AZURE_KEYVAULT_CERT_NAME} into Key Vault ${AZURE_KEYVAULT_NAME}"
    _body="{\"value\":\"${_payload}\",\"policy\":${_policy_json},\"attributes\":{\"enabled\":true}}"
    ;;
  pfx)
    _info "Importing PFX certificate ${AZURE_KEYVAULT_CERT_NAME} into Key Vault ${AZURE_KEYVAULT_NAME}"
    _body="{\"value\":\"${_payload}\",\"pwd\":\"${_password}\",\"policy\":${_policy_json},\"attributes\":{\"enabled\":true}}"
    ;;
  esac

  _import_url="${KV_BASE_URL}/certificates/${AZURE_KEYVAULT_CERT_NAME}/import?api-version=2025-07-01"
  _response=$(_azure_keyvault_api_call "$_body" "$_import_url" "POST" "application/json")
  if [ "$?" != "0" ]; then
    _err "Certificate import request failed"
    return 1
  fi
  if _contains "$_response" '"error"'; then
    _err "Azure Key Vault certificate import failed: $_response"
    return 1
  fi
  return 0
}

_azure_keyvault_detect_key_size() {
  _cert_file="$1"
  if ! command -v openssl >/dev/null 2>&1; then
    return 1
  fi
  _key_line=$(openssl x509 -in "$_cert_file" -noout -text 2>/dev/null | grep -m1 'Public-Key:')
  if [ -z "$_key_line" ]; then
    return 1
  fi
  _key_bits=$(printf "%s" "$_key_line" | sed -n 's/.*(\([0-9][0-9]*\) bit).*/\1/p')
  if [ -n "$_key_bits" ]; then
    printf "%s" "$_key_bits"
  fi
}

_azure_keyvault_detect_curve() {
  _cert_file="$1"
  if ! command -v openssl >/dev/null 2>&1; then
    return 1
  fi
  _curve_line=$(openssl x509 -in "$_cert_file" -noout -text 2>/dev/null | grep -m1 'ASN1 OID:')
  if [ -z "$_curve_line" ]; then
    _curve_line=$(openssl x509 -in "$_cert_file" -noout -text 2>/dev/null | grep -m1 'NIST CURVE:')
  fi
  if [ -z "$_curve_line" ]; then
    return 1
  fi
  _curve_value=$(printf "%s" "$_curve_line" | awk -F': ' 'NF>1 {print $2}' | tr -d '\r')
  case "$_curve_value" in
  prime256v1 | secp256r1 | P-256 | p-256)
    printf "%s" "P-256"
    return 0
    ;;
  secp384r1 | P-384 | p-384)
    printf "%s" "P-384"
    return 0
    ;;
  secp521r1 | P-521 | p-521)
    printf "%s" "P-521"
    return 0
    ;;
  secp256k1 | P-256K | p-256k)
    printf "%s" "P-256K"
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

_azure_keyvault_import_pem_certificate() {
  _key_file="$1"
  _cert_file="$2"
  _ca_file="$3"
  _fullchain_file="$4"

  _pkcs8_tmp=""
  _key_source="$_key_file"
  if ! grep -q "BEGIN PRIVATE KEY" "$_key_file"; then
    if ! command -v openssl >/dev/null 2>&1; then
      _err "openssl is required to convert private key to PKCS#8"
      return 1
    fi
    _info "Converting private key to PKCS#8 for Azure Key Vault import"
    _pkcs8_tmp=$(mktemp /tmp/akv_cert_keyXXXXXX.pem)
    if ! openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in "$_key_file" -out "$_pkcs8_tmp" >/dev/null 2>&1; then
      _err "Failed to convert private key to PKCS#8"
      rm -f "$_pkcs8_tmp"
      return 1
    fi
    _key_source="$_pkcs8_tmp"
  fi

  _bundle_tmp=$(mktemp /tmp/akv_pem_bundleXXXXXX.pem)
  if [ -s "$_fullchain_file" ]; then
    cat "$_fullchain_file" >"$_bundle_tmp"
  else
    cat "$_cert_file" >"$_bundle_tmp"
    if [ -s "$_ca_file" ]; then
      printf "\n" >>"$_bundle_tmp"
      cat "$_ca_file" >>"$_bundle_tmp"
    fi
  fi
  printf "\n" >>"$_bundle_tmp"
  cat "$_key_source" >>"$_bundle_tmp"

  _pem_payload=$(cat "$_bundle_tmp" | base64 | tr -d '\n')
  _key_bits=""
  _detected_bits=$(_azure_keyvault_detect_key_size "$_cert_file")
  if [ -n "$_detected_bits" ]; then
    _debug "pem_detected_key_bits" "$_detected_bits"
    _key_bits="$_detected_bits"
  fi
  _key_type="$AZURE_KEYVAULT_KEY_TYPE"
  _key_curve="$AZURE_KEYVAULT_KEY_CURVE"
  _detected_type=""
  _detected_curve=""
  if command -v openssl >/dev/null 2>&1; then
    _algo_line=$(openssl x509 -in "$_cert_file" -noout -text 2>/dev/null | grep -m1 'Public Key Algorithm:')
    case "$_algo_line" in
    *RSA*) _detected_type="RSA" ;;
    *EC* | *id-ecPublicKey*) _detected_type="EC" ;;
    esac
  fi
  if [ -n "$_detected_type" ]; then
    _debug "pem_detected_key_type" "$_detected_type"
  fi
  if [ -z "$_key_type" ] && [ -n "$_detected_type" ]; then
    _key_type="$_detected_type"
  fi
  case "$_key_type" in
  EC | EC-HSM)
    if [ -z "$_key_curve" ]; then
      if [ -z "$_detected_curve" ] && command -v openssl >/dev/null 2>&1; then
        _detected_curve=$(_azure_keyvault_detect_curve "$_cert_file")
      fi
      if [ -n "$_detected_curve" ]; then
        _key_curve="$_detected_curve"
      fi
    fi
    ;;
  esac
  if [ -n "$_detected_curve" ]; then
    _debug "pem_detected_key_curve" "$_detected_curve"
  fi

  rm -f "$_bundle_tmp"
  [ -n "$_pkcs8_tmp" ] && rm -f "$_pkcs8_tmp"

  if ! _azure_keyvault_import_certificate "pem" "$_pem_payload" "" "$_key_type" "$_key_bits" "$_key_curve"; then
    return 1
  fi
  return 0
}
