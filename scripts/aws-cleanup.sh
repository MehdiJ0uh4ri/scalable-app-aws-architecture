#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly EXPECTED_ACCOUNT_ID="412514130471"
readonly MAIN_REGION="eu-west-3"
readonly GLOBAL_REGION="us-east-1"
readonly PROJECT="manara-task-app"
readonly ENVIRONMENT="dev"
readonly MANAGED_BY="Terraform"
readonly NAME_PREFIX="manara-task-app-dev"
readonly TARGET_VPC_ID="vpc-0c52f6858b43ab34f"
readonly TARGET_VPC_NAME="manara-task-app-dev-vpc"
readonly CONFIRMATION="DELETE-MANARA-DEV"
readonly EXTERNAL_NAT_ID="nat-059e66ef4a90008a3"
readonly EXTERNAL_NAT_VPC="vpc-0c95d56e949597bd3"

ACTION="${CLEANUP_ACTION:-dry-run}"
CONFIRM_DELETE="${DELETE_CONFIRMATION:-}"

declare -a PLAN=()
declare -a SKIPPED=()
declare -a FAILED=()
declare -a DELETED=()
declare -a UNSUPPORTED=()
declare -a AUTOSCALING_GROUPS=()
declare -a LOAD_BALANCERS=()
declare -a TARGET_GROUPS=()
declare -a RDS_INSTANCES=()
declare -a VPC_ENDPOINTS=()
declare -a NAT_GATEWAYS=()
declare -a NAT_EIPS=()
declare -a ROUTE_TABLES=()
declare -a SECURITY_GROUPS=()
declare -a SUBNETS=()
declare -a NETWORK_ACLS=()
declare -a INTERNET_GATEWAYS=()
declare -a WAF_REGIONAL=()
declare -a WAF_CLOUDFRONT=()
declare -a CLOUDFRONT_DISTRIBUTIONS=()
declare -a IAM_ROLES=()
declare -a IAM_PROFILES=()
declare -a DB_SECURITY_GROUP_IDS=()
declare -a DB_SUBNET_IDS=()
declare -a ALB_SECURITY_GROUP_IDS=()
declare -a MANAGED_ENIS=()
declare -a INITIAL_PLAN=()

VPC_PRESENT=0
ALB_DNS=""
BLOCKERS=0
INITIAL_PLAN_COUNT=0
CLOUDFRONT_TEMP_FILE=""

log() {
  printf '%s\n' "$*"
}

aws_cli() {
  aws --no-cli-pager "$@"
}

record() {
  local status="$1" kind="$2" region="$3" identifier="$4" detail="${5:-}"
  printf '%-12s %-22s %-10s %s' "$status" "$kind" "$region" "$identifier"
  [[ -z "$detail" ]] || printf ' (%s)' "$detail"
  printf '\n'
}

add_plan() {
  local kind="$1" region="$2" identifier="$3" existing
  for existing in "${PLAN[@]}"; do
    [[ "$existing" != "${kind}"$'\t'"${region}"$'\t'"${identifier}" ]] || return 0
  done
  PLAN+=("${kind}"$'\t'"${region}"$'\t'"${identifier}")
}

skip_resource() {
  local kind="$1" region="$2" identifier="$3" reason="$4" blocks="${5:-false}"
  SKIPPED+=("${kind}"$'\t'"${region}"$'\t'"${identifier}"$'\t'"${reason}")
  [[ "$blocks" != "true" ]] || BLOCKERS=$((BLOCKERS + 1))
}

fail_resource() {
  local kind="$1" region="$2" identifier="$3" reason="$4"
  FAILED+=("${kind}"$'\t'"${region}"$'\t'"${identifier}"$'\t'"${reason}")
  BLOCKERS=$((BLOCKERS + 1))
}

unsupported_resource() {
  local kind="$1" region="$2" identifier="$3" reason="$4"
  UNSUPPORTED+=("${kind}"$'\t'"${region}"$'\t'"${identifier}"$'\t'"${reason}")
  BLOCKERS=$((BLOCKERS + 1))
}

print_rows() {
  local status="$1"
  shift
  local row kind region identifier detail
  for row in "$@"; do
    IFS=$'\t' read -r kind region identifier detail <<< "$row"
    record "$status" "$kind" "$region" "$identifier" "${detail:-}"
  done
}

