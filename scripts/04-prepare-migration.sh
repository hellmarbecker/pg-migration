#!/usr/bin/env bash
# Prepare source and target for the ClickPipes import, then print the values
# for the console wizard. Idempotent.
#
#   Source (RDS): replication user with read access to $MIG_SCHEMA, a publication
#                 for the schema, and ClickPipes egress IPs in the security group.
#   Target:       an empty database $MIG_TARGET_DB for the wizard's Automated
#                 schema migration (it expects an empty target database).
#
# The import itself has no API/CLI: it is created in the ClickHouse Cloud console
# (Managed Postgres service -> Data sources -> Start import). See the printed steps.
source "$(dirname "$0")/common.sh"

[[ -n "${RDS_MASTER_PASSWORD:-}" && -n "${CH_PG_PASSWORD:-}" ]] \
  || { log "Missing credentials in .env.local (run 01-03 first)"; exit 1; }

# --- Replication user password (kept in .env.local) ---
if [[ -z "${CLICKPIPES_PASSWORD:-}" ]]; then
  CLICKPIPES_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
  umask 077
  printf 'CLICKPIPES_PASSWORD=%q\n' "$CLICKPIPES_PASSWORD" >> "$SECRETS_FILE"
  log "Generated $CLICKPIPES_USER password and stored it in .env.local"
fi

# --- Source: user, grants, publication ---
log "Configuring $CLICKPIPES_USER and publication $CLICKPIPES_PUBLICATION on RDS"
rds_psql -q -v user="$CLICKPIPES_USER" -v pw="$CLICKPIPES_PASSWORD" \
  -v schema="$MIG_SCHEMA" -v pub="$CLICKPIPES_PUBLICATION" -v owner="$RDS_MASTER_USER" <<'SQL'
SELECT format(CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'user')
                   THEN 'ALTER ROLE %I WITH LOGIN PASSWORD %L'
                   ELSE 'CREATE ROLE %I WITH LOGIN PASSWORD %L' END, :'user', :'pw') \gexec
GRANT USAGE ON SCHEMA :"schema" TO :"user";
GRANT SELECT ON ALL TABLES IN SCHEMA :"schema" TO :"user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"schema" GRANT SELECT ON TABLES TO :"user";
GRANT rds_replication TO :"user";
SELECT format('CREATE PUBLICATION %I FOR TABLES IN SCHEMA %I', :'pub', :'schema')
WHERE NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = :'pub') \gexec
SQL

# Every published table needs a primary key (or REPLICA IDENTITY FULL).
NO_PK="$(rds_psql -At -v schema="$MIG_SCHEMA" <<'SQL'
SELECT string_agg(c.relname, ', ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = :'schema' AND c.relkind = 'r' AND c.relreplident <> 'f'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary);
SQL
)"
[[ -z "$NO_PK" ]] || { log "Tables without primary key: $NO_PK"; exit 1; }

# --- Source: allow ClickPipes egress IPs for the target's region ---
VPC_ID="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
SG_ID="$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$RDS_SECURITY_GROUP" \
  --query 'SecurityGroups[0].GroupId' --output text)"
IPS="$(curl -fsS https://api.clickhouse.cloud/static-ips.json \
  | jq -r --arg r "$CH_PG_REGION" '.aws[] | select(.region == $r) | .clickpipes_egress_ips[]')"
[[ -n "$IPS" ]] || { log "No ClickPipes egress IPs listed for $CH_PG_REGION"; exit 1; }
for ip in $IPS; do
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=$ip/32,Description=clickpipes-$CH_PG_REGION}]" \
    >/dev/null 2>&1 && log "Allowed $ip/32" || log "$ip/32 already allowed"
done

# --- Target: allow the same ClickPipes egress IPs ---
# The import also connects to the target's public endpoint from these IPs.
TARGET_ID="$(target_id)"
EXISTING="$(chctl postgres get "$TARGET_ID" | jq -r '.ipAccessList[]? | "\(.source)|\(.portRange)"')"
ADD=()
for ip in $IPS; do
  grep -qx "$ip/32|5432" <<<"$EXISTING" || ADD+=(--add-ip-allow "$ip/32:5432=clickpipes-$CH_PG_REGION")
done
if (( ${#ADD[@]} )); then
  chctl postgres update "$TARGET_ID" "${ADD[@]}" >/dev/null
  log "Allowed $(( ${#ADD[@]} / 2 )) ClickPipes IPs on target $CH_PG_NAME"
else
  log "ClickPipes IPs already allowed on target"
fi

# --- Target: empty database for the import ---
target_psql -q -v db="$MIG_TARGET_DB" <<'SQL'
SELECT format('CREATE DATABASE %I', :'db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
SQL
TABLES="$(TARGET_DBNAME="$MIG_TARGET_DB" target_psql -At -c \
  "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"
[[ "$TABLES" == "0" ]] || log "WARNING: target database $MIG_TARGET_DB is not empty ($TABLES tables)"

cat >&2 <<EOF

Source and target are ready. Now create the import in the ClickHouse Cloud console:

  1. Open service "$CH_PG_NAME" -> Data sources -> Start import.
  2. Connection:  host     $(rds_endpoint)
                  port     5432
                  database $RDS_DB_NAME
                  user     $CLICKPIPES_USER
                  password CLICKPIPES_PASSWORD in .env.local
                  TLS      on
     Ingestion method: Initial load only. Next.
  3. Schema migration: Automated, destination database "$MIG_TARGET_DB". Next.
  4. Publication: $CLICKPIPES_PUBLICATION (leave advanced settings at defaults). Next.
  5. Tables: select all of schema "$MIG_SCHEMA". Create migration.

When the Tables tab shows the initial load finished, run ./scripts/05-verify-migration.sh
EOF
