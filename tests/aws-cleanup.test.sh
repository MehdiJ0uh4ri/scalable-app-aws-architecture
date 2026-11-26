#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "--no-cli-pager" ]]; then
  shift
fi

printf '%s\n' "$*" >> "$MOCK_AWS_CALL_LOG"
if [[ "$1" == "sts" && "$2" == "get-caller-identity" ]]; then
  printf '%s\n' "${MOCK_AWS_ACCOUNT:-412514130471}"
  exit 0
fi

if [[ "$1" == "ec2" && "$2" == "describe-vpcs" &&
      "${MOCK_AWS_INVENTORY:-}" == "owned-vpc" ]]; then
  cat <<'VPC_JSON'
{"Vpcs":[{"VpcId":"vpc-0c52f6858b43ab34f","Tags":[
  {"Key":"Name","Value":"manara-task-app-dev-vpc"},
  {"Key":"Project","Value":"manara-task-app"},
  {"Key":"Environment","Value":"dev"},
  {"Key":"ManagedBy","Value":"Terraform"}
]}]}
VPC_JSON
  exit 0
fi

if [[ "$1" == "ec2" && "$2" == "describe-vpcs" &&
      "${MOCK_AWS_INVENTORY:-}" == "owned-network" ]]; then
  cat <<'VPC_JSON'
{"Vpcs":[{"VpcId":"vpc-0c52f6858b43ab34f","Tags":[
  {"Key":"Name","Value":"manara-task-app-dev-vpc"},
  {"Key":"Project","Value":"manara-task-app"},
  {"Key":"Environment","Value":"dev"},
  {"Key":"ManagedBy","Value":"Terraform"}
]}]}
VPC_JSON
  exit 0
fi

if [[ "$1" == "ec2" && "$2" == "describe-vpcs" &&
      "${MOCK_AWS_INVENTORY:-}" == "wrong-owner" ]]; then
  cat <<'VPC_JSON'
{"Vpcs":[{"VpcId":"vpc-0c52f6858b43ab34f","Tags":[
  {"Key":"Name","Value":"manara-task-app-dev-vpc"},
  {"Key":"Project","Value":"other-project"},
  {"Key":"Environment","Value":"dev"},
  {"Key":"ManagedBy","Value":"Terraform"}
]}]}
VPC_JSON
  exit 0
fi

if [[ "$1" == "ec2" && "$2" == "describe-subnets" &&
      "${MOCK_AWS_INVENTORY:-}" == "owned-network" ]]; then
  cat <<'SUBNET_JSON'
{"Subnets":[{"SubnetId":"subnet-00000000000000001","VpcId":"vpc-0c52f6858b43ab34f","Tags":[
  {"Key":"Name","Value":"manara-task-app-dev-public-eu-west-3a"},
  {"Key":"Project","Value":"manara-task-app"},
  {"Key":"Environment","Value":"dev"},
  {"Key":"ManagedBy","Value":"Terraform"}
]}]}
SUBNET_JSON
  exit 0
fi

if [[ "$1" == "ec2" && "$2" == "describe-route-tables" &&
      "${MOCK_AWS_INVENTORY:-}" == "owned-network" ]]; then
  cat <<'ROUTE_TABLE_JSON'
{"RouteTables":[{"RouteTableId":"rtb-00000000000000001","VpcId":"vpc-0c52f6858b43ab34f","Tags":[
  {"Key":"Name","Value":"manara-task-app-dev-rt-public"},
  {"Key":"Project","Value":"manara-task-app"},
  {"Key":"Environment","Value":"dev"},
  {"Key":"ManagedBy","Value":"Terraform"}
],"Routes":[{"DestinationCidrBlock":"10.0.0.0/16","GatewayId":"local"}],
"Associations":[{"RouteTableAssociationId":"rtbassoc-00000000000000001","SubnetId":"subnet-00000000000000001","Main":false}]}]}
ROUTE_TABLE_JSON
  exit 0
fi

