#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -n "${TF_VAR_auth_version_override:-}" ]]; then
  # Test the exact immutable version before any promotion or rollback apply.
  JWT_SECRET="$TF_VAR_jwt_secret" AUTH_SERVICE_TOKEN="$TF_VAR_auth_service_token" \
  IDENTITY_URL="${TF_VAR_identity_url:-}" FASE4_NLB_NAME="${TF_VAR_fase4_nlb_name:-workshop-fase4-internal}" \
    python scripts/test-candidate.py --function workshop-auth-cpf --version "$TF_VAR_auth_version_override"
fi
bash scripts/plan-serverless.sh
terraform -chdir=infra apply -input=false -auto-approve tfplan
