# Observabilidade ADOT da Lambda

O Terraform configura a função Java 21 com a camada AWS Distro for OpenTelemetry
(ADOT), o wrapper Java e o collector empacotado em `collector.yaml`. O SDK da
função envia traces, métricas e logs para o collector local; o collector envia
os sinais ao endpoint OTLP do New Relic.

## Variáveis obrigatórias

Os valores devem ser fornecidos pelo GitHub Environment `prod` ou por um
ambiente local seguro. Não commite `.tfvars` com segredos.

- `TF_VAR_adot_layer_arn`: ARN regional da camada ADOT Java compatível com Java 21.
- `TF_VAR_new_relic_api_key`: secret de ingestão do New Relic.
- `TF_VAR_service_version`: SHA hexadecimal do commit implantado.

`TF_VAR_new_relic_otlp_endpoint` é opcional e usa
`https://otlp.nr-data.net:4317` por padrão. A pipeline injeta o SHA da execução
e valida o ARN e o endpoint antes de executar `plan` ou `apply`.

O workflow continua sem deploy em pull requests. O deploy exige execução manual,
Environment `prod` e a confirmação literal `APLICAR SERVERLESS PROD`.
