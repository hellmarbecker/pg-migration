#!/usr/bin/env bash
# Create the source RDS for PostgreSQL instance in the default VPC.
# Idempotent: existing resources are reused.
source "$(dirname "$0")/common.sh"

log "Account: $(aws sts get-caller-identity --query Account --output text), region: $AWS_REGION"

# --- Master password (kept locally in .env.local, never committed) ---
if [[ -z "${RDS_MASTER_PASSWORD:-}" ]]; then
  RDS_MASTER_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
  umask 077
  printf 'RDS_MASTER_PASSWORD=%q\n' "$RDS_MASTER_PASSWORD" >> "$SECRETS_FILE"
  log "Generated master password and stored it in .env.local"
fi

# --- Parameter group with logical replication enabled (needed by ClickPipes) ---
if ! aws rds describe-db-parameter-groups --db-parameter-group-name "$RDS_PARAM_GROUP" >/dev/null 2>&1; then
  log "Creating parameter group $RDS_PARAM_GROUP"
  aws rds create-db-parameter-group \
    --db-parameter-group-name "$RDS_PARAM_GROUP" \
    --db-parameter-group-family "postgres${RDS_PG_MAJOR}" \
    --description "pg-migration source: logical replication enabled" \
    --tags Key=project,Value=pg-migration >/dev/null
fi
aws rds modify-db-parameter-group --db-parameter-group-name "$RDS_PARAM_GROUP" \
  --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" >/dev/null

# --- Security group in the default VPC, open to this machine's public IP ---
VPC_ID="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" == "None" ]] && { log "No default VPC in $AWS_REGION"; exit 1; }

SG_ID="$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$RDS_SECURITY_GROUP" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$SG_ID" == "None" ]]; then
  log "Creating security group $RDS_SECURITY_GROUP in $VPC_ID"
  SG_ID="$(aws ec2 create-security-group --group-name "$RDS_SECURITY_GROUP" \
    --description "pg-migration source Postgres access" --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=project,Value=pg-migration}]' \
    --query GroupId --output text)"
fi

MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
log "Allowing 5432 from $MY_IP/32"
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=$MY_IP/32,Description=setup-workstation}]" \
  >/dev/null 2>&1 || log "Ingress rule already present"

# --- DB subnet group with public subnets only ---
# The default subnet group may contain private (NAT-routed) subnets, which makes a
# "publicly accessible" instance unreachable. Use only subnets routed via an IGW.
if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$RDS_SUBNET_GROUP" >/dev/null 2>&1; then
  RTS="$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC_ID" --output json)"
  SUBNETS="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[].SubnetId' --output json)"
  PUBLIC_SUBNETS="$(jq -rn --argjson rts "$RTS" --argjson subs "$SUBNETS" '
    def has_igw: any(.Routes[]; .DestinationCidrBlock == "0.0.0.0/0" and ((.GatewayId // "") | startswith("igw-")));
    ($rts.RouteTables | map(select(any(.Associations[]?; .Main == true))) | .[0]) as $main
    | $subs[] as $s
    | ([$rts.RouteTables[] | select(any(.Associations[]?; .SubnetId == $s))] | .[0] // $main) as $rt
    | select($rt | has_igw) | $s')"
  [[ -n "$PUBLIC_SUBNETS" ]] || { log "No public subnets found in $VPC_ID"; exit 1; }
  log "Creating DB subnet group $RDS_SUBNET_GROUP: $(echo $PUBLIC_SUBNETS)"
  # shellcheck disable=SC2086
  aws rds create-db-subnet-group --db-subnet-group-name "$RDS_SUBNET_GROUP" \
    --db-subnet-group-description "pg-migration source: public subnets" \
    --subnet-ids $PUBLIC_SUBNETS --tags Key=project,Value=pg-migration >/dev/null
fi

# --- DB instance ---
if aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" >/dev/null 2>&1; then
  log "Instance $RDS_INSTANCE_ID already exists"
else
  ENGINE_VERSION="$(aws rds describe-db-engine-versions --engine postgres \
    --query "DBEngineVersions[?starts_with(EngineVersion, '${RDS_PG_MAJOR}.')].EngineVersion" \
    --output text | tr '\t' '\n' | sort -V | tail -1)"
  log "Creating $RDS_INSTANCE_ID ($RDS_INSTANCE_CLASS, postgres $ENGINE_VERSION, ${RDS_STORAGE_GB}GB gp3)"
  aws rds create-db-instance \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --db-instance-class "$RDS_INSTANCE_CLASS" \
    --engine postgres --engine-version "$ENGINE_VERSION" \
    --allocated-storage "$RDS_STORAGE_GB" --storage-type gp3 \
    --db-name "$RDS_DB_NAME" \
    --master-username "$RDS_MASTER_USER" --master-user-password "$RDS_MASTER_PASSWORD" \
    --db-parameter-group-name "$RDS_PARAM_GROUP" \
    --vpc-security-group-ids "$SG_ID" \
    --db-subnet-group-name "$RDS_SUBNET_GROUP" \
    --publicly-accessible --no-multi-az \
    --backup-retention-period 1 --no-deletion-protection \
    --tags Key=project,Value=pg-migration >/dev/null
fi

log "Waiting for $RDS_INSTANCE_ID to become available (typically 5-10 min)"
aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"

# Apply the static rds.logical_replication parameter if a reboot is pending.
STATUS="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" \
  --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' --output text)"
if [[ "$STATUS" == "pending-reboot" ]]; then
  log "Rebooting to apply parameter group"
  aws rds reboot-db-instance --db-instance-identifier "$RDS_INSTANCE_ID" >/dev/null
  sleep 30
  aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"
fi

log "Ready: $(rds_endpoint):5432 db=$RDS_DB_NAME user=$RDS_MASTER_USER"
