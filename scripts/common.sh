#!/usr/bin/env bash
# Sourced by the other scripts: loads config and local secrets.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$REPO_ROOT/config.env"

SECRETS_FILE="$REPO_ROOT/.env.local"
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