normalize_tags() {
  jq -c '
    (.TagInfoForResourceList[0].TagList // .TagList // .Tags // .tags // []) as $tags
    | if ($tags | type) == "array" then $tags
      elif ($tags | type) == "object" then
        if ($tags.Items | type) == "array" then $tags.Items
        else [$tags | to_entries[] | {Key: .key, Value: .value}] end
      else [] end
  ' <<< "$1"
}

tag_value() {
  local tags="$1" key="$2"
  jq -r --arg key "$key" '[.[] | select((.Key // .key) == $key) | (.Value // .value)][0] // ""' <<< "$tags"
}

# Exact API identifiers and verified parent relationships act as the allowlist
# for resources that do not carry all three Terraform ownership tags.
is_owned() {
  local object="$1" expected_name="$2" allowlisted="$3"
  local tags project environment managed name
  tags="$(normalize_tags "$object")"
  project="$(tag_value "$tags" Project)"
  environment="$(tag_value "$tags" Environment)"
  managed="$(tag_value "$tags" ManagedBy)"
  name="$(tag_value "$tags" Name)"

  [[ -z "$project" || "$project" == "$PROJECT" ]] || return 1
  [[ -z "$environment" || "$environment" == "$ENVIRONMENT" ]] || return 1
  [[ -z "$managed" || "$managed" == "$MANAGED_BY" ]] || return 1
  [[ -z "$name" || "$name" == "$expected_name" ]] || return 1

  if [[ "$project" == "$PROJECT" && "$environment" == "$ENVIRONMENT" && "$managed" == "$MANAGED_BY" ]]; then
    return 0
  fi
  [[ "$allowlisted" == "true" ]]
}

add_named_if_owned() {
  local kind="$1" region="$2" object="$3" identifier="$4" expected_name="$5" allowlisted="$6"
  if is_owned "$object" "$expected_name" "$allowlisted"; then
    add_plan "$kind" "$region" "$identifier"
  else
    skip_resource "$kind" "$region" "$identifier" "ownership tags conflict or cannot be verified" true
  fi
}

account_check() {
  local account
  account="$(aws_cli sts get-caller-identity --query Account --output text)"
  if [[ "$account" != "$EXPECTED_ACCOUNT_ID" ]]; then
    log "::error::Refusing cleanup in AWS account ${account}; expected ${EXPECTED_ACCOUNT_ID}."
    exit 1
  fi
  log "Verified AWS account: ${EXPECTED_ACCOUNT_ID}"
}

require_tools() {
  local tool
  for tool in aws jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "::error::Required command is unavailable: ${tool}"
      exit 1
    fi
  done
}

discover_vpc() {
  local response vpc
  response="$(aws_cli ec2 describe-vpcs --region "$MAIN_REGION" \
    --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
  vpc="$(jq -c '.Vpcs[0] // empty' <<< "$response")"
  if [[ -z "$vpc" ]]; then
    skip_resource "vpc" "$MAIN_REGION" "$TARGET_VPC_ID" "known Manara VPC is absent"
    return
  fi

  if ! is_owned "$vpc" "$TARGET_VPC_NAME" true; then
    fail_resource "vpc" "$MAIN_REGION" "$TARGET_VPC_ID" "VPC name or ownership tags do not match"
    return
  fi

  VPC_PRESENT=1
  add_plan "vpc" "$MAIN_REGION" "$TARGET_VPC_ID"
}

discover_compute_and_network() {
  local response item name id vpc_id service expected_name group_name arn
  local instance_ids template_id

  if [[ "$VPC_PRESENT" -eq 1 ]]; then
    response="$(aws_cli ec2 describe-vpc-endpoints --region "$MAIN_REGION" \
      --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      id="$(jq -r '.VpcEndpointId' <<< "$item")"
      service="$(jq -r '.ServiceName' <<< "$item")"
      name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
      case "$service" in
        "com.amazonaws.${MAIN_REGION}.ssm") expected_name="${NAME_PREFIX}-endpoint-ssm" ;;
        "com.amazonaws.${MAIN_REGION}.ssmmessages") expected_name="${NAME_PREFIX}-endpoint-ssmmessages" ;;
        "com.amazonaws.${MAIN_REGION}.ec2messages") expected_name="${NAME_PREFIX}-endpoint-ec2messages" ;;
        "com.amazonaws.${MAIN_REGION}.secretsmanager") expected_name="${NAME_PREFIX}-endpoint-secretsmanager" ;;
        "com.amazonaws.${MAIN_REGION}.monitoring") expected_name="${NAME_PREFIX}-endpoint-monitoring" ;;
        "com.amazonaws.${MAIN_REGION}.logs") expected_name="${NAME_PREFIX}-endpoint-logs" ;;
        *) skip_resource "vpc-endpoint" "$MAIN_REGION" "$id" "service is outside the Terraform allowlist" true; continue ;;
      esac
      if [[ "$(jq -r '.VpcId' <<< "$item")" != "$TARGET_VPC_ID" || "$name" != "$expected_name" ]]; then
        skip_resource "vpc-endpoint" "$MAIN_REGION" "$id" "endpoint name or VPC does not match" true
        continue
      fi
      add_named_if_owned "vpc-endpoint" "$MAIN_REGION" "$item" "$id" "$expected_name" true
      VPC_ENDPOINTS+=("$id")
    done < <(jq -c '.VpcEndpoints[]?' <<< "$response")

    response="$(aws_cli ec2 describe-subnets --region "$MAIN_REGION" \
      --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      id="$(jq -r '.SubnetId' <<< "$item")"
      name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
      if [[ "$name" =~ ^${NAME_PREFIX}-(public|private-app|private-db)-eu-west-3[ab]$ ]]; then
        add_named_if_owned "subnet" "$MAIN_REGION" "$item" "$id" "$name" true
        SUBNETS+=("$id")
      else
        skip_resource "subnet" "$MAIN_REGION" "$id" "subnet is not in the exact Manara subnet allowlist" true
      fi
    done < <(jq -c '.Subnets[]?' <<< "$response")

    response="$(aws_cli ec2 describe-route-tables --region "$MAIN_REGION" \
      --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      id="$(jq -r '.RouteTableId' <<< "$item")"
      if [[ "$(jq -r 'any(.Associations[]?; .Main == true)' <<< "$item")" == "true" ]]; then
        skip_resource "route-table" "$MAIN_REGION" "$id" "main route table is AWS-managed and must remain"
        continue
      fi
      name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
      if [[ "$name" =~ ^${NAME_PREFIX}-rt-(public|private-db|private-app-eu-west-3[ab])$ ]]; then
        add_named_if_owned "route-table" "$MAIN_REGION" "$item" "$id" "$name" true
        ROUTE_TABLES+=("$id")
        while IFS= read -r route; do
          [[ -n "$route" ]] || continue
          [[ "$(jq -r '.GatewayId // ""' <<< "$route")" == "local" ]] && continue
          local route_destination route_target
          route_destination="$(jq -r '.DestinationCidrBlock // .DestinationIpv6CidrBlock // .DestinationPrefixListId // ""' <<< "$route")"
          route_target="$(jq -r '.GatewayId // .NatGatewayId // ""' <<< "$route")"
          add_plan "route" "$MAIN_REGION" "${id},${route_destination},${route_target}"
        done < <(jq -c '.Routes[]?' <<< "$item")
        while IFS= read -r association; do
          [[ -n "$association" ]] || continue
          if [[ "$(jq -r '.Main // false' <<< "$association")" == "true" ]]; then
            continue
          fi
          local association_id association_subnet
          association_id="$(jq -r '.RouteTableAssociationId // ""' <<< "$association")"
          association_subnet="$(jq -r '.SubnetId // ""' <<< "$association")"
          if [[ -n "$association_id" && " ${SUBNETS[*]} " == *" ${association_subnet} "* ]]; then
            add_plan "route-table-association" "$MAIN_REGION" "$association_id"
          else
            skip_resource "route-table-association" "$MAIN_REGION" "${association_id:-$id}" \
              "association is not to a verified Manara subnet" true
          fi
        done < <(jq -c '.Associations[]?' <<< "$item")
      else
        skip_resource "route-table" "$MAIN_REGION" "$id" "route table is not in the exact Manara allowlist" true
      fi
    done < <(jq -c '.RouteTables[]?' <<< "$response")

    response="$(aws_cli ec2 describe-network-acls --region "$MAIN_REGION" \
      --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      id="$(jq -r '.NetworkAclId' <<< "$item")"
      if [[ "$(jq -r '.IsDefault' <<< "$item")" == "true" ]]; then
        skip_resource "network-acl" "$MAIN_REGION" "$id" "default network ACL is AWS-managed"
        continue
      fi
      name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
      if [[ "$name" =~ ^${NAME_PREFIX}-nacl-(public|private-app|private-db)$ ]]; then
        add_named_if_owned "network-acl" "$MAIN_REGION" "$item" "$id" "$name" true
        NETWORK_ACLS+=("$id")
      else
        skip_resource "network-acl" "$MAIN_REGION" "$id" "ACL is not in the exact Manara allowlist" true
      fi
    done < <(jq -c '.NetworkAcls[]?' <<< "$response")

    response="$(aws_cli ec2 describe-security-groups --region "$MAIN_REGION" \
      --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      id="$(jq -r '.GroupId' <<< "$item")"
      name="$(jq -r '.GroupName' <<< "$item")"
      case "$name" in
        "${NAME_PREFIX}-sg-alb"|"${NAME_PREFIX}-sg-app"|"${NAME_PREFIX}-sg-db"|"${NAME_PREFIX}-sg-vpc-endpoints")
          add_named_if_owned "security-group" "$MAIN_REGION" "$item" "$id" "$name" true
          SECURITY_GROUPS+=("$id")
          [[ "$name" != "${NAME_PREFIX}-sg-db" ]] || DB_SECURITY_GROUP_IDS+=("$id")
          [[ "$name" != "${NAME_PREFIX}-sg-alb" ]] || ALB_SECURITY_GROUP_IDS+=("$id")
          ;;
        default) skip_resource "security-group" "$MAIN_REGION" "$id" "default security group is AWS-managed" ;;
        *) skip_resource "security-group" "$MAIN_REGION" "$id" "security group is outside the exact Manara allowlist" true ;;
      esac
    done < <(jq -c '.SecurityGroups[]?' <<< "$response")

    response="$(aws_cli ec2 describe-internet-gateways --region "$MAIN_REGION" \
      --filters "Name=attachment.vpc-id,Values=${TARGET_VPC_ID}" --output json)"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      id="$(jq -r '.InternetGatewayId' <<< "$item")"
      name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
      if [[ "$name" == "${NAME_PREFIX}-igw" ]]; then
        add_named_if_owned "internet-gateway" "$MAIN_REGION" "$item" "$id" "$name" true
        INTERNET_GATEWAYS+=("$id")
      else
        skip_resource "internet-gateway" "$MAIN_REGION" "$id" "gateway is attached to the Manara VPC but not allowlisted" true
      fi
    done < <(jq -c '.InternetGateways[]?' <<< "$response")

    response="$(aws_cli ec2 describe-nat-gateways --region "$MAIN_REGION" \
      --filter "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      id="$(jq -r '.NatGatewayId' <<< "$item")"
      name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
      vpc_id="$(jq -r '.VpcId' <<< "$item")"
      if [[ "$vpc_id" == "$TARGET_VPC_ID" && "$name" =~ ^${NAME_PREFIX}-nat-[1-9][0-9]*$ ]]; then
        add_named_if_owned "nat-gateway" "$MAIN_REGION" "$item" "$id" "$name" true
        NAT_GATEWAYS+=("$id")
        while IFS= read -r arn; do
          [[ -z "$arn" ]] || NAT_EIPS+=("$arn")
        done < <(jq -r '.NatGatewayAddresses[]?.AllocationId' <<< "$item")
      else
        skip_resource "nat-gateway" "$MAIN_REGION" "$id" "not an allowlisted NAT in the Manara VPC" true
      fi
    done < <(jq -c '.NatGateways[]?' <<< "$response")
  fi

  # The explicitly identified NAT in another VPC is deliberately never eligible.
  response="$(aws_cli ec2 describe-nat-gateways --region "$MAIN_REGION" \
    --filter "Name=nat-gateway-id,Values=${EXTERNAL_NAT_ID}" --output json)"
  item="$(jq -c '.NatGateways[0] // empty' <<< "$response")"
  if [[ -n "$item" && "$(jq -r '.VpcId' <<< "$item")" == "$EXTERNAL_NAT_VPC" ]]; then
    skip_resource "nat-gateway" "$MAIN_REGION" "$EXTERNAL_NAT_ID" \
      "explicitly excluded: belongs to a different VPC"
  fi

  response="$(aws_cli autoscaling describe-auto-scaling-groups --region "$MAIN_REGION" \
    --auto-scaling-group-names "${NAME_PREFIX}-asg" --output json)"
  item="$(jq -c '.AutoScalingGroups[0] // empty' <<< "$response")"
  if [[ -n "$item" ]]; then
    group_name="$(jq -r '.AutoScalingGroupName' <<< "$item")"
    local subnet_csv
    subnet_csv="$(jq -r '.VPCZoneIdentifier // ""' <<< "$item")"
    local -a group_subnets=()
    IFS=',' read -r -a group_subnets <<< "$subnet_csv"
    if [[ -z "$subnet_csv" || "${#group_subnets[@]}" -eq 0 ]]; then
      skip_resource "autoscaling-group" "$MAIN_REGION" "$group_name" "ASG has no verifiable subnet association" true
    else
      local subnet_ids_json
      subnet_ids_json="$(printf '%s\n' "${group_subnets[@]}" | jq -R . | jq -s .)"
      local subnet_response
      subnet_response="$(aws_cli ec2 describe-subnets --region "$MAIN_REGION" \
        --subnet-ids "${group_subnets[@]}" --output json)"
      if [[ "$(jq -r --argjson ids "$subnet_ids_json" \
        '(.Subnets | length) == ($ids | length) and all(.Subnets[]; .VpcId == $vpc)' \
        --arg vpc "$TARGET_VPC_ID" <<< "$subnet_response")" == "true" ]]; then
        add_named_if_owned "autoscaling-group" "$MAIN_REGION" "$item" "$group_name" "$group_name" true
        AUTOSCALING_GROUPS+=("$group_name")
        instance_ids="$(jq -r '.AutoScalingGroups[0].Instances[]?.InstanceId' <<< "$response")"
        while IFS= read -r id; do
          [[ -z "$id" ]] || add_plan "asg-instance" "$MAIN_REGION" "$id"
        done <<< "$instance_ids"

        local policy_response policy
        policy_response="$(aws_cli autoscaling describe-policies --region "$MAIN_REGION" \
          --auto-scaling-group-name "$group_name" --output json)"
        while IFS= read -r policy; do
          [[ -n "$policy" ]] || continue
          name="$(jq -r '.PolicyName' <<< "$policy")"
          if [[ "$name" == "${NAME_PREFIX}-asg-cpu-tracking" || "$name" == "${NAME_PREFIX}-asg-alb-request-tracking" ]]; then
            add_plan "autoscaling-policy" "$MAIN_REGION" "${group_name},${name}"
          else
            skip_resource "autoscaling-policy" "$MAIN_REGION" "$name" "policy is attached to the allowlisted ASG but not name-allowlisted" true
          fi
        done < <(jq -c '.ScalingPolicies[]?' <<< "$policy_response")

        template_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // ""' <<< "$response")"
        if [[ -n "$template_id" ]]; then
          local lt_response lt_name
          lt_response="$(aws_cli ec2 describe-launch-templates --region "$MAIN_REGION" \
            --launch-template-ids "$template_id" --output json)"
          lt_name="$(jq -r '.LaunchTemplates[0].LaunchTemplateName // ""' <<< "$lt_response")"
          if [[ "$lt_name" == "${NAME_PREFIX}-lt-"* ]]; then
            add_plan "launch-template" "$MAIN_REGION" "$template_id"
          else
            skip_resource "launch-template" "$MAIN_REGION" "$template_id" "ASG launch template name is not allowlisted" true
          fi
        fi
      else
        skip_resource "autoscaling-group" "$MAIN_REGION" "$group_name" "ASG subnets are not all in the verified Manara VPC" true
      fi
    fi
  fi

  if [[ "$VPC_PRESENT" -eq 1 ]]; then
    response="$(aws_cli ec2 describe-instances --region "$MAIN_REGION" \
      --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" --output json)"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      id="$(jq -r '.InstanceId' <<< "$item")"
      name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
      group_name="$(jq -r '[.Tags[]? | select(.Key=="aws:autoscaling:groupName") | .Value][0] // ""' <<< "$item")"
      if [[ "$group_name" == "${NAME_PREFIX}-asg" && ${#AUTOSCALING_GROUPS[@]} -gt 0 ]]; then
        # The verified ASG operation terminates its own instances.
        continue
      elif [[ "$name" == "${NAME_PREFIX}-app-instance" ]]; then
        add_named_if_owned "ec2-instance" "$MAIN_REGION" "$item" "$id" "$name" true
      else
        skip_resource "ec2-instance" "$MAIN_REGION" "$id" "instance in Manara VPC is not in the exact project allowlist" true
      fi
    done < <(jq -c '.Reservations[]?.Instances[]?' <<< "$response")
  fi

  response="$(aws_cli ec2 describe-volumes --region "$MAIN_REGION" \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-app-volume" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    id="$(jq -r '.VolumeId' <<< "$item")"
    name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
    [[ "$name" == "${NAME_PREFIX}-app-volume" ]] || continue
    if ! is_owned "$item" "$name" true; then
      skip_resource "ebs-volume" "$MAIN_REGION" "$id" "volume ownership tags conflict" true
      continue
    fi

    local attachment_instance instance_response instance_object instance_name instance_asg
    local instance_vpc instance_owned attachment_owned
    attachment_owned=true
    while IFS= read -r attachment_instance; do
      [[ -n "$attachment_instance" ]] || continue
      if ! instance_response="$(aws_cli ec2 describe-instances --region "$MAIN_REGION" \
        --instance-ids "$attachment_instance" --output json 2>&1)"; then
        attachment_owned=false
        break
      fi
      instance_object="$(jq -c '.Reservations[]?.Instances[]? | select(.InstanceId == $id)' \
        --arg id "$attachment_instance" <<< "$instance_response")"
      instance_name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$instance_object")"
      instance_asg="$(jq -r '[.Tags[]? | select(.Key=="aws:autoscaling:groupName") | .Value][0] // ""' <<< "$instance_object")"
      instance_vpc="$(jq -r '.VpcId // ""' <<< "$instance_object")"
      instance_owned=false
      if [[ "$instance_name" == "${NAME_PREFIX}-app-instance" ]] &&
         is_owned "$instance_object" "${NAME_PREFIX}-app-instance" true; then
        instance_owned=true
      elif [[ "$instance_asg" == "${NAME_PREFIX}-asg" && ${#AUTOSCALING_GROUPS[@]} -gt 0 ]] &&
           is_owned "$instance_object" "${NAME_PREFIX}-app-instance" true; then
        instance_owned=true
      fi
      if [[ "$instance_vpc" != "$TARGET_VPC_ID" || "$instance_owned" != true ]]; then
        attachment_owned=false
        break
      fi
    done < <(jq -r '.Attachments[]?.InstanceId' <<< "$item")

    if [[ "$attachment_owned" == true ]]; then
      add_plan "ebs-volume" "$MAIN_REGION" "$id"
    else
      skip_resource "ebs-volume" "$MAIN_REGION" "$id" \
        "volume is attached to an instance not verified as Manara-owned" true
    fi
  done < <(jq -c '.Volumes[]?' <<< "$response")

  response="$(aws_cli ec2 describe-addresses --region "$MAIN_REGION" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    id="$(jq -r '.AllocationId // ""' <<< "$item")"
    name="$(jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""' <<< "$item")"
    [[ "$name" =~ ^${NAME_PREFIX}-nat-eip-[1-9][0-9]*$ ]] || continue
    local eni_id nat_owned association_id
    eni_id="$(jq -r '.NetworkInterfaceId // ""' <<< "$item")"
    association_id="$(jq -r '.AssociationId // ""' <<< "$item")"
    nat_owned="false"
    for arn in "${NAT_EIPS[@]}"; do
      [[ "$arn" != "$id" ]] || nat_owned="true"
    done
    if [[ "$nat_owned" == "true" || ( -z "$eni_id" && -z "$association_id" ) ]]; then
      add_named_if_owned "elastic-ip" "$MAIN_REGION" "$item" "$id" "$name" true
    else
      skip_resource "elastic-ip" "$MAIN_REGION" "$id" "address is not verifiably associated with Manara NAT" true
    fi
  done < <(jq -c '.Addresses[]?' <<< "$response")

  discover_launch_templates
}

discover_launch_templates() {
  local response item id name tags asg_response asg outside_group ref_id
  response="$(aws_cli ec2 describe-launch-templates --region "$MAIN_REGION" --output json)"
  asg_response="$(aws_cli autoscaling describe-auto-scaling-groups --region "$MAIN_REGION" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    id="$(jq -r '.LaunchTemplateId' <<< "$item")"
    name="$(jq -r '.LaunchTemplateName' <<< "$item")"
    [[ "$name" == "${NAME_PREFIX}-lt-"* ]] || continue
    tags="$(jq -c '{Tags: (.Tags // [])}' <<< "$item")"
    if ! is_owned "$tags" "$name" true; then
      skip_resource "launch-template" "$MAIN_REGION" "$id" \
        "launch template ownership tags conflict or cannot be verified" true
      continue
    fi

    outside_group=""
    while IFS= read -r asg; do
      [[ -n "$asg" ]] || continue
      ref_id="$(jq -r '.LaunchTemplate.LaunchTemplateId // .MixedInstancesPolicy.LaunchTemplate.LaunchTemplateSpecification.LaunchTemplateId // ""' <<< "$asg")"
      if [[ "$ref_id" == "$id" ]]; then
        name="$(jq -r '.AutoScalingGroupName' <<< "$asg")"
        if [[ "$name" != "${NAME_PREFIX}-asg" ]]; then
          outside_group="$name"
          break
        fi
      fi
    done < <(jq -c '.AutoScalingGroups[]?' <<< "$asg_response")

    if [[ -n "$outside_group" ]]; then
      skip_resource "launch-template" "$MAIN_REGION" "$id" \
        "referenced by non-Manara Auto Scaling group ${outside_group}" true
      continue
    fi
    add_plan "launch-template" "$MAIN_REGION" "$id"
  done < <(jq -c '.LaunchTemplates[]?' <<< "$response")
}

validate_route_tables() {
  local route_table_id response route destination target association subnet_id association_id
  for route_table_id in "${ROUTE_TABLES[@]}"; do
    response="$(aws_cli ec2 describe-route-tables --region "$MAIN_REGION" \
      --route-table-ids "$route_table_id" --output json)"
    while IFS= read -r route; do
      [[ -n "$route" ]] || continue
      [[ "$(jq -r '.GatewayId // ""' <<< "$route")" == "local" ]] && continue
      destination="$(jq -r '.DestinationCidrBlock // .DestinationIpv6CidrBlock // .DestinationPrefixListId // ""' <<< "$route")"
      target="$(jq -r '.GatewayId // .NatGatewayId // ""' <<< "$route")"
      if [[ "$destination" != "0.0.0.0/0" || -z "$target" ]] ||
         ! printf '%s\n' "${INTERNET_GATEWAYS[@]}" "${NAT_GATEWAYS[@]}" | grep -Fxq "$target"; then
        skip_resource "route" "$MAIN_REGION" "${route_table_id},${destination},${target}" \
          "route is not the Terraform default route through an allowlisted gateway" true
      fi
    done < <(jq -c '.RouteTables[0].Routes[]?' <<< "$response")

    while IFS= read -r association; do
      [[ -n "$association" ]] || continue
      [[ "$(jq -r '.Main // false' <<< "$association")" != "true" ]] || continue
      subnet_id="$(jq -r '.SubnetId // ""' <<< "$association")"
      association_id="$(jq -r '.RouteTableAssociationId // ""' <<< "$association")"
      if [[ -z "$subnet_id" || " ${SUBNETS[*]} " != *" ${subnet_id} "* ]]; then
        skip_resource "route-table-association" "$MAIN_REGION" "${association_id:-$route_table_id}" \
          "association is not to a verified Manara subnet" true
      fi
    done < <(jq -c '.RouteTables[0].Associations[]?' <<< "$response")
  done
}

discover_load_balancer() {
  local response item id vpc name tags listener_response listener rule_response rule
  local listener_arn listener_tags listener_name listener_port listener_protocol rule_arn rule_tags rule_name
  response="$(aws_cli elbv2 describe-load-balancers --region "$MAIN_REGION" --output json)"
  item="$(jq -c --arg name "${NAME_PREFIX}-alb" \
    'first(.LoadBalancers[]? | select(.LoadBalancerName == $name)) // empty' <<< "$response")"
  if [[ -z "$item" ]]; then
    skip_resource "load-balancer" "$MAIN_REGION" "${NAME_PREFIX}-alb" "not found"
  else
    id="$(jq -r '.LoadBalancerArn' <<< "$item")"
    vpc="$(jq -r '.VpcId' <<< "$item")"
    name="$(jq -r '.LoadBalancerName' <<< "$item")"
    if [[ "$vpc" != "$TARGET_VPC_ID" || "$name" != "${NAME_PREFIX}-alb" ]]; then
      fail_resource "load-balancer" "$MAIN_REGION" "$id" "name or VPC ownership check failed"
      return
    fi
    tags="$(aws_cli elbv2 describe-tags --region "$MAIN_REGION" \
      --resource-arns "$id" --output json | jq -c '.TagDescriptions[0] // {}')"
    add_named_if_owned "load-balancer" "$MAIN_REGION" "$tags" "$id" "$name" true
    LOAD_BALANCERS+=("$id")
    ALB_DNS="$(jq -r '.DNSName' <<< "$item")"

    listener_response="$(aws_cli elbv2 describe-listeners --region "$MAIN_REGION" \
      --load-balancer-arn "$id" --output json)"
    while IFS= read -r listener; do
      [[ -n "$listener" ]] || continue
      listener_arn="$(jq -r '.ListenerArn' <<< "$listener")"
      listener_port="$(jq -r '.Port // 0' <<< "$listener")"
      listener_protocol="$(jq -r '.Protocol // ""' <<< "$listener")"
      listener_tags="$(aws_cli elbv2 describe-tags --region "$MAIN_REGION" \
        --resource-arns "$listener_arn" --output json | jq -c '.TagDescriptions[0] // {}')"
      listener_name="$(tag_value "$(normalize_tags "$listener_tags")" Name)"
      if [[ "$listener_port" == "80" && "$listener_protocol" == "HTTP" &&
            "$listener_name" == "${NAME_PREFIX}-listener-http" ]] &&
         is_owned "$listener_tags" "${NAME_PREFIX}-listener-http" true; then
        add_plan "listener" "$MAIN_REGION" "$listener_arn"
      else
        skip_resource "listener" "$MAIN_REGION" "$listener_arn" \
          "listener identity does not match the Terraform HTTP listener" true
        continue
      fi
      rule_response="$(aws_cli elbv2 describe-rules --region "$MAIN_REGION" \
        --listener-arn "$listener_arn" --output json)"
      while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        if [[ "$(jq -r '.IsDefault' <<< "$rule")" != "true" ]]; then
          rule_arn="$(jq -r '.RuleArn' <<< "$rule")"
          rule_tags="$(aws_cli elbv2 describe-tags --region "$MAIN_REGION" \
            --resource-arns "$rule_arn" --output json | jq -c '.TagDescriptions[0] // {}')"
          rule_name="$(tag_value "$(normalize_tags "$rule_tags")" Name)"
          if [[ "$rule_name" == "${NAME_PREFIX}-rule-http-dev" ]] &&
             is_owned "$rule_tags" "${NAME_PREFIX}-rule-http-dev" true; then
            add_plan "listener-rule" "$MAIN_REGION" "$rule_arn"
          else
            skip_resource "listener-rule" "$MAIN_REGION" "$rule_arn" \
              "listener rule identity does not match the Terraform dev-forward rule" true
          fi
        fi
      done < <(jq -c '.Rules[]?' <<< "$rule_response")
    done < <(jq -c '.Listeners[]?' <<< "$listener_response")
  fi

  response="$(aws_cli elbv2 describe-target-groups --region "$MAIN_REGION" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    id="$(jq -r '.TargetGroupArn' <<< "$item")"
    name="$(jq -r '.TargetGroupName' <<< "$item")"
    [[ "$name" == "${NAME_PREFIX}-tg-app" ]] || continue
    vpc="$(jq -r '.VpcId' <<< "$item")"
    local associated
    associated="$(jq -r '[.LoadBalancerArns[]?] | join(",")' <<< "$item")"
    if [[ "$name" != "${NAME_PREFIX}-tg-app" || "$vpc" != "$TARGET_VPC_ID" ]]; then
      fail_resource "target-group" "$MAIN_REGION" "$id" "name or VPC ownership check failed"
    elif [[ -n "$associated" && "$associated" != "${LOAD_BALANCERS[0]:-}" ]]; then
      skip_resource "target-group" "$MAIN_REGION" "$id" "associated with a load balancer outside the Manara allowlist" true
    else
      tags="$(aws_cli elbv2 describe-tags --region "$MAIN_REGION" \
        --resource-arns "$id" --output json | jq -c '.TagDescriptions[0] // {}')"
      add_named_if_owned "target-group" "$MAIN_REGION" "$tags" "$id" "$name" true
      TARGET_GROUPS+=("$id")
    fi
  done < <(jq -c '.TargetGroups[]?' <<< "$response")
}

discover_databases_and_logs() {
  local response item id name tags region arn
  response="$(aws_cli rds describe-db-instances --region "$MAIN_REGION" --output json)"
  item="$(jq -c --arg name "${NAME_PREFIX}-postgres" \
    'first(.DBInstances[]? | select(.DBInstanceIdentifier == $name)) // empty' <<< "$response")"
  if [[ -n "$item" ]]; then
    id="$(jq -r '.DBInstanceIdentifier' <<< "$item")"
    if [[ "$(jq -r '.DBSubnetGroup.VpcId // ""' <<< "$item")" != "$TARGET_VPC_ID" ]]; then
      fail_resource "rds-instance" "$MAIN_REGION" "$id" "DB subnet group does not belong to the verified VPC"
    else
      arn="$(jq -r '.DBInstanceArn' <<< "$item")"
      tags="$(aws_cli rds list-tags-for-resource --region "$MAIN_REGION" \
        --resource-name "$arn" --output json)"
      add_named_if_owned "rds-instance" "$MAIN_REGION" "$tags" "$id" "$id" true
      RDS_INSTANCES+=("$id")
    fi
  fi

  response="$(aws_cli rds describe-db-subnet-groups --region "$MAIN_REGION" --output json)"
  item="$(jq -c --arg name "${NAME_PREFIX}-db-subnet-group" \
    'first(.DBSubnetGroups[]? | select(.DBSubnetGroupName == $name)) // empty' <<< "$response")"
  if [[ -n "$item" ]]; then
    id="$(jq -r '.DBSubnetGroupName' <<< "$item")"
    if [[ "$(jq -r '.VpcId' <<< "$item")" == "$TARGET_VPC_ID" ]]; then
      while IFS= read -r subnet_id; do
        [[ -z "$subnet_id" ]] || DB_SUBNET_IDS+=("$subnet_id")
      done < <(jq -r '.Subnets[]?.SubnetIdentifier' <<< "$item")
      tags="$(aws_cli rds list-tags-for-resource --region "$MAIN_REGION" \
        --resource-name "$(jq -r '.DBSubnetGroupArn' <<< "$item")" --output json)"
      add_named_if_owned "rds-subnet-group" "$MAIN_REGION" "$tags" "$id" "$id" true
    else
      fail_resource "rds-subnet-group" "$MAIN_REGION" "$id" "subnet group belongs to another VPC"
    fi
  fi

  response="$(aws_cli rds describe-db-parameter-groups --region "$MAIN_REGION" --output json)"
  item="$(jq -c --arg name "${NAME_PREFIX}-pg16-params" \
    'first(.DBParameterGroups[]? | select(.DBParameterGroupName == $name)) // empty' <<< "$response")"
  if [[ -n "$item" ]]; then
    id="$(jq -r '.DBParameterGroupName' <<< "$item")"
    arn="$(jq -r '.DBParameterGroupArn // ""' <<< "$item")"
    tags='{}'
    if [[ -n "$arn" ]]; then
      tags="$(aws_cli rds list-tags-for-resource --region "$MAIN_REGION" \
        --resource-name "$arn" --output json)"
    fi
    add_named_if_owned "rds-parameter-group" "$MAIN_REGION" "$tags" "$id" "$id" true
  fi

  response="$(aws_cli secretsmanager list-secrets --region "$MAIN_REGION" \
    --filters "Key=name,Values=${NAME_PREFIX}-db-credentials" --output json)"
  item="$(jq -c --arg name "${NAME_PREFIX}-db-credentials" \
    'first(.SecretList[]? | select(.Name == $name)) // empty' <<< "$response")"
  if [[ -n "$item" ]]; then
    id="$(jq -r '.ARN' <<< "$item")"
    add_named_if_owned "secret" "$MAIN_REGION" "$item" "$id" "${NAME_PREFIX}-db-credentials" true
  fi

  local -a log_groups=(
    "/aws/ec2/${NAME_PREFIX}/application"
    "/aws/ec2/${NAME_PREFIX}/access"
    "/aws/ec2/${NAME_PREFIX}/user-data"
    "/aws/rds/instance/${NAME_PREFIX}-postgres/postgresql"
    "/aws/rds/instance/${NAME_PREFIX}-postgres/upgrade"
  )
  for name in "${log_groups[@]}"; do
    response="$(aws_cli logs describe-log-groups --region "$MAIN_REGION" \
      --log-group-name-prefix "$name" --output json)"
    item="$(jq -c --arg name "$name" 'first(.logGroups[]? | select(.logGroupName == $name)) // empty' <<< "$response")"
    if [[ -n "$item" ]]; then
      local log_group_arn
      log_group_arn="arn:aws:logs:${MAIN_REGION}:${EXPECTED_ACCOUNT_ID}:log-group:${name}"
      tags="$(aws_cli logs list-tags-for-resource --region "$MAIN_REGION" \
        --resource-arn "$log_group_arn" --output json)"
      add_named_if_owned "log-group" "$MAIN_REGION" "$tags" "$name" "$name" true
    fi
  done

  local -a alarm_names=(
    "${NAME_PREFIX}-high-cpu"
    "${NAME_PREFIX}-alb-5xx-errors"
    "${NAME_PREFIX}-unhealthy-targets"
    "${NAME_PREFIX}-rds-high-cpu"
    "${NAME_PREFIX}-rds-low-storage"
  )
  response="$(aws_cli cloudwatch describe-alarms --region "$MAIN_REGION" \
    --alarm-names "${alarm_names[@]}" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    name="$(jq -r '.AlarmName' <<< "$item")"
    arn="$(jq -r '.AlarmArn' <<< "$item")"
    tags="$(aws_cli cloudwatch list-tags-for-resource --region "$MAIN_REGION" \
      --resource-arn "$arn" --output json)"
    add_named_if_owned "alarm" "$MAIN_REGION" "$tags" "$name" "$name" true
  done < <(jq -c '.MetricAlarms[]?' <<< "$response")

  name="${NAME_PREFIX}-dashboard"
  response="$(aws_cli cloudwatch list-dashboards --region "$MAIN_REGION" --output json)"
  item="$(jq -c --arg name "$name" 'first(.DashboardEntries[]? | select(.DashboardName == $name)) // empty' <<< "$response")"
  if [[ -n "$item" ]]; then
    arn="$(jq -r '.DashboardArn' <<< "$item")"
    tags="$(aws_cli cloudwatch list-tags-for-resource --region "$MAIN_REGION" \
      --resource-arn "$arn" --output json)"
    add_named_if_owned "dashboard" "$MAIN_REGION" "$tags" "$name" "$name" true
  fi
}

discover_global_and_waf() {
  local response item id name arn scope region tags role_json trust profile_json

  response="$(aws_cli wafv2 list-web-acls --scope REGIONAL --region "$MAIN_REGION" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    name="$(jq -r '.Name' <<< "$item")"
    [[ "$name" == "${NAME_PREFIX}-waf-regional" ]] || continue
    id="$(jq -r '.Id' <<< "$item")"
    arn="$(jq -r '.ARN' <<< "$item")"
    tags="$(aws_cli wafv2 list-tags-for-resource --scope REGIONAL --region "$MAIN_REGION" \
      --resource-arn "$arn" --output json)"
    if is_owned "$tags" "$name" true; then
      add_plan "waf-regional" "$MAIN_REGION" "${id},${name},${arn}"
      WAF_REGIONAL+=("$arn")
    else
      skip_resource "waf-regional" "$MAIN_REGION" "$arn" "ownership tags conflict" true
    fi
  done < <(jq -c '.WebACLs[]?' <<< "$response")

  response="$(aws_cli wafv2 list-web-acls --scope CLOUDFRONT --region "$GLOBAL_REGION" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    name="$(jq -r '.Name' <<< "$item")"
    [[ "$name" == "${NAME_PREFIX}-waf-cf" ]] || continue
    id="$(jq -r '.Id' <<< "$item")"
    arn="$(jq -r '.ARN' <<< "$item")"
    tags="$(aws_cli wafv2 list-tags-for-resource --scope CLOUDFRONT --region "$GLOBAL_REGION" \
      --resource-arn "$arn" --output json)"
    if is_owned "$tags" "$name" true; then
      add_plan "waf-cloudfront" "$GLOBAL_REGION" "${id},${name},${arn}"
      WAF_CLOUDFRONT+=("$arn")
    else
      skip_resource "waf-cloudfront" "$GLOBAL_REGION" "$arn" "ownership tags conflict" true
    fi
  done < <(jq -c '.WebACLs[]?' <<< "$response")

  response="$(aws_cli cloudfront list-distributions --region "$GLOBAL_REGION" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    id="$(jq -r '.Id' <<< "$item")"
    local comment origin_owns
    comment="$(jq -r '.Comment // ""' <<< "$item")"
    [[ "$comment" == "${NAME_PREFIX} CloudFront distribution" ]] || continue
    origin_owns="true"
    if [[ -n "$ALB_DNS" ]]; then
      origin_owns="$(jq -r --arg dns "$ALB_DNS" 'any(.Origins.Items[]?; .DomainName == $dns)' <<< "$item")"
    fi
    if [[ "$origin_owns" != "true" ]]; then
      skip_resource "cloudfront-distribution" "$GLOBAL_REGION" "$id" "expected Manara ALB origin could not be verified" true
      continue
    fi
    arn="$(jq -r '.ARN' <<< "$item")"
    tags="$(aws_cli cloudfront list-tags-for-resource --region "$GLOBAL_REGION" \
      --resource "$arn" --output json)"
    if is_owned "$tags" "${NAME_PREFIX}-cf" true; then
      add_plan "cloudfront-distribution" "$GLOBAL_REGION" "$id"
      CLOUDFRONT_DISTRIBUTIONS+=("$id")
    else
      skip_resource "cloudfront-distribution" "$GLOBAL_REGION" "$id" "ownership tags conflict" true
    fi
  done < <(jq -c '.DistributionList.Items[]?' <<< "$response")

  local -a iam_role_names=(
    "${NAME_PREFIX}-ec2-role"
    "${NAME_PREFIX}-rds-monitoring-role"
  )
  for name in "${iam_role_names[@]}"; do
    role_json="$(aws_cli iam list-roles --output json)"
    item="$(jq -c --arg name "$name" 'first(.Roles[]? | select(.RoleName == $name)) // empty' <<< "$role_json")"
    [[ -n "$item" ]] || continue
    trust="$(jq -r '[.AssumeRolePolicyDocument.Statement[]?.Principal.Service // empty] | join(",")' <<< "$item")"
    if [[ "$name" == "${NAME_PREFIX}-ec2-role" && "$trust" != *"ec2.amazonaws.com"* ]]; then
      skip_resource "iam-role" "global" "$name" "trust policy is not the expected EC2 service" true
      continue
    fi
    if [[ "$name" == "${NAME_PREFIX}-rds-monitoring-role" && "$trust" != *"monitoring.rds.amazonaws.com"* ]]; then
      skip_resource "iam-role" "global" "$name" "trust policy is not the expected RDS monitoring service" true
      continue
    fi
    if is_owned "$item" "$name" true; then
      add_plan "iam-role" "global" "$name"
      IAM_ROLES+=("$name")
      profile_json="$(aws_cli iam list-instance-profiles-for-role --role-name "$name" --output json)"
      while IFS= read -r profile_json_item; do
        [[ -n "$profile_json_item" ]] || continue
        local profile_name
        profile_name="$(jq -r '.InstanceProfileName' <<< "$profile_json_item")"
        if [[ "$profile_name" == "${NAME_PREFIX}-ec2-instance-profile" ]]; then
          add_plan "iam-profile" "global" "$profile_name"
          IAM_PROFILES+=("$profile_name")
        else
          skip_resource "iam-profile" "global" "$profile_name" "profile attached to Manara role but not allowlisted" true
        fi
      done < <(jq -c '.InstanceProfiles[]?' <<< "$profile_json")

      local inline_response attached_response policy_name policy_arn unknown_policy
      inline_response="$(aws_cli iam list-role-policies --role-name "$name" --output json)"
      while IFS= read -r policy_name; do
      [[ -n "$policy_name" ]] || continue
      if [[ "$policy_name" == "${NAME_PREFIX}-secrets-read" || "$policy_name" == "${NAME_PREFIX}-ssm-params-read" ]]; then
        add_plan "iam-inline-policy" "global" "${name},${policy_name}"
      else
        skip_resource "iam-inline-policy" "global" "$policy_name" "role has a policy outside the Manara allowlist" true
      fi
      done < <(jq -r '.PolicyNames[]?' <<< "$inline_response")

      attached_response="$(aws_cli iam list-attached-role-policies --role-name "$name" --output json)"
      while IFS= read -r policy_arn; do
      [[ -n "$policy_arn" ]] || continue
      case "$policy_arn" in
        arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore|\
        arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy|\
        arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole)
          add_plan "iam-attached-policy" "global" "${name},${policy_arn}"
          ;;
        *)
          skip_resource "iam-attached-policy" "global" "$policy_arn" "role has a policy outside the Manara allowlist" true
          ;;
      esac
      done < <(jq -r '.AttachedPolicies[]?.PolicyArn' <<< "$attached_response")
    else
      skip_resource "iam-role" "global" "$name" "ownership tags conflict" true
    fi
  done

  response="$(aws_cli sns list-topics --region "$MAIN_REGION" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    arn="$(jq -r '.TopicArn' <<< "$item")"
    [[ "$arn" == "arn:aws:sns:${MAIN_REGION}:${EXPECTED_ACCOUNT_ID}:${NAME_PREFIX}-alerts" ]] || continue
    tags="$(aws_cli sns list-tags-for-resource --region "$MAIN_REGION" \
      --resource-arn "$arn" --output json)"
    if is_owned "$tags" "${NAME_PREFIX}-alerts" true; then
      add_plan "sns-topic" "$MAIN_REGION" "$arn"
      local subscriptions subscription subscription_arn protocol
      subscriptions="$(aws_cli sns list-subscriptions-by-topic --region "$MAIN_REGION" \
        --topic-arn "$arn" --output json)"
      while IFS= read -r subscription; do
        [[ -n "$subscription" ]] || continue
        subscription_arn="$(jq -r '.SubscriptionArn // ""' <<< "$subscription")"
        protocol="$(jq -r '.Protocol // ""' <<< "$subscription")"
        if [[ "$subscription_arn" == "PendingConfirmation" ]]; then
          skip_resource "sns-subscription" "$MAIN_REGION" "$arn" \
            "pending subscription will be removed with the verified Manara topic"
        elif [[ "$protocol" == "email" && "$subscription_arn" == arn:aws:sns:* ]]; then
          add_plan "sns-subscription" "$MAIN_REGION" "$subscription_arn"
        else
          skip_resource "sns-subscription" "$MAIN_REGION" "$subscription_arn" \
            "subscription is not the Terraform-managed email subscription" true
        fi
      done < <(jq -c '.Subscriptions[]?' <<< "$subscriptions")
    else
      skip_resource "sns-topic" "$MAIN_REGION" "$arn" "ownership tags conflict" true
    fi
  done < <(jq -c '.Topics[]?' <<< "$response")

  # Terraform creates ACM/Route53 resources only when domain_name is set.
  # DNS records have no ownership tags; fail closed rather than guess which
  # hosted-zone records are safe to remove.
  response="$(aws_cli acm list-certificates --region "$GLOBAL_REGION" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    arn="$(jq -r '.CertificateArn' <<< "$item")"
    local cert_tags
    cert_tags="$(aws_cli acm list-tags-for-certificate --region "$GLOBAL_REGION" \
      --certificate-arn "$arn" --output json)"
    local cert_name
    cert_name="$(tag_value "$(normalize_tags "$cert_tags")" Name)"
    if [[ "$cert_name" == "${NAME_PREFIX}-acm-cert" ]] ||
       is_owned "$cert_tags" "${NAME_PREFIX}-acm-cert" false; then
      unsupported_resource "acm-route53" "$GLOBAL_REGION" "$arn" \
        "optional domain certificate and associated Route 53 records require manual DNS ownership review"
    fi
  done < <(jq -c '.CertificateSummaryList[]?' <<< "$response")
}

discover_network_interfaces() {
  [[ "$VPC_PRESENT" -eq 1 ]] || return 0

  local response item id interface_type description requester_managed
  local parent_id subnet_id group_id id_candidate owned parent_instance row kind region identifier
  response="$(aws_cli ec2 describe-network-interfaces --region "$MAIN_REGION" \
    --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    id="$(jq -r '.NetworkInterfaceId' <<< "$item")"
    interface_type="$(jq -r '.InterfaceType // ""' <<< "$item")"
    description="$(jq -r '.Description // ""' <<< "$item")"
    requester_managed="$(jq -r '.RequesterManaged // false' <<< "$item")"
    subnet_id="$(jq -r '.SubnetId // ""' <<< "$item")"
    owned=false

    if [[ "$requester_managed" == "true" && "$interface_type" == "vpc_endpoint" &&
          "$description" == "VPC Endpoint Interface "* ]]; then
      parent_id="${description#VPC Endpoint Interface }"
      for id_candidate in "${VPC_ENDPOINTS[@]}"; do
        [[ "$parent_id" != "$id_candidate" ]] || owned=true
      done
    elif [[ "$requester_managed" == "true" && "$interface_type" == "nat_gateway" &&
            "$description" == "Interface for NAT Gateway "* ]]; then
      parent_id="${description#Interface for NAT Gateway }"
      for id_candidate in "${NAT_GATEWAYS[@]}"; do
        [[ "$parent_id" != "$id_candidate" ]] || owned=true
      done
    elif [[ "$requester_managed" == "true" && "$interface_type" == "interface" &&
            "$description" == "ELB app/${NAME_PREFIX}-alb/"* &&
            ${#LOAD_BALANCERS[@]} -gt 0 ]]; then
      while IFS= read -r group_id; do
        for id_candidate in "${ALB_SECURITY_GROUP_IDS[@]}"; do
          [[ "$group_id" != "$id_candidate" ]] || owned=true
        done
      done < <(jq -r '.Groups[]?.GroupId' <<< "$item")
    elif [[ "$requester_managed" == "true" && "$interface_type" == "interface" &&
            "$description" == "RDSNetworkInterface" && ${#RDS_INSTANCES[@]} -gt 0 ]]; then
      local subnet_owned group_owned
      subnet_owned=false
      group_owned=false
      for id_candidate in "${DB_SUBNET_IDS[@]}"; do
        [[ "$subnet_id" != "$id_candidate" ]] || subnet_owned=true
      done
      while IFS= read -r group_id; do
        for id_candidate in "${DB_SECURITY_GROUP_IDS[@]}"; do
          [[ "$group_id" != "$id_candidate" ]] || group_owned=true
        done
      done < <(jq -r '.Groups[]?.GroupId' <<< "$item")
      [[ "$subnet_owned" != true || "$group_owned" != true ]] || owned=true
    else
      parent_instance="$(jq -r '.Attachment.InstanceId // ""' <<< "$item")"
      if [[ -n "$parent_instance" ]]; then
        for row in "${PLAN[@]}"; do
          IFS=$'\t' read -r kind region identifier <<< "$row"
          if [[ ( "$kind" == "ec2-instance" || "$kind" == "asg-instance" ) &&
                "$identifier" == "$parent_instance" ]]; then
            owned=true
          fi
        done
      fi
    fi

    if [[ "$owned" == true ]]; then
      MANAGED_ENIS+=("$id")
      add_plan "network-interface" "$MAIN_REGION" "$id"
    else
      skip_resource "network-interface" "$MAIN_REGION" "$id" \
        "ENI owner is not verified; it will not be detached or deleted" true
    fi
  done < <(jq -c '.NetworkInterfaces[]?' <<< "$response")
}

discover_associations() {
  local lb response waf_arn distribution config web_acl
  for lb in "${LOAD_BALANCERS[@]}"; do
    if ! response="$(aws_cli wafv2 get-web-acl-for-resource --region "$MAIN_REGION" \
      --resource-arn "$lb" --output json 2>&1)"; then
      if [[ "$response" == *"WAFNonexistentItemException"* ]]; then
        continue
      fi
      fail_resource "waf-association" "$MAIN_REGION" "$lb" \
        "could not verify whether a WebACL is associated"
      continue
    fi
    waf_arn="$(jq -r '.WebACL.ARN // ""' <<< "$response")"
    [[ -n "$waf_arn" ]] || continue
    if printf '%s\n' "${WAF_REGIONAL[@]}" | grep -Fxq "$waf_arn"; then
      add_plan "waf-association" "$MAIN_REGION" "$lb"
    else
      fail_resource "waf-association" "$MAIN_REGION" "$lb" \
        "associated WebACL is outside the Manara allowlist"
    fi
  done

  for distribution in "${CLOUDFRONT_DISTRIBUTIONS[@]}"; do
    config="$(aws_cli cloudfront get-distribution-config --region "$GLOBAL_REGION" \
      --id "$distribution" --output json)"
    web_acl="$(jq -r '.DistributionConfig.WebACLId // ""' <<< "$config")"
    [[ -n "$web_acl" ]] || continue
    if printf '%s\n' "${WAF_CLOUDFRONT[@]}" | grep -Fxq "$web_acl"; then
      add_plan "cloudfront-waf-association" "$GLOBAL_REGION" "$distribution"
    else
      skip_resource "cloudfront-waf-association" "$GLOBAL_REGION" "$distribution" \
        "distribution references a non-Manara WebACL; it will not be modified"
    fi
  done
}

print_inventory() {
  log ""
  log "=== Cleanup inventory ==="
  if ((${#PLAN[@]} == 0)); then
    log "No allowlisted Manara resources were found."
  else
    local row kind region identifier
    for row in "${PLAN[@]}"; do
      IFS=$'\t' read -r kind region identifier <<< "$row"
      record "PLANNED" "$kind" "$region" "$identifier"
    done
  fi
  print_rows "SKIPPED" "${SKIPPED[@]}"
  print_rows "UNSUPPORTED" "${UNSUPPORTED[@]}"
  print_rows "FAILED" "${FAILED[@]}"
}

delete_record() {
  local kind="$1" region="$2" identifier="$3" id name arn scope
  case "$kind" in
    autoscaling-policy)
      IFS=',' read -r name id <<< "$identifier"
      aws_cli autoscaling delete-policy --region "$region" \
        --auto-scaling-group-name "$name" --policy-name "$id" >/dev/null || return 1
      ;;
    autoscaling-group)
      name="$identifier"
      aws_cli autoscaling update-auto-scaling-group --region "$region" \
        --auto-scaling-group-name "$name" --min-size 0 --max-size 0 --desired-capacity 0 || return 1
      aws_cli autoscaling delete-auto-scaling-group --region "$region" \
        --auto-scaling-group-name "$name" --force-delete || return 1
      wait_for_asg_absent "$name" || return 1
      ;;
    asg-instance)
      # Termination is handled by deleting the verified owning ASG.
      return 0
      ;;
    ec2-instance)
      aws_cli ec2 terminate-instances --region "$region" --instance-ids "$identifier" >/dev/null || return 1
      aws_cli ec2 wait instance-terminated --region "$region" --instance-ids "$identifier" || return 1
      ;;
    ebs-volume)
      local volume_response volume_state
      if ! volume_response="$(aws_cli ec2 describe-volumes --region "$region" \
        --volume-ids "$identifier" --output json 2>&1)"; then
        [[ "$volume_response" == *"InvalidVolume.NotFound"* ]] && return 0
        return 1
      fi
      volume_state="$(jq -r '.Volumes[0].State // ""' <<< "$volume_response")"
      if [[ "$volume_state" == "deleting" ]]; then
        aws_cli ec2 wait volume-deleted --region "$region" --volume-ids "$identifier" || return 1
        return 0
      fi
      [[ "$volume_state" == "available" ]] || return 1
      aws_cli ec2 delete-volume --region "$region" --volume-id "$identifier" >/dev/null || return 1
      aws_cli ec2 wait volume-deleted --region "$region" --volume-ids "$identifier" || return 1
      ;;
    launch-template)
      aws_cli ec2 delete-launch-template --region "$region" --launch-template-id "$identifier" >/dev/null || return 1
      ;;
    listener-rule)
      aws_cli elbv2 delete-rule --region "$region" --rule-arn "$identifier" >/dev/null || return 1
      ;;
    listener)
      aws_cli elbv2 delete-listener --region "$region" --listener-arn "$identifier" >/dev/null || return 1
      ;;
    load-balancer)
      aws_cli elbv2 delete-load-balancer --region "$region" --load-balancer-arn "$identifier" >/dev/null || return 1
      aws_cli elbv2 wait load-balancers-deleted --region "$region" --load-balancer-arns "$identifier" || return 1
      ;;
    target-group)
      aws_cli elbv2 delete-target-group --region "$region" --target-group-arn "$identifier" >/dev/null || return 1
      ;;
    waf-association)
      aws_cli wafv2 disassociate-web-acl --region "$region" --resource-arn "$identifier" >/dev/null || return 1
      ;;
    cloudfront-waf-association)
      # The distribution update below clears the verified Manara ACL.
      return 0
      ;;
    rds-instance)
      local protection
      # This exact database was ownership-checked; the user authorized deletion without a snapshot.
      protection="$(aws_cli rds describe-db-instances --region "$region" \
        --db-instance-identifier "$identifier" --query 'DBInstances[0].DeletionProtection' --output text)"
      if [[ "$protection" == "True" ]]; then
        aws_cli rds modify-db-instance --region "$region" --db-instance-identifier "$identifier" \
          --no-deletion-protection --apply-immediately >/dev/null || return 1
      fi
      aws_cli rds delete-db-instance --region "$region" --db-instance-identifier "$identifier" \
        --skip-final-snapshot --delete-automated-backups >/dev/null || return 1
      aws_cli rds wait db-instance-deleted --region "$region" --db-instance-identifier "$identifier" || return 1
      ;;
    rds-subnet-group)
      aws_cli rds delete-db-subnet-group --region "$region" --db-subnet-group-name "$identifier" >/dev/null || return 1
      ;;
    rds-parameter-group)
      aws_cli rds delete-db-parameter-group --region "$region" --db-parameter-group-name "$identifier" >/dev/null || return 1
      ;;
    secret)
      # Immediate deletion is authorized only for the verified Manara secret ARN.
      aws_cli secretsmanager delete-secret --region "$region" --secret-id "$identifier" \
        --force-delete-without-recovery >/dev/null || return 1
      ;;
    log-group)
      aws_cli logs delete-log-group --region "$region" --log-group-name "$identifier" >/dev/null || return 1
      ;;
    alarm)
      aws_cli cloudwatch delete-alarms --region "$region" --alarm-names "$identifier" >/dev/null || return 1
      ;;
    dashboard)
      aws_cli cloudwatch delete-dashboards --region "$region" --dashboard-names "$identifier" >/dev/null || return 1
      ;;
    sns-topic)
      aws_cli sns delete-topic --region "$region" --topic-arn "$identifier" >/dev/null || return 1
      ;;
    sns-subscription)
      aws_cli sns unsubscribe --region "$region" --subscription-arn "$identifier" >/dev/null || return 1
      ;;
    vpc-endpoint)
      aws_cli ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids "$identifier" >/dev/null || return 1
      wait_for_vpc_endpoint_absent "$identifier" || return 1
      ;;
    nat-gateway)
      aws_cli ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$identifier" >/dev/null || return 1
      aws_cli ec2 wait nat-gateway-deleted --region "$region" --nat-gateway-ids "$identifier" || return 1
      ;;
    elastic-ip)
      aws_cli ec2 release-address --region "$region" --allocation-id "$identifier" >/dev/null || return 1
      ;;
    internet-gateway)
      aws_cli ec2 detach-internet-gateway --region "$region" \
        --internet-gateway-id "$identifier" --vpc-id "$TARGET_VPC_ID" >/dev/null || return 1
      aws_cli ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$identifier" >/dev/null || return 1
      ;;
    subnet)
      aws_cli ec2 delete-subnet --region "$region" --subnet-id "$identifier" >/dev/null || return 1
      ;;
    route-table)
      delete_route_table "$identifier" "$region"
      ;;
    network-acl)
      aws_cli ec2 delete-network-acl --region "$region" --network-acl-id "$identifier" >/dev/null || return 1
      ;;
    security-group)
      aws_cli ec2 delete-security-group --region "$region" --group-id "$identifier" >/dev/null || return 1
      ;;
    vpc)
      aws_cli ec2 delete-vpc --region "$region" --vpc-id "$identifier" >/dev/null || return 1
      ;;
    waf-regional|waf-cloudfront)
      IFS=',' read -r id name arn <<< "$identifier"
      scope="REGIONAL"
      [[ "$kind" != "waf-cloudfront" ]] || scope="CLOUDFRONT"
      local lock_token
      lock_token="$(aws_cli wafv2 get-web-acl --region "$region" --scope "$scope" \
        --id "$id" --name "$name" --query LockToken --output text)" || return 1
      aws_cli wafv2 delete-web-acl --region "$region" --scope "$scope" \
        --id "$id" --name "$name" --lock-token "$lock_token" >/dev/null || return 1
      ;;
    cloudfront-distribution)
      delete_cloudfront_distribution "$identifier"
      ;;
    iam-profile)
      delete_iam_profile "$identifier"
      ;;
    iam-role)
      delete_iam_role "$identifier"
      ;;
    *)
      return 2
      ;;
  esac
}

