# workshop-auth-serverless

Parte da entrega da **Fase 3** do Tech Challenge (SOAT).
Repositorio segregado conforme o plano de orquestracao.

## Estado

Esqueleto inicial. O conteudo e entregue nas ondas seguintes do plano.

Os preflights executáveis dos riscos da W0 estão em
[`docs/w0-spikes.md`](docs/w0-spikes.md). Eles são acionados manualmente, usam recursos
temporários e não fazem parte da CI comum.

## State remoto da W4

O Terraform serverless guarda seu state em S3, na chave
`serverless/terraform.tfstate`, e usa uma tabela DynamoDB para lock. Antes de executar
o workflow **W4 — Serverless CI, plan e deploy** manualmente, crie estas *Environment
variables* no environment GitHub `prod` (não são secrets):

- `TFSTATE_BUCKET`: bucket S3 que já contém os states `cluster/terraform.tfstate` e
  `database/terraform.tfstate`;
- `TFSTATE_LOCK_TABLE`: tabela DynamoDB de lock do Terraform para esse bucket.

O workflow valida ambas antes de `terraform init`, configura seu backend com elas e
também as fornece como os buckets de state do cluster e do banco. Não registre valores
reais de bucket, tabela, credenciais ou senhas neste repositório.

## Agentes

Ver [.claude/agents/README.md](.claude/agents/README.md).
