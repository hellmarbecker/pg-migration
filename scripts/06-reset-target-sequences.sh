#!/usr/bin/env bash
# Post-migration: the initial load copies rows but not sequence positions, so
# identity/serial sequences on the target start at 1 again. Advance each sequence
# owned by a column in $MIG_SCHEMA to that column's max value. Idempotent.
# (Same effect as the wizard's "Reset sequences" post-migration step.)
source "$(dirname "$0")/common.sh"

TARGET_DBNAME="$MIG_TARGET_DB" target_psql -q -o /dev/null -v schema="$MIG_SCHEMA" <<'SQL'
SELECT format(
         'SELECT setval(%L, coalesce((SELECT max(%I) FROM %I.%I), 1), (SELECT max(%I) FROM %I.%I) IS NOT NULL)',
         s.oid::regclass, a.attname, n.nspname, t.relname, a.attname, n.nspname, t.relname)
FROM pg_class s
JOIN pg_depend d    ON d.objid = s.oid AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
JOIN pg_class t     ON t.oid = d.refobjid
JOIN pg_namespace n ON n.oid = t.relnamespace
JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
WHERE s.relkind = 'S' AND n.nspname = :'schema' \gexec
SQL

TARGET_DBNAME="$MIG_TARGET_DB" target_psql -At -F ' ' -v schema="$MIG_SCHEMA" \
  -c "select sequencename, last_value from pg_sequences where schemaname = '$MIG_SCHEMA' order by 1" \
  | while read -r seq val; do log "$seq -> $val"; done
