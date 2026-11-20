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
- **ClickHouse side:** scripted with ClickHouse control (ClickHouse's CLI). Other scripting, such as calls to the ClickHouse Cloud API, is fine where the CLI doesn't cover a step.
- Every step should be runnable from a script. Avoid manual steps. If a step can't be automated, document it in the relevant script.

## Commands

```bash
aws sso login                    # SSO session for the AWS profile (default: "default")
./scripts/01-create-rds.sh       # create source RDS instance (idempotent, ~10 min)
./scripts/02-populate-rds.sh     # (re)load sample data into schema "shop"
./scripts/99-teardown-rds.sh     # delete RDS instance, parameter group, security group
```

All settings live in `config.env` (profile, region `eu-central-1`, instance ID, class, sample sizes). Any value can be overridden by an environment variable. `scripts/common.sh` is sourced by every script: it loads the config and `.env.local`, and provides `rds_psql` for running psql against the source.

## Source setup details

- The master password is generated on first run and stored in `.env.local`, which is gitignored. Never print or commit it.
- The instance is publicly accessible in the default VPC. Its security group allows 5432 only from the workstation IP that ran `01-create-rds.sh`. ClickPipes' egress IPs must be added before migrating.
- A custom parameter group sets `rds.logical_replication=1`, a static parameter; the create script reboots to apply it. This prepares the source for ClickPipes.
- `sql/sample_data.sql` drops and recreates schema `shop`: customers, products, orders, order_items. It uses enum, uuid, numeric, jsonb, text[] and timestamptz columns, and every table has a primary key. Row counts come from psql variables `n_customers`, `n_products` and `n_orders`. To test the SQL without AWS, run it against a local Postgres with the same `-v` variables.

## Status

Source side (RDS) is scripted. The ClickHouse Managed Postgres target and the ClickPipes migration aren't built yet.
