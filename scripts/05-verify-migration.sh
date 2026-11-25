#!/usr/bin/env bash
# Compare every table of $MIG_SCHEMA between source (RDS) and target (Managed Postgres):
# exact row count plus an md5 over all rows (rendered as text in UTC, sorted with
# collation "C" so both sides order identically). Partitioned tables are checked
# as a whole and per partition. Then compares partition layout, triggers and
# functions, and checks on the target that the trigger fires (rolled back).
# Exits non-zero on any mismatch.
source "$(dirname "$0")/common.sh"

TABLES="$(rds_psql -At -v schema="$MIG_SCHEMA" <<'SQL'
SELECT tablename FROM pg_tables WHERE schemaname = :'schema' ORDER BY 1;
SQL
)"
[[ -n "$TABLES" ]] || { log "No tables in source schema $MIG_SCHEMA"; exit 1; }

# count|md5 for one table
fingerprint_sql() {
  echo "SET timezone = 'UTC'; SELECT count(*) || '|' || coalesce(md5(string_agg(t::text, chr(10) ORDER BY t::text COLLATE \"C\")), '-') FROM $MIG_SCHEMA.$1 t;"
}

fail=0
printf '%-30s %10s %10s  %s\n' table source target result
for t in $TABLES; do
  src="$(rds_psql -At -q -c "$(fingerprint_sql "$t")")"
  dst="$(TARGET_DBNAME="$MIG_TARGET_DB" target_psql -At -q -c "$(fingerprint_sql "$t")" 2>/dev/null || echo "missing|-")"
  if [[ "$src" == "$dst" ]]; then res=OK; else res=MISMATCH; fail=1; fi
  printf '%-30s %10s %10s  %s\n' "$t" "${src%%|*}" "${dst%%|*}" "$res"
done

# --- Schema objects: partition keys/bounds, triggers, functions ---
# One line per object; timezone pinned because partition bounds render in it.
STRUCT_SQL="SET timezone = 'UTC';
SELECT 'partkey ' || c.relname || ': ' || pg_get_partkeydef(c.oid)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '$MIG_SCHEMA' AND c.relkind = 'p'
UNION ALL
SELECT 'partition ' || p.relname || ' <- ' || c.relname || ': ' || pg_get_expr(c.relpartbound, c.oid)
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
JOIN pg_namespace n ON n.oid = p.relnamespace
WHERE n.nspname = '$MIG_SCHEMA' AND c.relkind IN ('r', 'p')
UNION ALL
SELECT 'trigger ' || pg_get_triggerdef(t.oid) || CASE t.tgenabled WHEN 'D' THEN ' [disabled]' ELSE '' END
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '$MIG_SCHEMA' AND NOT t.tgisinternal
UNION ALL
SELECT 'function ' || p.oid::regprocedure || ' md5=' || md5(pg_get_functiondef(p.oid))
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = '$MIG_SCHEMA'
ORDER BY 1;"
src_struct="$(rds_psql -At -q -c "$STRUCT_SQL")"
dst_struct="$(TARGET_DBNAME="$MIG_TARGET_DB" target_psql -At -q -c "$STRUCT_SQL")"
echo
printf 'Schema objects: %s on source, %s on target\n' \
  "$(grep -c . <<<"$src_struct")" "$(grep -c . <<<"$dst_struct")"
if diff <(echo "$src_struct") <(echo "$dst_struct") >/dev/null; then
  log "Partition layout, triggers and functions match"
else
  log "Schema object differences (< source, > target):"
  diff <(echo "$src_struct") <(echo "$dst_struct") | grep '^[<>]' >&2
  fail=1
fi

# --- Trigger fires on the target? Update one order's status, roll back. ---
TRIGGERS="$(rds_psql -At -c "select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace where n.nspname = '$MIG_SCHEMA' and c.relname = 'orders' and not t.tgisinternal")"
if [[ "$TRIGGERS" != "0" ]]; then
  delta="$(TARGET_DBNAME="$MIG_TARGET_DB" target_psql -At -q 2>&1 <<SQL
BEGIN;
CREATE TEMP TABLE before_count AS SELECT count(*) AS n FROM $MIG_SCHEMA.order_status_history;
UPDATE $MIG_SCHEMA.orders SET status = CASE status WHEN 'cancelled' THEN 'pending' ELSE 'cancelled' END::$MIG_SCHEMA.order_status
WHERE order_id = (SELECT min(order_id) FROM $MIG_SCHEMA.orders);
SELECT (SELECT count(*) FROM $MIG_SCHEMA.order_status_history) - n FROM before_count;
ROLLBACK;
SQL
)"
  if [[ "$delta" == "1" ]]; then
    log "Trigger on orders fires on the target (1 history row; rolled back)"
  else
    log "Trigger on orders did not fire on the target: $delta"
    fail=1
  fi
fi

[[ $fail == 0 ]] && log "All tables match" || { log "Differences found"; exit 1; }
