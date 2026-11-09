# Autenticação CPF — Fase 4 no AWS Academy

O runtime resolve identidade por HTTP em OS, sem JDBC. CPF, handler e JWT foram preservados. IDENTITY_URL aponta para o listener privado 8081 do NLB novo; AUTH_SERVICE_TOKEN deve coincidir com OS; JWT_SECRET é compartilhado.

A pasta infra foi adaptada da infraestrutura existente: mesmos endereços Terraform, função auth-cpf, alias prod, LabRole, backend serverless/terraform.tfstate, ADOT/New Relic e API Gateway/VPC Link. Não há criação de role IAM ou state paralelo. As rotas adicionais ficam desligadas por padrão e não alteram o fallback antigo sem corte explícito.

Os workflows preservam as credenciais temporárias Academy e o Environment prod. O CD adaptado fornece as variáveis HTTP, exige plano não destrutivo e permite rollback restrito das rotas adicionais e seleção de versão publicada anterior no alias. Não usar o CD anterior com o runtime HTTP.

[Configuração, ordem de execução e limites](docs/ACADEMY.md). Executar `mvn -B clean verify` para verificar o runtime; 15 testes anteriores foram aprovados na cópia local. Terraform foi validado localmente em 09/11/2026; não houve plan/apply remoto, corte de tráfego ou prova integrada da Lambda.