if [[ "$1" == "logs" && "$2" == "describe-log-groups" &&
      "${MOCK_AWS_INVENTORY:-}" == "owned-network" ]]; then
  printf '%s\n' '{"logGroups":[{"logGroupName":"/aws/ec2/manara-task-app-dev/application","logGroupArn":"arn:aws:logs:eu-west-3:412514130471:log-group:/aws/ec2/manara-task-app-dev/application:*"}]}'
  exit 0
fi

if [[ "$1" == "logs" && "$2" == "list-tags-for-resource" &&
      "${MOCK_AWS_INVENTORY:-}" == "owned-network" ]]; then
  printf '%s\n' '{"tags":{"Name":"manara-task-app-dev-app-logs"}}'
  exit 0
fi

if [[ "$1" == "cloudwatch" && "$2" == "describe-alarms" &&
      "${MOCK_AWS_INVENTORY:-}" == "owned-network" ]]; then
  printf '%s\n' '{"MetricAlarms":[{"AlarmName":"manara-task-app-dev-alb-5xx-errors","AlarmArn":"arn:aws:cloudwatch:eu-west-3:412514130471:alarm:manara-task-app-dev-alb-5xx-errors"}]}'
  exit 0
fi

if [[ "$1" == "cloudwatch" && "$2" == "list-tags-for-resource" &&
      "${MOCK_AWS_INVENTORY:-}" == "owned-network" ]]; then
  printf '%s\n' '{"Tags":[{"Key":"Name","Value":"manara-task-app-dev-alarm-alb-5xx"}]}'
  exit 0
fi

case "$2" in
  create-*|delete-*|modify-*|terminate-*|release-*|detach-*|disassociate-*|\
  unsubscribe|remove-*|revoke-*|disable-*|put-*|attach-*|stop-*|update-*)
    printf '%s\n' "$*" >> "$MOCK_AWS_MUTATION_LOG"
    ;;
esac
printf '{}\n'
MOCK_AWS
chmod +x "$TEST_TMP/bin/aws"

export PATH="$TEST_TMP/bin:$PATH"
export MOCK_AWS_CALL_LOG="$TEST_TMP/aws-calls.log"
export MOCK_AWS_MUTATION_LOG="$TEST_TMP/aws-mutations.log"

assert_no_mutations() {
  if [[ -s "$MOCK_AWS_MUTATION_LOG" ]]; then
    printf 'Unexpected AWS mutation call(s):\n' >&2
    cat "$MOCK_AWS_MUTATION_LOG" >&2
    exit 1
  fi
}

run_test() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name" >&2
    exit 1
  fi
}

test_empty_dry_run_is_read_only() {
  : > "$MOCK_AWS_CALL_LOG"
  : > "$MOCK_AWS_MUTATION_LOG"
  if ! env AWS_REGION=eu-west-3 CLEANUP_ACTION=dry-run \
    bash "$REPO_ROOT/scripts/aws-cleanup.sh" > "$TEST_TMP/dry-run.log" 2>&1; then
    cat "$TEST_TMP/dry-run.log" >&2
    return 1
  fi
  grep -Fq 'Dry-run complete: no AWS mutation APIs were called.' "$TEST_TMP/dry-run.log"
  assert_no_mutations
}

test_wrong_account_aborts_before_mutations() {
  : > "$MOCK_AWS_CALL_LOG"
  : > "$MOCK_AWS_MUTATION_LOG"
  if env MOCK_AWS_ACCOUNT=999999999999 AWS_REGION=eu-west-3 \
    CLEANUP_ACTION=dry-run bash "$REPO_ROOT/scripts/aws-cleanup.sh" \
    > "$TEST_TMP/wrong-account.log" 2>&1; then
    return 1
  fi
  grep -Fq 'expected 412514130471' "$TEST_TMP/wrong-account.log"
  assert_no_mutations
}

test_owned_vpc_is_listed_without_mutations() {
  : > "$MOCK_AWS_CALL_LOG"
  : > "$MOCK_AWS_MUTATION_LOG"
  if ! env MOCK_AWS_INVENTORY=owned-vpc AWS_REGION=eu-west-3 \
    CLEANUP_ACTION=dry-run bash "$REPO_ROOT/scripts/aws-cleanup.sh" \
    > "$TEST_TMP/owned-vpc.log" 2>&1; then
    cat "$TEST_TMP/owned-vpc.log" >&2
    return 1
  fi
  grep -Fq 'PLANNED      vpc                    eu-west-3   vpc-0c52f6858b43ab34f' "$TEST_TMP/owned-vpc.log"
  assert_no_mutations
}

