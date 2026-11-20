#!/usr/bin/env bash
# Compare every table of $MIG_SCHEMA between source (RDS) and target (Managed Postgres):
# exact row count plus an md5 over all rows (rendered as text in UTC, sorted with
# collation "C" so both sides order identically). Exits non-zero on any mismatch.
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
printf '%-14s %10s %10s  %s\n' table source target result
for t in $TABLES; do
  src="$(rds_psql -At -q -c "$(fingerprint_sql "$t")")"
  dst="$(TARGET_DBNAME="$MIG_TARGET_DB" target_psql -At -q -c "$(fingerprint_sql "$t")" 2>/dev/null || echo "missing|-")"
  if [[ "$src" == "$dst" ]]; then res=OK; else res=MISMATCH; fail=1; fi
  printf '%-14s %10s %10s  %s\n' "$t" "${src%%|*}" "${dst%%|*}" "$res"
done

[[ $fail == 0 ]] && log "All tables match" || { log "Differences found"; exit 1; }