delete_route_table() {
  local route_table_id="$1" region="$2" table route destination gateway subnet_id id
  local gateway_owned
  table="$(aws_cli ec2 describe-route-tables --region "$region" \
    --route-table-ids "$route_table_id" --output json)"

  # Validate every non-local route and association before changing the table.
  # A project-named route table may still have been modified by its operator.
  while IFS= read -r route; do
    [[ -n "$route" ]] || continue
    gateway="$(jq -r '.GatewayId // ""' <<< "$route")"
    [[ "$gateway" == "local" ]] && continue
    destination="$(jq -r '.DestinationCidrBlock // .DestinationIpv6CidrBlock // .DestinationPrefixListId // ""' <<< "$route")"
    [[ "$destination" == "0.0.0.0/0" ]] || return 1
    gateway="$(jq -r '.GatewayId // .NatGatewayId // ""' <<< "$route")"
    gateway_owned=false
    for id in "${INTERNET_GATEWAYS[@]}" "${NAT_GATEWAYS[@]}"; do
      [[ -n "$id" && "$gateway" == "$id" ]] && gateway_owned=true
    done
    [[ "$gateway_owned" == true ]] || return 1
  done < <(jq -c '.RouteTables[0].Routes[]?' <<< "$table")

  while IFS= read -r route; do
    [[ -n "$route" ]] || continue
    [[ "$(jq -r '.Main // false' <<< "$route")" == "true" ]] && continue
    subnet_id="$(jq -r '.SubnetId // ""' <<< "$route")"
    gateway="$(jq -r '.GatewayId // ""' <<< "$route")"
    local association_owned
    association_owned=false
    for id in "${SUBNETS[@]}"; do
      [[ -n "$id" && "$subnet_id" == "$id" ]] && association_owned=true
    done
    [[ "$association_owned" == true && -z "$gateway" ]] || return 1
  done < <(jq -c '.RouteTables[0].Associations[]?' <<< "$table")

  while IFS= read -r route; do
    [[ -n "$route" ]] || continue
    [[ "$(jq -r '.GatewayId // ""' <<< "$route")" == "local" ]] && continue
    destination="$(jq -r '.DestinationCidrBlock' <<< "$route")"
    aws_cli ec2 delete-route --region "$region" --route-table-id "$route_table_id" \
      --destination-cidr-block "$destination" >/dev/null || return 1
  done < <(jq -c '.RouteTables[0].Routes[]?' <<< "$table")

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    aws_cli ec2 disassociate-route-table --region "$region" --association-id "$id" >/dev/null || return 1
  done < <(jq -r '.RouteTables[0].Associations[]? | select(.Main != true) | .RouteTableAssociationId' <<< "$table")
  aws_cli ec2 delete-route-table --region "$region" --route-table-id "$route_table_id" >/dev/null || return 1
  while IFS= read -r route; do
    [[ -n "$route" ]] || continue
    [[ "$(jq -r '.GatewayId // ""' <<< "$route")" == "local" ]] && continue
    destination="$(jq -r '.DestinationCidrBlock // .DestinationIpv6CidrBlock // .DestinationPrefixListId // ""' <<< "$route")"
    gateway="$(jq -r '.GatewayId // .NatGatewayId // ""' <<< "$route")"
    DELETED+=("route"$'\t'"$region"$'\t'"${route_table_id},${destination},${gateway}")
  done < <(jq -c '.RouteTables[0].Routes[]?' <<< "$table")
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    DELETED+=("route-table-association"$'\t'"$region"$'\t'"$id")
  done < <(jq -r '.RouteTables[0].Associations[]? | select(.Main != true) | .RouteTableAssociationId' <<< "$table")
}

