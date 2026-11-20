#!/usr/bin/env bash
# Sourced by the other scripts: loads config and local secrets.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$REPO_ROOT/config.env"

SECRETS_FILE="$REPO_ROOT/.env.local"
SECRETS_DIR="$REPO_ROOT/.secrets"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Print a psql connection URI for the source RDS instance.
rds_endpoint() {
  aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].Endpoint.Address' --output text
}

rds_psql() {
  local host
  host="$(rds_endpoint)"
  PGPASSWORD="$RDS_MASTER_PASSWORD" psql \
    "host=$host port=5432 dbname=$RDS_DB_NAME user=$RDS_MASTER_USER sslmode=require" \
    -v ON_ERROR_STOP=1 "$@"
}

# --- ClickHouse Managed Postgres target ---

# clickhousectl cloud, scoped to the configured org, JSON output.
chctl() {
  # Unwraps the API's {"result": ...} envelope if present.
  clickhousectl cloud "$@" --org-id "$CH_ORG_ID" --json 2> >(grep -v 'new version of clickhousectl' >&2) \
    | jq 'if type == "object" and has("result") then .result else . end'
}

target_id() {
  chctl postgres list | jq -r --arg n "$CH_PG_NAME" '.[] | select(.name == $n) | .id'
}

target_host() {
  chctl postgres get "$(target_id)" | jq -r '.hostname'
}

target_psql() {
  PGPASSWORD="$CH_PG_PASSWORD" psql \
    "host=$(target_host) port=5432 dbname=${TARGET_DBNAME:-postgres} user=$CH_PG_USER sslmode=verify-full sslrootcert=$SECRETS_DIR/target-ca.pem" \
    -v ON_ERROR_STOP=1 "$@"
}
