# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository scripts a one-off migration from **Amazon RDS for PostgreSQL** to **ClickHouse Managed Postgres**, using **ClickPipes** to move the data.

The end-to-end flow has two phases:

1. **Source setup (AWS):** provision an RDS Postgres instance and populate it with example data.
2. **Migration (ClickHouse):** provision the ClickHouse Managed Postgres target and run a one-off ClickPipes migration from RDS into it.

The migration is a one-time load, not ongoing replication. Don't add continuous-sync or CDC features unless asked.

## Tooling

- **AWS side:** everything is scripted with the AWS CLI (`aws ...`). Don't use console steps or other IaC tools unless asked.
- **ClickHouse side:** scripted with `clickhousectl cloud ...` (ClickHouse's CLI). Other scripting, such as calls to the ClickHouse Cloud API, is fine where the CLI doesn't cover a step. Write commands need an API key login (`clickhousectl cloud auth login --interactive`); the OAuth/browser login is read-only. The user has many orgs, so every call must pass `--org-id` (the `chctl` helper does this).
- Every step should be runnable from a script. Avoid manual steps. If a step can't be automated, document it in the relevant script.

## Commands

```bash
aws sso login                    # SSO session for the AWS profile (default: "default")
./scripts/01-create-rds.sh       # create source RDS instance (idempotent, ~10 min)
./scripts/02-populate-rds.sh     # (re)load sample data into schema "shop"
./scripts/03-create-target.sh    # create ClickHouse Managed Postgres target (idempotent, ~6 min)
./scripts/04-prepare-migration.sh # replication user, publication, ClickPipes IPs, empty target DB; prints wizard steps
./scripts/05-verify-migration.sh # compare row count + md5 of every table, source vs target
./scripts/06-reset-target-sequences.sh # advance target identity sequences to max(id) after the load
./scripts/07-cleanup-source.sh   # drop the import's replication slot on RDS (after deleting the migration in the console)
./scripts/98-teardown-target.sh  # delete the target service (irreversible)
./scripts/99-teardown-rds.sh     # delete RDS instance, subnet/parameter/security groups
```

All settings live in `config.env` (profile, region `eu-central-1`, instance ID, class, sample sizes). Any value can be overridden by an environment variable. `scripts/common.sh` is sourced by every script: it loads the config and `.env.local`, and provides `rds_psql` / `target_psql` for running psql against source and target, plus `chctl` (clickhousectl with `--org-id` and `--json`, unwrapping the API's `result` envelope).

## Source setup details

- The master password is generated on first run and stored in `.env.local`, which is gitignored. Never print or commit it.
- The default VPC's default DB subnet group includes a NAT-routed private subnet (`private-toy`); an instance placed there is unreachable despite having a public IP. `01-create-rds.sh` therefore builds its own subnet group from IGW-routed subnets only.
- The instance is publicly accessible in the default VPC. Its security group allows 5432 only from the workstation IP that ran `01-create-rds.sh`. ClickPipes' egress IPs must be added before migrating.
- A custom parameter group sets `rds.logical_replication=1`, a static parameter. It applies at creation; the create script reboots only if a change is pending. This prepares the source for ClickPipes.
- `sql/sample_data.sql` drops and recreates schema `shop`: customers, products, orders, order_items. It uses enum, uuid, numeric, jsonb, text[] and timestamptz columns, and every table has a primary key. `order_status_history` is range-partitioned by quarter on `changed_at` (10 partitions including `DEFAULT`; the identity column on a partitioned table needs PG17, so the local PG14 can't run this file anymore). Trigger `orders_status_change` (AFTER UPDATE OF status on `orders`) writes into it via function `log_order_status_change()`. Row counts come from psql variables `n_customers`, `n_products` and `n_orders`. To test the SQL without AWS, run it against a local Postgres with the same `-v` variables.

## Target setup details

- Service `pg-migration-target` in HB's Organization, `eu-central-1`, Postgres 17, size `r6gd.medium` (smallest: 1 vCPU, 8 GB RAM, 59 GB NVMe), no HA. Admin database is `postgres`; migrated data goes to database `shop` (`TARGET_DBNAME=shop target_psql ...`).
- The password is returned only by the create call. `03-create-target.sh` stores `CH_PG_USER`/`CH_PG_PASSWORD` in `.env.local` and the raw response in `.secrets/target-create.json` (both gitignored). If lost, use `clickhousectl cloud postgres reset-password`. `get` never returns credentials.
- Access is limited by `--ip-allow` to the workstation IP on 5432. Omitting `--ip-allow` would open 5432 and 6432 to everyone.
- `target_psql` verifies the server certificate with `.secrets/target-ca.pem` (`sslmode=verify-full`).
- `clickhousectl cloud postgres delete` acts immediately with no confirmation.

## Migration details

- The RDS → Managed Postgres import ("Data sources" in the console) has **no API or CLI**. `clickhousectl cloud clickpipe create postgres` and the Cloud API's `/services/{id}/clickpipes` only target ClickHouse services (ReplacingMergeTree tables), not Managed Postgres. So the one manual step is the console wizard: service → **Data sources** → **Start import**, ingestion method **Initial load only**, schema migration **Automated** into the empty `shop` database, publication `clickpipes_shop`, all tables of schema `shop`. `04-prepare-migration.sh` prints the exact values.
- Use Automated schema migration: the local `pg_dump`/`psql` are version 14 and can't dump the Postgres 17 source, which Manual mode would need.
- `04-prepare-migration.sh` creates `clickpipes_user` (password in `.env.local` as `CLICKPIPES_PASSWORD`) with SELECT on `shop` and `rds_replication`, and publication `clickpipes_shop FOR TABLES IN SCHEMA shop WITH (publish_via_partition_root = true)`, so partitioned tables are published as their root table. It also adds the ClickPipes egress IPs for the target's region, read from `https://api.clickhouse.cloud/static-ips.json`, to the RDS security group **and to the target's IP allow list**. The import connects to the target's public endpoint from those IPs too; without them, the wizard times out with `connect to destination postgres ... dial error: timeout`. Every published table must have a primary key; the script checks this.
- `publish_via_partition_root = true` makes the publication list only the root of a partitioned table (`order_status_history`), not its partitions, and report changes under the root's name. The import then copies the table once through the root, and the target only needs a table with the root's name: Postgres routes each row into the right partition there, and the target could even be partitioned differently or not at all. With the default `false`, the publication lists every leaf partition instead, and the target must have matching partitions with the same names. Partition layout on the target comes from the Automated schema migration either way. ClickPipes docs show the setting in a FAQ example but don't require it. Both values were tested on 2026-11-25 with identical results: all tables and every partition match, partition layout and trigger match, the trigger fires on the target. The default is `true`; set `CLICKPIPES_VIA_ROOT=false` (config.env or environment) before `04-prepare-migration.sh` to publish leaf partitions instead. `04` logs the tables the publication lists.
- `05-verify-migration.sh` fingerprints each table on both sides with `count(*)` and `md5(string_agg(row::text ORDER BY row::text COLLATE "C"))` in UTC. Collation and timezone are pinned so formatting and ordering can't cause false mismatches. Partitioned tables are checked as a whole and per partition. It also compares partition keys and bounds, triggers and functions, and checks that the `orders` trigger fires on the target (inside a rolled-back transaction).

- Indexes, constraints (PK/FK/unique/check), the enum type, partitioned tables (same partition key, bounds and rows per partition), trigger functions and triggers (enabled, and firing on the target) come across with Automated schema migration. **Sequence positions don't**: identity sequences on the target stay unset until `06-reset-target-sequences.sh` runs. Otherwise the first insert collides with id 1.
- "Initial load only" still creates a logical replication slot `peerflow_slot_mirror_<uuid>` on RDS, and the migration keeps it active. Delete the migration in the console (Post-migration steps → Clean up), then run `07-cleanup-source.sh` to make sure no slot is left (deleting the migration dropped the slot itself on 2026-11-20); a leftover slot makes RDS retain WAL until the disk fills.

## Status

First migration completed on 2026-11-20; source and target were torn down on 2026-11-21. Rebuilt on 2026-11-24 with the partitioned table and trigger, and migrated again on 2026-11-25: all tables and every partition match (count + md5), partition layout, trigger and function match, the trigger fires on the target, and sequences are reset. No replication slot remained on RDS after the import. Both were torn down again on 2026-11-25, then rebuilt the same day to repeat the migration with `publish_via_partition_root = false`, with the same result, and torn down again afterwards; nothing is left running. RDS keeps the automated snapshots for a short while after deletion and then removes them on its own; they can't be deleted directly. RDS keeps the automated snapshots for a short while after deletion and then removes them on its own; they can't be deleted directly. To rebuild after a teardown, delete `.env.local` first, because the scripts reuse saved passwords. Then run `01`–`04` again.