cleanup_cloudfront_temp_file() {
  if [[ -n "$CLOUDFRONT_TEMP_FILE" ]]; then
    rm -f -- "$CLOUDFRONT_TEMP_FILE" || return 1
    CLOUDFRONT_TEMP_FILE=""
  fi
  trap - EXIT
}

delete_cloudfront_distribution() {
  local id="$1" response etag config temp_file web_acl
  response="$(aws_cli cloudfront get-distribution-config --region "$GLOBAL_REGION" --id "$id" --output json)"
  etag="$(jq -r '.ETag' <<< "$response")"
  web_acl="$(jq -r '.DistributionConfig.WebACLId // ""' <<< "$response")"
  config="$(jq -c --argjson webAclArnList "$(printf '%s\n' "${WAF_CLOUDFRONT[@]}" | jq -R . | jq -s .)" \
    '.DistributionConfig
     | .Enabled = false
     | if ($webAclArnList | index(.WebACLId)) then .WebACLId = "" else . end' <<< "$response")"
  temp_file="$(mktemp)"
  CLOUDFRONT_TEMP_FILE="$temp_file"
  trap '[[ -z "$CLOUDFRONT_TEMP_FILE" ]] || rm -f -- "$CLOUDFRONT_TEMP_FILE"' EXIT
  if ! printf '%s\n' "$config" > "$temp_file"; then
    cleanup_cloudfront_temp_file
    return 1
  fi
  if ! aws_cli cloudfront update-distribution --region "$GLOBAL_REGION" --id "$id" --if-match "$etag" \
    --distribution-config "file://${temp_file}" >/dev/null; then
    cleanup_cloudfront_temp_file
    return 1
  fi
  cleanup_cloudfront_temp_file
  if [[ -n "$web_acl" ]] && printf '%s\n' "${WAF_CLOUDFRONT[@]}" | grep -Fxq "$web_acl"; then
    DELETED+=("cloudfront-waf-association"$'\t'"$GLOBAL_REGION"$'\t'"$id")
  fi
  aws_cli cloudfront wait distribution-deployed --region "$GLOBAL_REGION" --id "$id" || return 1
  response="$(aws_cli cloudfront get-distribution-config --region "$GLOBAL_REGION" --id "$id" --output json)"
  etag="$(jq -r '.ETag' <<< "$response")"
  aws_cli cloudfront delete-distribution --region "$GLOBAL_REGION" --id "$id" --if-match "$etag" >/dev/null || return 1
  wait_for_cloudfront_absent "$id" || return 1
  : "$web_acl"
}

