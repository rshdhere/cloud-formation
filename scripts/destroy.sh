#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
NETWORKING_STACK_NAME="${NETWORKING_STACK_NAME:-shared-networking}"
SECURITY_STACK_NAME="${SECURITY_STACK_NAME:-shared-security}"
CACHE_STACK_NAME="${CACHE_STACK_NAME:-shared-cache}"
DATABASE_STACK_NAME="${DATABASE_STACK_NAME:-shared-database}"
LEGACY_SECURITY_IAM_STACK_NAME="${LEGACY_SECURITY_IAM_STACK_NAME:-shared-security-IAMStack}"
DEPLOYMENT_USER_NAME="${DEPLOYMENT_USER_NAME:-transcoding-infra}"
LEGACY_CACHE_POLICY_NAME="${LEGACY_CACHE_POLICY_NAME:-shared-cache-elasticache-deploy-v2}"

usage() {
  cat <<'EOF'
Required environment variables:
  AWS_REGION             AWS region for CloudFormation and IAM operations

Optional environment variables:
  NETWORKING_STACK_NAME   Root stack name for shared networking (default: shared-networking)
  SECURITY_STACK_NAME     Root stack name for shared security (default: shared-security)
  CACHE_STACK_NAME        Root stack name for shared cache (default: shared-cache)
  DATABASE_STACK_NAME     Root stack name for shared database (default: shared-database)
  LEGACY_SECURITY_IAM_STACK_NAME  Legacy nested IAM stack name (default: shared-security-IAMStack)
  DEPLOYMENT_USER_NAME    IAM user that received the legacy managed policy (default: transcoding-infra)
  LEGACY_CACHE_POLICY_NAME  Managed policy name created by the legacy IAM stack (default: shared-cache-elasticache-deploy-v2)
EOF
}

require_env() {
  local name="$1"
  local value="${!name:-}"

  if [[ -z "${value}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    usage >&2
    exit 1
  fi
}

stack_exists() {
  aws cloudformation describe-stacks \
    --stack-name "$1" \
    --region "${AWS_REGION}" \
    >/dev/null 2>&1
}

delete_stack() {
  local stack_name="$1"

  if ! stack_exists "${stack_name}"; then
    echo "Skipping ${stack_name}: stack not found"
    return 0
  fi

  echo "Deleting ${stack_name}"
  aws cloudformation delete-stack \
    --stack-name "${stack_name}" \
    --region "${AWS_REGION}"

  aws cloudformation wait stack-delete-complete \
    --stack-name "${stack_name}" \
    --region "${AWS_REGION}"
}

cleanup_legacy_security_iam_stack() {
  if ! stack_exists "${LEGACY_SECURITY_IAM_STACK_NAME}"; then
    echo "Skipping ${LEGACY_SECURITY_IAM_STACK_NAME}: stack not found"
    return 0
  fi

  local policy_arn
  policy_arn="$(
    aws iam list-policies \
      --scope Local \
      --query "Policies[?PolicyName=='${LEGACY_CACHE_POLICY_NAME}'].Arn | [0]" \
      --output text
  )"

  if [[ -n "${policy_arn}" && "${policy_arn}" != "None" ]]; then
    echo "Detaching legacy policy ${LEGACY_CACHE_POLICY_NAME} from ${DEPLOYMENT_USER_NAME}"
    aws iam detach-user-policy \
      --user-name "${DEPLOYMENT_USER_NAME}" \
      --policy-arn "${policy_arn}" || true
  fi

  delete_stack "${LEGACY_SECURITY_IAM_STACK_NAME}"
}

main() {
  require_env AWS_REGION

  cleanup_legacy_security_iam_stack
  delete_stack "${DATABASE_STACK_NAME}"
  delete_stack "${CACHE_STACK_NAME}"
  delete_stack "${SECURITY_STACK_NAME}"
  delete_stack "${NETWORKING_STACK_NAME}"
}

main "$@"
