#!/usr/bin/env bash
set -euo pipefail

for variable in CLUSTER_NAME VPC_ID PRIVATE_SUBNET_IDS; do
  [[ -n "${!variable:-}" ]] || {
    echo "ERRO: variavel obrigatoria ausente: $variable" >&2
    exit 2
  }
done
for command in aws kubectl curl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERRO: comando obrigatorio ausente: $command" >&2
    exit 2
  }
done

AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
suffix="${GITHUB_RUN_ID:-local}-$(date +%s)"
namespace="w0-vpclink-spike"
sg_id=""
vpc_link_id=""
api_id=""
diagnostics_written=false

diagnostics() {
  [[ "$diagnostics_written" == false ]] || return 0
  diagnostics_written=true
  echo "::group::Diagnostico do namespace $namespace"
  kubectl get deployment,pod,service -n "$namespace" -o wide --request-timeout=20s || true
  kubectl describe service echo -n "$namespace" --request-timeout=20s || true
  kubectl get events -n "$namespace" --sort-by='.lastTimestamp' --request-timeout=20s || true
  echo "::endgroup::"

  echo "::group::Diagnostico do AWS Load Balancer Controller"
  kubectl get deployment,pod -n kube-system \
    -l app.kubernetes.io/name=aws-load-balancer-controller -o wide --request-timeout=20s || true
  kubectl describe deployment aws-load-balancer-controller -n kube-system --request-timeout=20s || true
  kubectl logs deployment/aws-load-balancer-controller -n kube-system \
    --all-containers=true --tail=200 --request-timeout=20s || true
  echo "::endgroup::"
}

fail() {
  echo "ERRO: $*" >&2
  diagnostics
  exit 1
}

unexpected_failure() {
  local exit_code=$?
  local line=$1
  echo "ERRO: comando inesperadamente falhou na linha $line (exit $exit_code)." >&2
  diagnostics
  exit "$exit_code"
}

cleanup() {
  trap - ERR
  set +e
  echo "Iniciando limpeza dos recursos temporarios..."
  [[ -z "$api_id" ]] || aws apigatewayv2 delete-api --api-id "$api_id" >/dev/null 2>&1 || \
    echo "AVISO: nao foi possivel solicitar a remocao da API $api_id."
  [[ -z "$vpc_link_id" ]] || aws apigatewayv2 delete-vpc-link --vpc-link-id "$vpc_link_id" >/dev/null 2>&1 || \
    echo "AVISO: nao foi possivel solicitar a remocao do VPC Link $vpc_link_id."

  kubectl delete namespace "$namespace" --wait=false --request-timeout=20s >/dev/null 2>&1 || \
    echo "AVISO: nao foi possivel solicitar a remocao do namespace $namespace."
  namespace_status="$(kubectl get namespace "$namespace" -o name --request-timeout=20s 2>&1)"
  namespace_get_exit=$?
  if [[ $namespace_get_exit -eq 0 ]]; then
    kubectl wait --for=delete namespace/"$namespace" --timeout=300s --request-timeout=20s >/dev/null 2>&1 || \
      echo "AVISO: namespace $namespace ainda esta em remocao; verifique-o manualmente."
  elif [[ "$namespace_status" != *NotFound* ]]; then
    echo "AVISO: nao foi possivel confirmar a remocao do namespace: $namespace_status"
  fi
  if [[ -n "$sg_id" ]]; then
    for _ in {1..12}; do
      aws ec2 delete-security-group --group-id "$sg_id" >/dev/null 2>&1 && break
      sleep 10
    done
    aws ec2 describe-security-groups --group-ids "$sg_id" >/dev/null 2>&1 && \
      echo "AVISO: security group $sg_id ainda existe; remova-o depois que as ENIs do VPC Link desaparecerem."
  fi
  echo "Rotina de limpeza automatica finalizada; confira os avisos acima."
}
trap cleanup EXIT
trap 'unexpected_failure $LINENO' ERR

echo "Atualizando kubeconfig e criando backend temporario..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
kubectl rollout status deployment/aws-load-balancer-controller \
  -n kube-system --timeout=120s >/dev/null
kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<'YAML' | kubectl apply -n "$namespace" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
spec:
  replicas: 1
  selector:
    matchLabels: {app: echo}
  template:
    metadata:
      labels: {app: echo}
    spec:
      containers:
        - name: echo
          image: public.ecr.aws/nginx/nginx:stable-alpine
          ports:
            - {containerPort: 80}
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  type: LoadBalancer
  selector: {app: echo}
  ports:
    - {name: http, port: 80, targetPort: 80}
YAML
kubectl wait -n "$namespace" --for=condition=available deployment/echo --timeout=180s >/dev/null

nlb_dns=""
for _ in {1..60}; do
  nlb_dns="$(kubectl get service echo -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$nlb_dns" ]] && break
  sleep 10
done
if [[ -z "$nlb_dns" ]]; then
  fail "NLB nao recebeu DNS em 10 minutos."
fi

nlb_arn="$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='${nlb_dns}'].LoadBalancerArn | [0]" --output text)"
[[ "$nlb_arn" != None && -n "$nlb_arn" ]] || fail "NLB nao encontrado na API ELBv2."
scheme="$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb_arn" --query 'LoadBalancers[0].Scheme' --output text)"
[[ "$scheme" == internal ]] || fail "o Load Balancer criado nao e interno (scheme=$scheme)."

listener_arn=""
for _ in {1..30}; do
  listener_arn="$(aws elbv2 describe-listeners --load-balancer-arn "$nlb_arn" --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)"
  [[ -n "$listener_arn" && "$listener_arn" != None ]] && break
  sleep 10
done
[[ -n "$listener_arn" && "$listener_arn" != None ]] || fail "listener do NLB nao encontrado."

sg_id="$(aws ec2 create-security-group \
  --group-name "w0-vpclink-${suffix}" \
  --description 'Temporary W0 VPC Link validation' \
  --vpc-id "$VPC_ID" \
  --query GroupId --output text)"
IFS=', ' read -r -a subnet_ids <<<"${PRIVATE_SUBNET_IDS//,/ }"
vpc_link_id="$(aws apigatewayv2 create-vpc-link \
  --name "w0-vpclink-${suffix}" \
  --subnet-ids "${subnet_ids[@]}" \
  --security-group-ids "$sg_id" \
  --query VpcLinkId --output text)"

status=""
for _ in {1..60}; do
  status="$(aws apigatewayv2 get-vpc-link --vpc-link-id "$vpc_link_id" --query VpcLinkStatus --output text)"
  [[ "$status" == AVAILABLE ]] && break
  [[ "$status" == FAILED || "$status" == INACTIVE ]] && break
  sleep 10
done
[[ "$status" == AVAILABLE ]] || fail "VPC Link terminou com status $status."

api_id="$(aws apigatewayv2 create-api --name "w0-vpclink-${suffix}" --protocol-type HTTP --query ApiId --output text)"
integration_id="$(aws apigatewayv2 create-integration \
  --api-id "$api_id" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --connection-type VPC_LINK \
  --connection-id "$vpc_link_id" \
  --integration-uri "$listener_arn" \
  --payload-format-version 1.0 \
  --query IntegrationId --output text)"
aws apigatewayv2 create-route --api-id "$api_id" --route-key '$default' --target "integrations/$integration_id" >/dev/null
aws apigatewayv2 create-stage --api-id "$api_id" --stage-name '$default' --auto-deploy >/dev/null

endpoint="https://${api_id}.execute-api.${AWS_REGION}.amazonaws.com/"
http_status=""
for _ in {1..30}; do
  http_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "$endpoint" || true)"
  [[ "$http_status" == 200 ]] && break
  sleep 10
done
[[ "$http_status" == 200 ]] || fail "Gateway -> VPC Link -> NLB respondeu HTTP $http_status."

echo "VEREDITO: APROVADO — NLB interno, VPC Link AVAILABLE e proxy HTTP responderam 200."
echo "LIMPEZA: API, VPC Link, namespace/NLB e security group temporarios serao removidos."
