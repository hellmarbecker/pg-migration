#!/usr/bin/env bash
# Delete the source RDS instance, its parameter group and security group.
# Destructive and not reversible: no final snapshot is taken.
source "$(dirname "$0")/common.sh"

read -r -p "Delete RDS instance $RDS_INSTANCE_ID in $AWS_REGION (no final snapshot)? [y/N] " ans
[[ "$ans" == "y" ]] || { log "Aborted"; exit 1; }

if aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$RDS_INSTANCE_ID" \
    --skip-final-snapshot --delete-automated-backups >/dev/null
  log "Waiting for deletion"
  aws rds wait db-instance-deleted --db-instance-identifier "$RDS_INSTANCE_ID"
fi

aws rds delete-db-subnet-group --db-subnet-group-name "$RDS_SUBNET_GROUP" 2>/dev/null || true
aws rds delete-db-parameter-group --db-parameter-group-name "$RDS_PARAM_GROUP" 2>/dev/null || true

VPC_ID="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
SG_ID="$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$RDS_SECURITY_GROUP" \
  --query 'SecurityGroups[0].GroupId' --output text)"
[[ "$SG_ID" != "None" ]] && aws ec2 delete-security-group --group-id "$SG_ID"

log "Teardown complete"
