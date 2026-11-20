#!/usr/bin/env bash
# Create the ClickHouse Managed Postgres target service with clickhousectl.
# Idempotent: an existing service with the same name is reused.
# Needs an API key login (`clickhousectl cloud auth login --interactive`);
# OAuth (browser) login is read-only.
source "$(dirname "$0")/common.sh"

[[ -n "$CH_PG_SIZE" ]] || { log "CH_PG_SIZE is not set in config.env"; exit 1; }

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

ID="$(target_id)"
if [[ -n "$ID" ]]; then
  log "Service $CH_PG_NAME already exists ($ID)"
else
  MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  log "Creating $CH_PG_NAME ($CH_PG_SIZE, Postgres $CH_PG_VERSION, $CH_PG_REGION), access from $MY_IP/32"
  umask 077
  # The password is returned only by this call: keep the raw response.
  chctl postgres create \
    --name "$CH_PG_NAME" --provider aws --region "$CH_PG_REGION" \
    --size "$CH_PG_SIZE" --pg-version "$CH_PG_VERSION" --ha-type none \
    --tag project=pg-migration \
    --ip-allow "$MY_IP/32:5432=setup-workstation" \
    > "$SECRETS_DIR/target-create.json"

  ID="$(jq -r '.id' "$SECRETS_DIR/target-create.json")"
  if [[ "$(jq -r '.password // empty' "$SECRETS_DIR/target-create.json")" == "" ]]; then
    log "WARNING: create response has no password; use 'clickhousectl cloud postgres reset-password'"
  fi
  {
    printf 'CH_PG_USER=%q\n' "$(jq -r '.username' "$SECRETS_DIR/target-create.json")"
    printf 'CH_PG_PASSWORD=%q\n' "$(jq -r '.password' "$SECRETS_DIR/target-create.json")"
  } >> "$SECRETS_FILE"
  log "Created $ID; credentials stored in .env.local"
fi

log "Waiting for state=running"
for _ in $(seq 1 90); do
  STATE="$(chctl postgres get "$ID" | jq -r '.state')"
  [[ "$STATE" == "running" ]] && break
  log "  state=$STATE"
  sleep 20
done
[[ "$STATE" == "running" ]] || { log "Timed out waiting for $CH_PG_NAME (state=$STATE)"; exit 1; }

chctl postgres certs get "$ID" --output "$SECRETS_DIR/target-ca.pem" >/dev/null
log "Ready: $(target_host):5432 db=postgres (CA cert in .secrets/target-ca.pem)"
