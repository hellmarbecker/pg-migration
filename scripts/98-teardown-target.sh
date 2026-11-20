#!/usr/bin/env bash
# Delete the ClickHouse Managed Postgres target service.
# Irreversible: the service and its data cannot be recovered.
source "$(dirname "$0")/common.sh"

ID="$(target_id)"
[[ -n "$ID" ]] || { log "No service named $CH_PG_NAME"; exit 0; }

read -r -p "Delete Managed Postgres service $CH_PG_NAME ($ID) and all its data? [y/N] " ans
[[ "$ans" == "y" ]] || { log "Aborted"; exit 1; }

chctl postgres delete "$ID" >/dev/null
rm -f "$SECRETS_DIR/target-create.json" "$SECRETS_DIR/target-ca.pem"
log "Deleted $CH_PG_NAME. Remove CH_PG_USER/CH_PG_PASSWORD from .env.local if you recreate it."