test_network_associations_and_terraform_tags_are_recognized() {
  : > "$MOCK_AWS_CALL_LOG"
  : > "$MOCK_AWS_MUTATION_LOG"
  if ! env MOCK_AWS_INVENTORY=owned-network AWS_REGION=eu-west-3 \
    CLEANUP_ACTION=dry-run bash "$REPO_ROOT/scripts/aws-cleanup.sh" \
    > "$TEST_TMP/owned-network.log" 2>&1; then
    cat "$TEST_TMP/owned-network.log" >&2
    return 1
  fi
  grep -Fq 'PLANNED      route-table-association eu-west-3  rtbassoc-00000000000000001' "$TEST_TMP/owned-network.log"
  grep -Fq 'PLANNED      log-group              eu-west-3  /aws/ec2/manara-task-app-dev/application' "$TEST_TMP/owned-network.log"
  grep -Fq 'PLANNED      alarm                  eu-west-3  manara-task-app-dev-alb-5xx-errors' "$TEST_TMP/owned-network.log"
  assert_no_mutations
}

test_conflicting_owner_tags_block_dry_run() {
  : > "$MOCK_AWS_CALL_LOG"
  : > "$MOCK_AWS_MUTATION_LOG"
  if env MOCK_AWS_INVENTORY=wrong-owner AWS_REGION=eu-west-3 \
    CLEANUP_ACTION=dry-run bash "$REPO_ROOT/scripts/aws-cleanup.sh" \
    > "$TEST_TMP/wrong-owner.log" 2>&1; then
    cat "$TEST_TMP/wrong-owner.log" >&2
    return 1
  fi
  grep -Fq 'VPC name or ownership tags do not match' "$TEST_TMP/wrong-owner.log"
  assert_no_mutations
}

test_delete_requires_exact_confirmation() {
  : > "$MOCK_AWS_CALL_LOG"
  : > "$MOCK_AWS_MUTATION_LOG"
  if env AWS_REGION=eu-west-3 CLEANUP_ACTION=delete DELETE_CONFIRMATION=wrong \
    bash "$REPO_ROOT/scripts/aws-cleanup.sh" > "$TEST_TMP/confirmation.log" 2>&1; then
    return 1
  fi
  grep -Fq 'Deletion requires DELETE-MANARA-DEV confirmation.' "$TEST_TMP/confirmation.log"
  [[ ! -s "$MOCK_AWS_CALL_LOG" ]]
  assert_no_mutations
}

test_confirmed_empty_cleanup_is_a_noop() {
  : > "$MOCK_AWS_CALL_LOG"
  : > "$MOCK_AWS_MUTATION_LOG"
  if ! env AWS_REGION=eu-west-3 CLEANUP_ACTION=delete \
    DELETE_CONFIRMATION=DELETE-MANARA-DEV \
    bash "$REPO_ROOT/scripts/aws-cleanup.sh" > "$TEST_TMP/empty-delete.log" 2>&1; then
    cat "$TEST_TMP/empty-delete.log" >&2
    return 1
  fi
  grep -Fq 'Cleanup completed and the verified Manara VPC is absent.' "$TEST_TMP/empty-delete.log"
  assert_no_mutations
}

run_test "empty inventory dry-run is read-only" test_empty_dry_run_is_read_only
run_test "wrong account aborts before mutations" test_wrong_account_aborts_before_mutations
run_test "owned VPC inventory remains read-only" test_owned_vpc_is_listed_without_mutations
run_test "network associations and Terraform tags are recognized" test_network_associations_and_terraform_tags_are_recognized
run_test "conflicting owner tags block dry-run" test_conflicting_owner_tags_block_dry_run
run_test "delete requires exact confirmation" test_delete_requires_exact_confirmation
run_test "confirmed empty cleanup is a no-op" test_confirmed_empty_cleanup_is_a_noop
