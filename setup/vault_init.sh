#!/bin/sh
# Seeds Vault and gives every consumer its own identity.
#
# Runs once per `docker compose up` from the `vault-init` service, which is the
# only container that ever holds the dev root token. For each service in
# $SERVICES it writes:
#   - a policy that can read this one secret and nothing else
#   - an AppRole whose tokens live for $TOKEN_TTL
#   - that role's role_id/secret_id into the service's own approle volume
#
# A one-shot `*-creds` sidecar then logs in as the service itself and renders
# the keys into the matching creds volume. No consumer sees the root token, and
# none of them shares a rendered file with the others.
set -eu

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

SECRET_PATH="${SECRET_PATH:-secret/lakehouse/minio}"
APPROLE_ROOT="${APPROLE_ROOT:-/approle}"
TOKEN_TTL="${TOKEN_TTL:-1h}"
SERVICES="${SERVICES:-nessie mlflow}"

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

# The storage credential itself. MinIO's root login has to exist before anything
# can store it, so this pair still arrives from .env; it is the last bootstrap
# value in the stack.
vault kv put "$SECRET_PATH" \
  root_user="${MINIO_ROOT_USER:-minioadmin}" \
  root_password="${MINIO_ROOT_PASSWORD:-minioadmin}" >/dev/null
echo "vault-init: wrote $SECRET_PATH"

# AppRole is how a container authenticates as itself: no shared token, and each
# role carries its own policy.
vault auth enable approle >/dev/null 2>&1 || true
echo "vault-init: approle auth ready"

for svc in $SERVICES; do
  policy="lakehouse-s3-$svc"

  vault policy write "$policy" - >/dev/null <<POLICY
path "secret/data/lakehouse/minio" {
  capabilities = ["read"]
}

path "secret/metadata/lakehouse/minio" {
  capabilities = ["read"]
}
POLICY

  vault write "auth/approle/role/$svc" \
    token_policies="$policy" \
    token_ttl="$TOKEN_TTL" \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0 >/dev/null

  dir="$APPROLE_ROOT/$svc"
  mkdir -p "$dir"
  vault read -field=role_id "auth/approle/role/$svc/role-id" > "$dir/role_id"
  vault write -f -field=secret_id "auth/approle/role/$svc/secret-id" > "$dir/secret_id"
  # Only the fetcher sidecar reads these; the application volume is separate.
  chmod 0400 "$dir/role_id" "$dir/secret_id"

  echo "vault-init: identity $svc ready (policy $policy, token ttl $TOKEN_TTL)"
done

echo "vault-init: done; consumers authenticate as themselves"
