#!/usr/bin/env bash
# Load the sample dataset (sql/sample_data.sql) into the source RDS instance.
# Re-running drops and recreates the "shop" schema.
source "$(dirname "$0")/common.sh"

[[ -n "${RDS_MASTER_PASSWORD:-}" ]] || { log "RDS_MASTER_PASSWORD not set (run 01-create-rds.sh first)"; exit 1; }

log "Loading sample data into $RDS_INSTANCE_ID/$RDS_DB_NAME"
rds_psql \
  -v n_customers="$SAMPLE_CUSTOMERS" \
  -v n_products="$SAMPLE_PRODUCTS" \
  -v n_orders="$SAMPLE_ORDERS" \
  -f "$REPO_ROOT/sql/sample_data.sql"