wait_for_cloudfront_absent() {
  local id="$1" attempt response
  for attempt in {1..40}; do
    if response="$(aws_cli cloudfront get-distribution --region "$GLOBAL_REGION" \
      --id "$id" --output json 2>&1)"; then
      sleep 15
    elif [[ "$response" == *"NoSuchDistribution"* ]]; then
      return 0
    else
      return 1
    fi
  done
  return 1
}

wait_for_vpc_endpoint_absent() {
  local id="$1" attempt response count
  for attempt in {1..40}; do
    if ! response="$(aws_cli ec2 describe-vpc-endpoints --region "$MAIN_REGION" \
      --filters "Name=vpc-endpoint-id,Values=${id}" --output json 2>&1)"; then
      return 1
    fi
    if ! count="$(jq '.VpcEndpoints | length' <<< "$response")"; then
      return 1
    fi
    [[ "$count" -eq 0 ]] && return 0
    sleep 15
  done
  return 1
}

wait_for_asg_absent() {
  local name="$1" attempt response count
  for attempt in {1..40}; do
    if ! response="$(aws_cli autoscaling describe-auto-scaling-groups --region "$MAIN_REGION" \
      --auto-scaling-group-names "$name" --output json 2>&1)"; then
      return 1
    fi
    if ! count="$(jq '.AutoScalingGroups | length' <<< "$response")"; then
      return 1
    fi
    [[ "$count" -eq 0 ]] && return 0
    sleep 15
  done
  return 1
}

