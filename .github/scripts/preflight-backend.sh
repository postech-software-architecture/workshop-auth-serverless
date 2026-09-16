#!/usr/bin/env bash
# Pre-voo do backend Terraform. Identico nos tres repositorios do projeto:
# workshop-infra-kubernetes, workshop-infra-database e workshop-auth-serverless.
# Ao alterar um, alterar os outros dois.
#
# Valida, nesta ordem:
#   1. a sessao AWS, distinguindo credencial expirada de erro de rede;
#   2. o bucket de state e as quatro garantias de hardening;
#   3. a tabela de lock;
#   4. opcionalmente o objeto de state deste componente, aceitando a ausencia
#      dele como primeiro apply.
#
# Variaveis:
#   TFSTATE_BUCKET      obrigatoria
#   TFSTATE_LOCK_TABLE  obrigatoria
#   TFSTATE_KEY         opcional; quando definida, verifica o objeto de state
#   MASK_VARS           opcional; nomes de variaveis a mascarar no log

set -Eeuo pipefail

: "${TFSTATE_BUCKET:?Variavel de Environment TFSTATE_BUCKET ausente}"
: "${TFSTATE_LOCK_TABLE:?Variavel de Environment TFSTATE_LOCK_TABLE ausente}"

# Mascara segredos antes de qualquer comando poder ecoa-los.
for var in ${MASK_VARS:-TF_VAR_db_password TF_VAR_jwt_secret TF_VAR_new_relic_license_key TF_VAR_new_relic_api_key}; do
  value="${!var:-}"
  # Um '[[ ... ]] && echo' aqui encerraria o script sob 'set -e' na primeira
  # variavel vazia, porque a lista inteira devolveria 1.
  if [[ -n "${value}" ]]; then
    echo "::add-mask::${value}"
  fi
done

fail() { echo "::error::$1" >&2; exit 1; }

expired_hint='A sessao do AWS Academy dura cerca de quatro horas. Abra o lab, copie o bloco AWS CLI e atualize os secrets AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY e AWS_SESSION_TOKEN no Environment usado por este job.'

# 1. Sessao -----------------------------------------------------------------
if ! account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  fail "Credencial AWS invalida ou expirada. ${expired_hint}"
fi
echo "Conta AWS autenticada: ${account}"

# 2. Bucket de state --------------------------------------------------------
# O head-bucket devolve 403 tanto para sessao expirada quanto para bucket de
# outra conta do lab, e 404 quando o bucket nao existe. Sem separar os casos a
# mensagem do Terraform nao diz qual dos tres aconteceu.
set +e
bucket_error="$(aws s3api head-bucket --bucket "${TFSTATE_BUCKET}" 2>&1 >/dev/null)"
bucket_status=$?
set -e
if (( bucket_status != 0 )); then
  case "${bucket_error}" in
    *404*|*'Not Found'*|*NoSuchBucket*)
      fail "O bucket ${TFSTATE_BUCKET} nao existe na conta ${account}. Confira a variavel TFSTATE_BUCKET do Environment." ;;
    *403*|*Forbidden*|*AccessDenied*)
      fail "Sem acesso ao bucket ${TFSTATE_BUCKET} a partir da conta ${account} (403). Ou a sessao expirou, ou o bucket pertence a outra conta do lab. ${expired_hint}" ;;
    *)
      fail "Falha ao consultar o bucket ${TFSTATE_BUCKET}: ${bucket_error}" ;;
  esac
fi

versioning="$(aws s3api get-bucket-versioning --bucket "${TFSTATE_BUCKET}" --query Status --output text)"
[[ "${versioning}" == 'Enabled' ]] \
  || fail "Versionamento do bucket ${TFSTATE_BUCKET} deve estar Enabled; esta '${versioning}'. Sem versionamento um state corrompido nao tem como ser recuperado."

encryption="$(aws s3api get-bucket-encryption \
  --bucket "${TFSTATE_BUCKET}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
  --output text 2>/dev/null || echo 'None')"
[[ "${encryption}" == 'AES256' || "${encryption}" == 'aws:kms' ]] \
  || fail "Criptografia default do bucket ${TFSTATE_BUCKET} ausente ou invalida ('${encryption}'). O state guarda senha do RDS e segredo do JWT em texto claro."

public_access="$(aws s3api get-public-access-block \
  --bucket "${TFSTATE_BUCKET}" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets] | [?@==`true`] | length(@)' \
  --output text 2>/dev/null || echo 0)"
[[ "${public_access}" == '4' ]] \
  || fail "As quatro flags de Public Access Block do bucket ${TFSTATE_BUCKET} devem estar true; ${public_access} de 4 estao."

# 3. Tabela de lock ---------------------------------------------------------
table_status="$(aws dynamodb describe-table \
  --table-name "${TFSTATE_LOCK_TABLE}" --query 'Table.TableStatus' --output text 2>/dev/null || echo 'AUSENTE')"
[[ "${table_status}" == 'ACTIVE' ]] \
  || fail "A tabela de lock ${TFSTATE_LOCK_TABLE} deve estar ACTIVE; esta '${table_status}'. Sem lock, dois applies simultaneos corrompem o state."

# 4. Objeto de state deste componente ---------------------------------------
if [[ -n "${TFSTATE_KEY:-}" ]]; then
  set +e
  object_error="$(aws s3api head-object --bucket "${TFSTATE_BUCKET}" --key "${TFSTATE_KEY}" 2>&1 >/dev/null)"
  object_status=$?
  set -e
  if (( object_status == 0 )); then
    echo "State encontrado em s3://${TFSTATE_BUCKET}/${TFSTATE_KEY}"
  else
    case "${object_error}" in
      *404*|*'Not Found'*)
        echo "::notice::State ${TFSTATE_KEY} ainda nao existe em ${TFSTATE_BUCKET}; o primeiro apply cria o objeto." ;;
      *403*|*Forbidden*|*AccessDenied*)
        fail "Sem acesso a s3://${TFSTATE_BUCKET}/${TFSTATE_KEY} (403), embora o bucket responda. Verifique a policy do objeto. ${expired_hint}" ;;
      *)
        fail "Falha ao consultar s3://${TFSTATE_BUCKET}/${TFSTATE_KEY}: ${object_error}" ;;
    esac
  fi
fi

echo 'Backend validado: sessao, bucket, versionamento, criptografia, Public Access Block e lock.'
