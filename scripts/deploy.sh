#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
TEMPLATE_BUCKET_NAME="${TEMPLATE_BUCKET_NAME:-}"
NETWORKING_STACK_NAME="${NETWORKING_STACK_NAME:-shared-networking}"
SECURITY_STACK_NAME="${SECURITY_STACK_NAME:-shared-security}"
CACHE_STACK_NAME="${CACHE_STACK_NAME:-shared-cache}"
DATABASE_STACK_NAME="${DATABASE_STACK_NAME:-shared-database}"
ENVIRONMENT="${ENVIRONMENT:-prod}"

usage() {
  cat <<'EOF'
Required environment variables:
  TEMPLATE_BUCKET_NAME   S3 bucket that stores nested CloudFormation templates
  AWS_REGION             AWS region for CloudFormation and S3 operations

Optional environment variables:
  ENVIRONMENT            CloudFormation environment parameter (default: prod)
  NETWORKING_STACK_NAME  Root stack name for shared networking (default: shared-networking)
  SECURITY_STACK_NAME    Root stack name for shared security (default: shared-security)
  CACHE_STACK_NAME       Root stack name for shared cache (default: shared-cache)
  DATABASE_STACK_NAME    Root stack name for shared database (default: shared-database)
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

sync_templates() {
  aws s3 sync "${ROOT_DIR}/shared" "s3://${TEMPLATE_BUCKET_NAME}/shared" \
    --exclude "*" \
    --include "*.yaml" \
    --region "${AWS_REGION}"
}

deploy_stack() {
  local stack_name="$1"
  local template_file="$2"
  shift 2

  local capabilities=()
  if [[ "${1:-}" == "--capabilities" ]]; then
    capabilities=(--capabilities "$2")
    shift 2
  fi

  echo "Deploying ${stack_name}"
  aws cloudformation deploy \
    --stack-name "${stack_name}" \
    --template-file "${template_file}" \
    --region "${AWS_REGION}" \
    --no-fail-on-empty-changeset \
    "${capabilities[@]}" \
    --parameter-overrides "$@"
}

main() {
  require_env TEMPLATE_BUCKET_NAME
  require_env AWS_REGION

  sync_templates

  deploy_stack "${NETWORKING_STACK_NAME}" "${ROOT_DIR}/shared/networking/template.yaml" \
    TemplateBucketName="${TEMPLATE_BUCKET_NAME}"

  deploy_stack "${SECURITY_STACK_NAME}" "${ROOT_DIR}/shared/security/template.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    TemplateBucketName="${TEMPLATE_BUCKET_NAME}"

  deploy_stack "${CACHE_STACK_NAME}" "${ROOT_DIR}/shared/cache/template.yaml" \
    TemplateBucketName="${TEMPLATE_BUCKET_NAME}" \
    Environment="${ENVIRONMENT}"

  deploy_stack "${DATABASE_STACK_NAME}" "${ROOT_DIR}/shared/database/template.yaml" \
    TemplateBucketName="${TEMPLATE_BUCKET_NAME}" \
    Environment="${ENVIRONMENT}"
}

main "$@"
