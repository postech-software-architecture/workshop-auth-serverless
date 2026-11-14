# Autenticação CPF — Fase 4 no AWS Academy

O runtime resolve identidade por HTTP em OS, sem JDBC. CPF, handler e JWT foram preservados. IDENTITY_URL aponta para o listener privado 8081 do NLB novo; AUTH_SERVICE_TOKEN deve coincidir com OS; JWT_SECRET é compartilhado.

A pasta infra suporta dois modos: `fresh` cria a primeira candidata sem depender de Lambda, alias ou NLB antigos; `legacy` preserva o alias e fallback existentes. Mantém função auth-cpf, LabRole, backend serverless/terraform.tfstate e ADOT/New Relic. Os blocos moved preservam seis objetos existentes ao condicionar sua criação. Não cria IAM role/policy nem state paralelo.

Os workflows usam credenciais temporárias Academy centralizadas e Environment prod. O bootstrap fresh não ativa acesso público: a candidata numerada é testada contra a OS, suas credenciais e JWT antes de criar alias/rotas. O apply repete esse teste antes da promoção. O endereço privado é descoberto pelo NLB; o smoke usa a URL da API produzida pelo Terraform.

[Bootstrap, ativação e rollback](docs/AUTH-BOOTSTRAP.md). [Contexto Academy](docs/ACADEMY.md). Executar `mvn -B clean verify`, `python -m unittest discover -s scripts/tests -v` e `terraform -chdir=infra test` após init com backend desabilitado para os testes mockados. Plan/apply e teste real da candidata são verificações distintas do CI.
