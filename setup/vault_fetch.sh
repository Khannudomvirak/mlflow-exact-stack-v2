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
# Each service reads its own path, so one service's key never lands in another.
SECRET_PATH="${SECRET_PATH:?SECRET_PATH must be set}"
FIELD_KEY="${FIELD_KEY:-access_key}"
FIELD_SECRET="${FIELD_SECRET:-secret_key}"

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

# Read into variables first: a denied read must abort the run, never render an
# empty credential that the service would then start with.
ACCESS_KEY=$(vault kv get -field="$FIELD_KEY" "$SECRET_PATH")
SECRET_KEY=$(vault kv get -field="$FIELD_SECRET" "$SECRET_PATH")
if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
  echo "$SERVICE-creds: $SECRET_PATH returned an empty credential" >&2
  exit 1
fi

mkdir -p "$(dirname "$CREDS_FILE")"
tmp="$CREDS_FILE.tmp"
{
  printf 'S3_ACCESS_KEY=%s\n' "$ACCESS_KEY"
  printf 'S3_SECRET_KEY=%s\n' "$SECRET_KEY"
} > "$tmp"
chmod 0444 "$tmp"
mv "$tmp" "$CREDS_FILE"

echo "$SERVICE-creds: rendered $CREDS_FILE from $SECRET_PATH"