wait_for_managed_enis_absent() {
  local attempt response eni_id item still_present managed_eni
  for attempt in {1..40}; do
    if ! response="$(aws_cli ec2 describe-network-interfaces --region "$MAIN_REGION" \
      --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json 2>&1)"; then
      return 1
    fi
    still_present=false
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      eni_id="$(jq -r '.NetworkInterfaceId' <<< "$item")"
      for managed_eni in "${MANAGED_ENIS[@]}"; do
        [[ "$eni_id" != "$managed_eni" ]] || still_present=true
      done
    done < <(jq -c '.NetworkInterfaces[]?' <<< "$response")
    [[ "$still_present" == false ]] && return 0
    sleep 15
  done
  return 1
}

delete_iam_profile() {
  local profile="$1" response role
  response="$(aws_cli iam get-instance-profile --instance-profile-name "$profile" --output json)"
  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    if [[ "$role" != "${NAME_PREFIX}-ec2-role" && "$role" != "${NAME_PREFIX}-rds-monitoring-role" ]]; then
      skip_resource "iam-profile-role" "global" "$role" "profile contains a role outside the Manara allowlist" true
      return 1
    fi
    aws_cli iam remove-role-from-instance-profile --instance-profile-name "$profile" \
      --role-name "$role" >/dev/null || return 1
  done < <(jq -r '.InstanceProfile.Roles[]?.RoleName' <<< "$response")
  aws_cli iam delete-instance-profile --instance-profile-name "$profile" >/dev/null || return 1
}

