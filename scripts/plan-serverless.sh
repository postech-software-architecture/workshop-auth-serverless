#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
: "${TF_VAR_auth_service_token:?AUTH_SERVICE_TOKEN is required}"
case "${TF_VAR_deployment_mode:-legacy}" in legacy|fresh) ;; *) echo 'Invalid AUTH_DEPLOYMENT_MODE' >&2; exit 1 ;; esac
terraform -chdir=infra plan -input=false -no-color -out=tfplan
terraform -chdir=infra show -json tfplan > "$RUNNER_TEMP/serverless-plan.json"
extra=()
if [[ "${ALLOW_ROUTE_ROLLBACK:-false}" == 'true' ]]; then extra+=(--allow-phase4-route-removal); fi
python scripts/guard-academy-plan.py "$RUNNER_TEMP/serverless-plan.json" "${extra[@]}"
terraform -chdir=infra show -no-color tfplan > "$RUNNER_TEMP/tfplan.txt"
sed -E 's/(password|secret|token|authorization)[^=]*=.*/\1 = (sensitive)/Ig' \
  "$RUNNER_TEMP/tfplan.txt" > "$RUNNER_TEMP/tfplan-sanitized.txt"
