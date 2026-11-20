#!/usr/bin/env bash
# Post-migration cleanup on the source, after the import has been deleted in the
# console (Data sources -> migration -> Post-migration steps -> Delete ClickPipe migration).
# Drops the import's leftover replication slot(s). An abandoned logical slot makes
# RDS retain WAL indefinitely and eventually fills the disk. Idempotent.
source "$(dirname "$0")/common.sh"

ACTIVE="$(rds_psql -At -c "select string_agg(slot_name, ', ') from pg_replication_slots where slot_name like 'peerflow_slot_%' and active")"
if [[ -n "$ACTIVE" ]]; then
  log "Slot(s) still in use: $ACTIVE"
  log "Delete the migration in the console first, then re-run this script."
  exit 1
fi

rds_psql -At -c "select slot_name || ': ' || pg_drop_replication_slot(slot_name)::text from pg_replication_slots where slot_name like 'peerflow_slot_%'" \
  | while read -r line; do log "Dropped ${line%%:*}"; done
log "Remaining slots: $(rds_psql -At -c "select coalesce(string_agg(slot_name, ', '), 'none') from pg_replication_slots")"