delete_iam_role() {
  local role="$1" response name arn
  response="$(aws_cli iam list-role-policies --role-name "$role" --output json)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in
      "${NAME_PREFIX}-secrets-read"|"${NAME_PREFIX}-ssm-params-read")
        aws_cli iam delete-role-policy --role-name "$role" --policy-name "$name" >/dev/null || return 1
        DELETED+=("iam-inline-policy"$'\t'"global"$'\t'"${role},${name}")
        ;;
      *) skip_resource "iam-inline-policy" "global" "$name" "policy name is outside the allowlist" true ;;
    esac
  done < <(jq -r '.PolicyNames[]?' <<< "$response")
  response="$(aws_cli iam list-attached-role-policies --role-name "$role" --output json)"
  while IFS= read -r arn; do
    [[ -n "$arn" ]] || continue
    case "$arn" in
      arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore|\
      arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy|\
      arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole)
        aws_cli iam detach-role-policy --role-name "$role" --policy-arn "$arn" >/dev/null || return 1
        DELETED+=("iam-attached-policy"$'\t'"global"$'\t'"${role},${arn}")
        ;;
      *) skip_resource "iam-attached-policy" "global" "$arn" "attached policy is outside the allowlist" true ;;
    esac
  done < <(jq -r '.AttachedPolicies[]?.PolicyArn' <<< "$response")
  aws_cli iam delete-role --role-name "$role" >/dev/null || return 1
}

disassociate_regional_waf() {
  local lb arn response waf_arn status
  status=0
  for lb in "${LOAD_BALANCERS[@]}"; do
    if ! response="$(aws_cli wafv2 get-web-acl-for-resource --region "$MAIN_REGION" \
      --resource-arn "$lb" --output json 2>&1)"; then
      if [[ "$response" == *"WAFNonexistentItemException"* ]]; then
        continue
      fi
      fail_resource "waf-association" "$MAIN_REGION" "$lb" \
        "could not verify whether a WebACL is associated"
      status=1
      continue
    fi
    waf_arn="$(jq -r '.WebACL.ARN // ""' <<< "$response")"
    [[ -n "$waf_arn" ]] || continue
    if printf '%s\n' "${WAF_REGIONAL[@]}" | grep -Fxq "$waf_arn"; then
      if aws_cli wafv2 disassociate-web-acl --region "$MAIN_REGION" --resource-arn "$lb" >/dev/null; then
        DELETED+=("waf-association"$'\t'"$MAIN_REGION"$'\t'"$lb")
      else
        fail_resource "waf-association" "$MAIN_REGION" "$lb" "could not disassociate the verified Manara WebACL"
        status=1
      fi
    else
      fail_resource "waf-association" "$MAIN_REGION" "$lb" "ALB has a WebACL outside the Manara allowlist"
      status=1
    fi
  done
  return "$status"
}

delete_security_groups_in_order() {
  local name id
  local -a ordered_names=(
    "${NAME_PREFIX}-sg-db"
    "${NAME_PREFIX}-sg-vpc-endpoints"
    "${NAME_PREFIX}-sg-app"
    "${NAME_PREFIX}-sg-alb"
  )
  for name in "${ordered_names[@]}"; do
    for id in "${SECURITY_GROUPS[@]}"; do
      local group_name
      if ! group_name="$(aws_cli ec2 describe-security-groups --region "$MAIN_REGION" \
        --group-ids "$id" --query 'SecurityGroups[0].GroupName' --output text 2>&1)"; then
        fail_resource "security-group" "$MAIN_REGION" "$id" "could not re-verify group before deletion"
        continue
      fi
      [[ "$group_name" == "$name" ]] || continue
      if aws_cli ec2 delete-security-group --region "$MAIN_REGION" --group-id "$id" >/dev/null; then
        DELETED+=("security-group"$'\t'"$MAIN_REGION"$'\t'"$id")
      else
        fail_resource "security-group" "$MAIN_REGION" "$id" "group still has references or attached ENIs"
      fi
    done
  done
}

