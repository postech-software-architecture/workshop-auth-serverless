#!/usr/bin/env bash
set -Eeuo pipefail

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

cleanup() {
  set +e
  [[ -n "$api_id" ]] && aws apigatewayv2 delete-api --api-id "$api_id" >/dev/null 2>&1
  [[ -n "$vpc_link_id" ]] && aws apigatewayv2 delete-vpc-link --vpc-link-id "$vpc_link_id" >/dev/null 2>&1
  kubectl delete namespace "$namespace" --wait=false >/dev/null 2>&1
  if [[ -n "$sg_id" ]]; then
    for _ in {1..12}; do
      aws ec2 delete-security-group --group-id "$sg_id" >/dev/null 2>&1 && break
      sleep 10
    done
  fi
}
trap cleanup EXIT

echo "Atualizando kubeconfig e criando backend temporario..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
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
[[ -n "$nlb_dns" ]] || { echo "ERRO: NLB nao recebeu DNS em 10 minutos." >&2; exit 1; }

nlb_arn="$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='${nlb_dns}'].LoadBalancerArn | [0]" --output text)"
[[ "$nlb_arn" != None && -n "$nlb_arn" ]] || { echo "ERRO: NLB nao encontrado na API ELBv2." >&2; exit 1; }
scheme="$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb_arn" --query 'LoadBalancers[0].Scheme' --output text)"
[[ "$scheme" == internal ]] || { echo "ERRO: o Load Balancer criado nao e interno (scheme=$scheme)." >&2; exit 1; }

listener_arn=""
for _ in {1..30}; do
  listener_arn="$(aws elbv2 describe-listeners --load-balancer-arn "$nlb_arn" --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)"
  [[ -n "$listener_arn" && "$listener_arn" != None ]] && break
  sleep 10
done
[[ -n "$listener_arn" && "$listener_arn" != None ]] || { echo "ERRO: listener do NLB nao encontrado." >&2; exit 1; }

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
[[ "$status" == AVAILABLE ]] || { echo "ERRO: VPC Link terminou com status $status." >&2; exit 1; }

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
[[ "$http_status" == 200 ]] || { echo "ERRO: Gateway -> VPC Link -> NLB respondeu HTTP $http_status." >&2; exit 1; }

echo "VEREDITO: APROVADO — NLB interno, VPC Link AVAILABLE e proxy HTTP responderam 200."
echo "LIMPEZA: API, VPC Link, namespace/NLB e security group temporarios serao removidos."
