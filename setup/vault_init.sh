#!/bin/sh
# Seeds Vault and gives every consumer its own identity and its own storage key.
#
# Runs once per `docker compose up` from the `vault-init` service, which is the
# only container that ever holds the dev root token. For each service in
# $SERVICES it:
#   - generates a fresh S3 access key/secret and stores it at its own KV path
#   - writes a policy that can read that one path and nothing else
#   - writes an AppRole whose tokens live for $TOKEN_TTL
#   - drops role_id/secret_id into the service's own approle volume, and the
#     key into the seed volume that only the MinIO provisioning step reads
#
# A one-shot `*-creds` sidecar then logs in as the service itself and renders
# only its own keys. No consumer sees the root token, and no two consumers
# share a credential.
set -eu

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

# The admin/bootstrap pair stays readable only by the root token; it is what
# `minio` and `minio-init` start with from .env, kept here for humans and Dremio.
ADMIN_SECRET_PATH="${ADMIN_SECRET_PATH:-secret/lakehouse/minio}"
APPROLE_ROOT="${APPROLE_ROOT:-/approle}"
SEED_ROOT="${SEED_ROOT:-/s3seed}"
TOKEN_TTL="${TOKEN_TTL:-1h}"
SERVICES="${SERVICES:-nessie mlflow}"

random_hex() {
  head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"$1"
}

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

# MinIO's root login has to exist before anything can store it, so this pair
# still arrives from .env; it is the last bootstrap value in the stack. No
# service reads it - each one gets its own key below.
vault kv put "$ADMIN_SECRET_PATH" \
  root_user="${MINIO_ROOT_USER:-minioadmin}" \
  root_password="${MINIO_ROOT_PASSWORD:-minioadmin}" >/dev/null
echo "vault-init: wrote $ADMIN_SECRET_PATH (admin pair, root token only)"

# AppRole is how a container authenticates as itself: no shared token, and each
# role carries its own policy.
vault auth enable approle >/dev/null 2>&1 || true
echo "vault-init: approle auth ready"

for svc in $SERVICES; do
  policy="lakehouse-s3-$svc"
  # Relative to the KV v2 mount, so the policy can add the data/ prefix itself.
  kv_path="lakehouse/s3/$svc"
  path="secret/$kv_path"
  # Stable access key per service, so MinIO keeps exactly one identity per
  # service. The secret is generated once and reused for as long as this Vault
  # holds it: a second `up` on a running stack must not rotate the key out from
  # under a consumer that is already serving. A Vault restart wipes the store
  # and the next start issues a new secret, which `minio-provision` re-registers.
  access_key="$svc-svc"
  if existing=$(vault kv get -field=secret_key "$path" 2>/dev/null) && [ -n "$existing" ]; then
    secret_key="$existing"
    echo "vault-init: reusing the existing key for $svc"
  elif [ -f "$SEED_ROOT/$svc.env" ] &&
       existing=$(sed -n 's/^SECRET_KEY=//p' "$SEED_ROOT/$svc.env") && [ -n "$existing" ]; then
    # Dev mode is in-memory: a Vault restart empties it. Restoring the key the
    # volume already holds keeps MinIO's user and the running consumers valid
    # instead of rotating a credential they cannot pick up without a recreate.
    secret_key="$existing"
    vault kv put "$path" access_key="$access_key" secret_key="$secret_key" >/dev/null
    echo "vault-init: restored the $svc key from s3seed"
  else
    secret_key=$(random_hex 40)
    vault kv put "$path" access_key="$access_key" secret_key="$secret_key" >/dev/null
    echo "vault-init: generated a new key for $svc"
  fi

  vault policy write "$policy" - >/dev/null <<POLICY
path "secret/data/$kv_path" {
  capabilities = ["read"]
}

path "secret/metadata/$kv_path" {
  capabilities = ["read"]
}
POLICY

  # Only the MinIO provisioning step reads this, to register the same pair as a
  # bucket-scoped MinIO user. Consumers read the value back from Vault instead.
  mkdir -p "$SEED_ROOT"
  printf 'ACCESS_KEY=%s\nSECRET_KEY=%s\n' "$access_key" "$secret_key" > "$SEED_ROOT/$svc.env"
  chmod 0400 "$SEED_ROOT/$svc.env"

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

  echo "vault-init: identity $svc ready ($path, policy $policy, token ttl $TOKEN_TTL)"
done

echo "vault-init: done; consumers authenticate as themselves"