run_type() {
  local wanted="$1" row kind region identifier
  for row in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind region identifier <<< "$row"
    [[ "$kind" == "$wanted" ]] || continue
    if delete_record "$kind" "$region" "$identifier"; then
      DELETED+=("${kind}"$'\t'"${region}"$'\t'"${identifier}")
    else
      fail_resource "$kind" "$region" "$identifier" "AWS deletion API or bounded waiter failed"
    fi
  done
}

delete_network_dependencies() {
  local id
  # Remove only verified project routes and explicit associations first.
  for id in "${ROUTE_TABLES[@]}"; do
    if delete_route_table "$id" "$MAIN_REGION"; then
      DELETED+=("route-table"$'\t'"$MAIN_REGION"$'\t'"$id")
    else
      fail_resource "route-table" "$MAIN_REGION" "$id" "route cleanup failed"
    fi
  done
  for id in "${INTERNET_GATEWAYS[@]}"; do
    if delete_record "internet-gateway" "$MAIN_REGION" "$id"; then
      DELETED+=("internet-gateway"$'\t'"$MAIN_REGION"$'\t'"$id")
    else
      fail_resource "internet-gateway" "$MAIN_REGION" "$id" "detach/delete failed"
    fi
  done
  for id in "${SUBNETS[@]}"; do
    if delete_record "subnet" "$MAIN_REGION" "$id"; then
      DELETED+=("subnet"$'\t'"$MAIN_REGION"$'\t'"$id")
    else
      fail_resource "subnet" "$MAIN_REGION" "$id" "subnet remains or has dependencies"
    fi
  done
  for id in "${NETWORK_ACLS[@]}"; do
    if delete_record "network-acl" "$MAIN_REGION" "$id"; then
      DELETED+=("network-acl"$'\t'"$MAIN_REGION"$'\t'"$id")
    else
      fail_resource "network-acl" "$MAIN_REGION" "$id" "ACL remains associated or deletion failed"
    fi
  done
  delete_security_groups_in_order

  if [[ "$VPC_PRESENT" -eq 1 ]]; then
    local eni_response eni_count
    if ! wait_for_managed_enis_absent; then
      for id in "${MANAGED_ENIS[@]}"; do
        fail_resource "network-interface" "$MAIN_REGION" "$id" \
          "verified parent deletion did not remove the ENI before timeout"
      done
      return
    fi
    for id in "${MANAGED_ENIS[@]}"; do
      DELETED+=("network-interface"$'\t'"$MAIN_REGION"$'\t'"$id")
    done
    eni_response="$(aws_cli ec2 describe-network-interfaces --region "$MAIN_REGION" \
      --filters "Name=vpc-id,Values=${TARGET_VPC_ID}" --output json)"
    eni_count="$(jq '.NetworkInterfaces | length' <<< "$eni_response")"
    if [[ "$eni_count" -gt 0 ]]; then
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        skip_resource "network-interface" "$MAIN_REGION" "$id" \
          "remaining ENI is not detached/deleted automatically; inspect its requester/owner" true
      done < <(jq -r '.NetworkInterfaces[]?.NetworkInterfaceId' <<< "$eni_response")
      return
    fi
    # Never attempt VPC deletion while a verified or unknown ENI remains.
    if delete_record "vpc" "$MAIN_REGION" "$TARGET_VPC_ID"; then
      DELETED+=("vpc"$'\t'"$MAIN_REGION"$'\t'"$TARGET_VPC_ID")
    else
      fail_resource "vpc" "$MAIN_REGION" "$TARGET_VPC_ID" "VPC still has dependent resources"
    fi
  fi
}

record_asg_instance_results() {
  local row kind region identifier response state
  for row in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind region identifier <<< "$row"
    [[ "$kind" == "asg-instance" ]] || continue
    if ! response="$(aws_cli ec2 describe-instances --region "$region" \
      --instance-ids "$identifier" --output json 2>&1)"; then
      if [[ "$response" == *"InvalidInstanceID.NotFound"* ]]; then
        DELETED+=("${kind}"$'\t'"${region}"$'\t'"${identifier}")
      else
        fail_resource "$kind" "$region" "$identifier" "could not verify ASG instance termination"
      fi
      continue
    fi
    state="$(jq -r 'first(.Reservations[]?.Instances[]?.State.Name) // empty' <<< "$response")"
    if [[ -z "$state" || "$state" == "terminated" ]]; then
      DELETED+=("${kind}"$'\t'"${region}"$'\t'"${identifier}")
    else
      fail_resource "$kind" "$region" "$identifier" "instance remains in state ${state} after ASG deletion"
    fi
  done
}

delete_all() {
  local id regional_waf_ready
  # Workloads and service attachments are removed before their network.
  run_type "autoscaling-policy"
  run_type "autoscaling-group"
  record_asg_instance_results
  run_type "ec2-instance"
  run_type "ebs-volume"
  run_type "launch-template"

  # CloudFront must be disabled and fully deployed before deletion. Its exact
  # Manara WAF association is cleared only if it matches the identified ACL.
  run_type "cloudfront-distribution"

  regional_waf_ready=true
  if ! disassociate_regional_waf; then
    regional_waf_ready=false
  fi
  if [[ "$regional_waf_ready" == true ]]; then
    run_type "listener-rule"
    run_type "listener"
    run_type "load-balancer"
    run_type "target-group"
  else
    skip_resource "load-balancer" "$MAIN_REGION" "${NAME_PREFIX}-alb" \
      "regional WAF association could not be safely verified or removed" true
  fi

  run_type "rds-instance"
  run_type "rds-subnet-group"
  run_type "rds-parameter-group"
  run_type "secret"

  run_type "alarm"
  run_type "dashboard"
  run_type "sns-subscription"
  run_type "sns-topic"
  run_type "log-group"

  run_type "vpc-endpoint"
  run_type "nat-gateway"
  run_type "elastic-ip"
  if [[ "$regional_waf_ready" == true ]]; then
    run_type "waf-regional"
  else
    skip_resource "waf-regional" "$MAIN_REGION" "${NAME_PREFIX}-waf-regional" \
      "regional ALB association remains unresolved" true
  fi
  run_type "waf-cloudfront"

  # IAM is global; remove profiles and allowlisted attachments/policies before
  # roles. Unrecognized role attachments are reported and block role deletion.
  run_type "iam-profile"
  run_type "iam-role"

  delete_network_dependencies
}

reset_discovery_state() {
  PLAN=()
  AUTOSCALING_GROUPS=()
  LOAD_BALANCERS=()
  TARGET_GROUPS=()
  RDS_INSTANCES=()
  VPC_ENDPOINTS=()
  NAT_GATEWAYS=()
  NAT_EIPS=()
  ROUTE_TABLES=()
  SECURITY_GROUPS=()
  SUBNETS=()
  NETWORK_ACLS=()
  INTERNET_GATEWAYS=()
  WAF_REGIONAL=()
  WAF_CLOUDFRONT=()
  CLOUDFRONT_DISTRIBUTIONS=()
  IAM_ROLES=()
  IAM_PROFILES=()
  DB_SECURITY_GROUP_IDS=()
  DB_SUBNET_IDS=()
  ALB_SECURITY_GROUP_IDS=()
  MANAGED_ENIS=()
  VPC_PRESENT=0
  ALB_DNS=""
}

final_verify() {
  local row kind region identifier
  reset_discovery_state
  discover_vpc
  discover_load_balancer
  discover_compute_and_network
  validate_route_tables
  discover_databases_and_logs
  discover_global_and_waf
  discover_associations
  discover_network_interfaces
  if ((${#PLAN[@]} > 0)); then
    for row in "${PLAN[@]}"; do
      IFS=$'\t' read -r kind region identifier <<< "$row"
      fail_resource "verification:${kind}" "$region" "$identifier" "eligible resource remains after cleanup"
    done
  fi
  if ((${#PLAN[@]} > 0)); then
    log "Remaining eligible resources:"
    print_rows "REMAINS" "${PLAN[@]}"
  fi
}

print_summary() {
  log ""
  log "=== Cleanup summary ==="
  print_rows "DELETED" "${DELETED[@]}"
  print_rows "SKIPPED" "${SKIPPED[@]}"
  print_rows "UNSUPPORTED" "${UNSUPPORTED[@]}"
  print_rows "FAILED" "${FAILED[@]}"
  log "Planned: ${INITIAL_PLAN_COUNT} | Deleted: ${#DELETED[@]} | Skipped: ${#SKIPPED[@]} | Unsupported: ${#UNSUPPORTED[@]} | Failed: ${#FAILED[@]}"
}

main() {
  if [[ "$ACTION" != "dry-run" && "$ACTION" != "delete" ]]; then
    log "::error::CLEANUP_ACTION must be 'dry-run' or 'delete'."
    exit 2
  fi
  if [[ "$ACTION" == "delete" && "$CONFIRM_DELETE" != "$CONFIRMATION" ]]; then
    log "::error::Deletion requires DELETE-MANARA-DEV confirmation."
    exit 2
  fi
  if [[ "${AWS_REGION:-$MAIN_REGION}" != "$MAIN_REGION" ]]; then
    log "::error::AWS_REGION must be ${MAIN_REGION}."
    exit 2
  fi

  require_tools
  account_check
  log "Mode: ${ACTION}; main region: ${MAIN_REGION}; CloudFront/WAF region: ${GLOBAL_REGION}"

  discover_vpc
  discover_load_balancer
  discover_compute_and_network
  validate_route_tables
  discover_databases_and_logs
  discover_global_and_waf
  discover_associations
  discover_network_interfaces
  print_inventory
  INITIAL_PLAN=("${PLAN[@]}")
  INITIAL_PLAN_COUNT="${#PLAN[@]}"

  if [[ "$ACTION" == "dry-run" ]]; then
    log "Dry-run complete: no AWS mutation APIs were called."
    print_summary
    [[ "$BLOCKERS" -eq 0 ]] || exit 1
    exit 0
  fi

  if [[ "$BLOCKERS" -gt 0 ]]; then
    log "::error::Deletion stopped before making changes because inventory contains ownership blockers."
    print_summary
    exit 1
  fi

  delete_all
  final_verify
  print_summary
  if ((${#PLAN[@]} > 0 || ${#FAILED[@]} > 0 || ${#UNSUPPORTED[@]} > 0 || BLOCKERS > 0)); then
    log "::error::Cleanup is incomplete. Review failed, unsupported, or skipped resources above."
    exit 1
  fi
  log "Cleanup completed and the verified Manara VPC is absent."
}

main "$@"
