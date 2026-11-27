#!/bin/sh
# A Vault Agent in miniature, one sidecar per consumer.
#
# Logs in with the service's own AppRole (never the root token), reads the one
# secret that service's policy allows, and renders it to the creds volume the
# service mounts. Runs once per `docker compose up`.
set -eu

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${SERVICE:?SERVICE must be set}"

APPROLE_DIR="${APPROLE_DIR:-/approle}"
CREDS_FILE="${CREDS_FILE:-/credentials/s3.env}"
SECRET_PATH="${SECRET_PATH:-secret/lakehouse/minio}"

echo "$SERVICE-creds: waiting for $VAULT_ADDR"
i=0
until vault status >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "$SERVICE-creds: Vault did not become ready" >&2
    exit 1
  fi
  sleep 2
done

ROLE_ID=$(cat "$APPROLE_DIR/role_id")
SECRET_ID=$(cat "$APPROLE_DIR/secret_id")

VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID")
export VAULT_TOKEN
echo "$SERVICE-creds: logged in as app role '$SERVICE' (policies $(vault read -field=policies auth/token/lookup-self))"

mkdir -p "$(dirname "$CREDS_FILE")"
tmp="$CREDS_FILE.tmp"
{
  printf 'S3_ACCESS_KEY=%s\n' "$(vault kv get -field=root_user "$SECRET_PATH")"
  printf 'S3_SECRET_KEY=%s\n' "$(vault kv get -field=root_password "$SECRET_PATH")"
} > "$tmp"
chmod 0444 "$tmp"
mv "$tmp" "$CREDS_FILE"

echo "$SERVICE-creds: rendered $CREDS_FILE from $SECRET_PATH"
