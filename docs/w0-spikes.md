# Spikes W0: validação operacional

Os scripts deste repositório não são executados pela CI comum. Eles só rodam por acionamento
manual do workflow **W0 — spikes controlados**, no Environment escolhido. Nenhum secret é
impresso. Os spikes AWS criam recursos temporários e tentam removê-los mesmo quando falham.

## Pré-requisitos no Environment `prod`

Secrets:

- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` (sessão atual do Academy);
- `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`.

Os nomes são os padrões do OpenTelemetry e não prendem o projeto a um fornecedor. Exemplos
de configuração (grave os valores como secrets, nunca no repositório):

- Grafana Cloud: endpoint OTLP da stack; headers com
  `Authorization=Basic <base64(instance-id:access-policy-token)>`;
- New Relic: endpoint OTLP regional; headers com `api-key=<license-key>`.

A escolha do backend continua sendo uma decisão arquitetural separada; este spike funciona
com qualquer destino que aceite OTLP/HTTP JSON.

Variables opcionais:

- `AWS_REGION` (padrão `us-east-1`);
- `LAB_ROLE_ARN` (se omitida, usa `arn:aws:iam::<conta>:role/LabRole`).

## Ordem recomendada

### 1. Ingestão OTLP (Grafana Cloud ou New Relic)

No GitHub, abra **Actions → W0 — spikes controlados → Run workflow**:

- `spike`: `otlp-ingestion`;
- `environment`: `prod`;
- deixe os demais campos vazios.

O job envia um único trace sem dados de negócio. Sucesso técnico é HTTP `2xx`. Para a prova
funcional, copie o `Trace ID` do log e procure no explorador de traces do fornecedor, ou filtre
por `service.name = workshop-w0-otlp-spike`. Guarde uma captura sem token.

### 2. LabRole assumível por Lambda

Escolha `labrole-lambda` e escreva `CRIAR-E-LIMPAR` na confirmação. O job cria uma função
Python mínima, espera ficar ativa, invoca, exige resposta `200` e a apaga. Esse teste é mais
forte que apenas ler a trust policy.

- `APROVADO`: a LabRole pode ser usada no desenho final da Lambda;
- erro `cannot be assumed by Lambda`: trust policy incompatível, aplicar o fallback arquitetural;
- `AccessDenied` em `CreateFunction`: inconclusivo; a sessão não permite realizar o spike.

Ao final, confirme em **AWS Console → Lambda → Functions** que não restou função iniciada por
`w0-labrole-spike-`.

### 3. VPC Link + NLB interno

Execute enquanto o EKS e o AWS Load Balancer Controller estiverem ativos. Obtenha os campos no
repo de Kubernetes:

```bash
terraform output -raw cluster_name
terraform output -raw vpc_id
terraform output -json private_subnet_ids | jq -r 'join(",")'
```

No workflow, escolha `vpclink-nlb`, confirme com `CRIAR-E-LIMPAR` e informe o cluster, a VPC e
cole a saída do terceiro comando no campo de subnets privadas. Ela já estará separada por
vírgulas, no formato aceito pelo script. O job cria um namespace de teste, um NLB interno,
um VPC Link e uma HTTP API temporários. O veredito só é aprovado quando o caminho público do
Gateway até o backend privado responde `200`.

Após o job, confirme que não restaram:

```bash
kubectl get namespace w0-vpclink-spike
aws apigatewayv2 get-vpc-links --query "Items[?starts_with(Name, 'w0-vpclink-')]"
aws elbv2 describe-load-balancers --query "LoadBalancers[?Scheme=='internal'].DNSName"
```

O último comando também lista NLBs internos legítimos; procure apenas o criado durante o job.
Se a limpeza do security group falhar por consistência eventual, procure a descrição
`Temporary W0 VPC Link validation` e remova-o depois que as ENIs do VPC Link desaparecerem.

Se o NLB nao receber DNS no tempo limite, o workflow imprime no proprio log os recursos e
eventos do namespace, o estado do deployment e dos pods do AWS Load Balancer Controller e as
ultimas 200 linhas de log do controller antes de iniciar a limpeza automatica.

## Execução local opcional

Em Linux/WSL com AWS CLI, `kubectl`, `curl`, `zip`, `openssl` e `python`:

```bash
bash scripts/spikes/otlp-ingestion.sh
bash scripts/spikes/lab-role-lambda.sh
CLUSTER_NAME=... VPC_ID=... PRIVATE_SUBNET_IDS=subnet-a,subnet-b \
  bash scripts/spikes/vpc-link-nlb.sh
```

Nunca use `set -x`, pois ele pode exibir tokens e credenciais.
