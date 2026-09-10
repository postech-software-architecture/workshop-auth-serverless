#!/usr/bin/env bash
set -Eeuo pipefail

for command in aws zip; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERRO: comando obrigatorio ausente: $command" >&2
    exit 2
  }
done

AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

account_id="$(aws sts get-caller-identity --query Account --output text)"
role_arn="${LAB_ROLE_ARN:-arn:aws:iam::${account_id}:role/LabRole}"
function_name="w0-labrole-spike-${GITHUB_RUN_ID:-local}-$(date +%s)"
work_dir="$(mktemp -d)"
created=false

cleanup() {
  if [[ "$created" == true ]]; then
    aws lambda delete-function --function-name "$function_name" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

printf '%s\n' \
  'def handler(event, context):' \
  '    return {"statusCode": 200, "body": "LabRole assumida pela Lambda"}' \
  >"$work_dir/handler.py"
(
  cd "$work_dir"
  zip -q function.zip handler.py
)

echo "Criando uma Lambda temporaria sem VPC para testar a trust policy da LabRole..."
if ! create_error="$(aws lambda create-function \
  --function-name "$function_name" \
  --runtime python3.12 \
  --handler handler.handler \
  --role "$role_arn" \
  --zip-file "fileb://$work_dir/function.zip" \
  --timeout 5 \
  --memory-size 128 \
  --query FunctionArn \
  --output text 2>&1)"; then
  echo "FALHOU: a Lambda temporaria nao foi criada." >&2
  if grep -qiE 'cannot be assumed by Lambda|trust|lambda.amazonaws.com' <<<"$create_error"; then
    echo "VEREDITO: LabRole NAO e assumivel por Lambda (trust policy incompatível)." >&2
  elif grep -qiE 'AccessDenied|not authorized' <<<"$create_error"; then
    echo "VEREDITO: INCONCLUSIVO; a sessao nao permite lambda:CreateFunction." >&2
  else
    echo "VEREDITO: INCONCLUSIVO; erro inesperado ao criar a funcao." >&2
  fi
  # A mensagem AWS e util como evidencia, mas remove numeros longos/ARNs da conta.
  sed -E 's/[0-9]{12}/<ACCOUNT_ID>/g; s#arn:aws:[^ ]+#<ARN>#g' <<<"$create_error" >&2
  exit 1
fi
created=true

aws lambda wait function-active-v2 --function-name "$function_name"
aws lambda invoke \
  --function-name "$function_name" \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  "$work_dir/response.json" >/dev/null

python - "$work_dir/response.json" <<'PY'
import json
import pathlib
import sys

response = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if response.get("statusCode") != 200:
    raise SystemExit(f"Invocacao retornou resposta inesperada: {response}")
PY

echo "VEREDITO: APROVADO — a LabRole foi assumida e a Lambda temporaria respondeu 200."
echo "LIMPEZA: a funcao temporaria sera removida automaticamente."
