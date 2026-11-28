#!/bin/sh
# Seeds the lakehouse MinIO credentials into Vault's KV store and renders them
# to a shared volume for the containers that need S3 access.
#
# Runs once per `docker compose up` from the `vault-init` service. Idempotent:
# the same values are written and rendered on every start.
set -eu

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

RENDER_PATH="${RENDER_PATH:-/vault-creds/minio.env}"
SECRET_PATH="secret/lakehouse/minio"
POLICY_NAME="lakehouse-minio-reader"

echo "vault-init: waiting for $VAULT_ADDR"
i=0
until vault status >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "vault-init: Vault did not become ready" >&2
    exit 1
  fi
  sleep 2
done

vault kv put "$SECRET_PATH" \
  root_user="${MINIO_ROOT_USER:-minioadmin}" \
  root_password="${MINIO_ROOT_PASSWORD:-minioadmin}" >/dev/null
echo "vault-init: wrote $SECRET_PATH"

# A read-only policy, so the demo shows least privilege and not just storage.
# Read it back with: docker compose exec vault vault policy read $POLICY_NAME
vault policy write "$POLICY_NAME" - >/dev/null <<'POLICY'
path "secret/data/lakehouse/minio" {
  capabilities = ["read"]
}
POLICY
echo "vault-init: wrote policy $POLICY_NAME"

# Render the KV contents into an env file the other containers source.
# This is Vault Agent's templating idea in miniature.
mkdir -p "$(dirname "$RENDER_PATH")"
{
  printf 'MINIO_ROOT_USER=%s\n' "$(vault kv get -field=root_user "$SECRET_PATH")"
  printf 'MINIO_ROOT_PASSWORD=%s\n' "$(vault kv get -field=root_password "$SECRET_PATH")"
} > "$RENDER_PATH"
chmod 0644 "$RENDER_PATH"
echo "vault-init: rendered $RENDER_PATH from Vault"
