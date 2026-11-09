# Execução compatível com AWS Academy

Atualizado em 09/11/2026. Os arquivos abaixo foram preparados e verificados localmente; não houve apply, corte de tráfego, pagamento ou acesso ao state remoto.

## Contratos preservados

- Credenciais temporárias: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY e AWS_SESSION_TOKEN, com Environment `prod`. Não há OIDC/role-to-assume nos novos deploys.
- Lambda mantém `data.aws_iam_role.lab`/LabRole, nome auth-cpf, alias prod, VPC Link, API Gateway, logs, layer ADOT e endereços Terraform existentes. Não cria IAM role/policy. O backend continua `serverless/terraform.tfstate`.
- A borda anterior e seu `$default` permanecem. `FASE4_ROUTES_ENABLED=false` por padrão. Rotas novas são opt-in e usam outro NLB interno, `workshop-fase4-internal`, por listener80. A identidade da Lambda usa exclusivamente o listener8081; `/internal` é bloqueado no listener público.
- VPC/EKS/RDS existentes e seus states não são substituídos. Os bancos `os_fase4` e `billing_fase4` são bancos lógicos distintos no mesmo RDS, com proprietários e credenciais diferentes e CONNECT revogado para PUBLIC. Não é isolamento físico de instância. A decisão reduz alterações no Academy e precisa constar na apresentação.

## Preparação da plataforma

No repo `workshop-infra-platform`, definir no Environment prod:

Variables: `AWS_REGION`, `EKS_CLUSTER_NAME`, `RDS_HOST` (hostname privado, sem protocolo), `STORAGE_CLASS` já operacional no cluster. Secrets AWS temporários e os nomes exigidos por `prepare-secrets.py`: RDS_ADMIN_USER/PASSWORD, OS_DB_PASSWORD, BILLING_DB_PASSWORD, JWT_SECRET, AUTH_SERVICE_TOKEN, tokens técnicos e senhas Rabbit/Mongo, NEW_RELIC_LICENSE_KEY. O usuário RDS administrativo vem da infraestrutura anterior; não presumir seu nome.

AUTH_SERVICE_TOKEN deve ter 32 ou mais caracteres e ser igual em OS e Lambda. Senhas de OS e Billing devem ser distintas. RDS_ADMIN_PASSWORD só é usada pelo Job de bootstrap, não pelas aplicações. Não colocar valores no chat ou em commits.

`deploy-academy-platform` exige a confirmação textual **O texto exato é `APLICAR PLATAFORMA FASE4`**. Executa preflight da sessão, cluster, StorageClass, controller de LB e CSI EBS quando aplicável; não instala drivers nem cria roles para contornar bloqueio do Academy. Se o requisito estiver indisponível, aborta antes do apply.

O workflow prepara Secrets sem imprimir valores, faz dry-run de servidor, aplica apenas recursos novos e espera bootstrap/rollout. O bootstrap não rotaciona senhas existentes silenciosamente; se uma senha não autenticar ou um banco existente tiver outro dono, falha. Não apagar state/volumes/RDS para contornar a falha. Jobs concluídos não repetem automaticamente uma rotação de credenciais; tratar essa operação em janela própria, com revisão.

Mongo/Rabbit continuam em PVCs de uma réplica. A StorageClass deve existir e seu provisioner deve funcionar com as permissões atuais. Nenhuma nova role é criada. Backup, restauração e disponibilidade ainda exigem teste real; manter os backups nativos do RDS anterior. Interromper se o cluster não tiver capacidade para os workloads novos.

## Serviços e validação antes do corte

Cada app usa `publish-and-deploy`, na main, Environment prod e as mesmas credenciais AWS temporárias. Configurar AWS_REGION, EKS_CLUSTER_NAME e RDS_HOST. O renderizador resolve somente IPs privados do RDS e restringe egress SQL a esses /32. Depois de failover ou mudança dos IPs do RDS, renderizar/reaplicar essas políticas antes de retomar a aplicação. O renderer não modifica DNS, SG, IAM ou state.

Cada app deve usar o Secret `<runtime>-config` criado pela plataforma. Configuração do registry `ghcr-pull` permanece necessária quando as imagens não forem públicas. O ambiente anterior continua acessível enquanto se testa o novo NLB por acesso privado/port-forward. O listener8080 do pod edge permite os prefixos /os, /billing, /execution dos roteiros locais.

Antes de habilitar cobrança, preencher os MP_* em Secrets da plataforma e definir PAYMENTS_ENABLED=true na Variable do repo Billing; NOTIFICATIONS_ENABLED e MAIL_* habilitam SMTP por opção. Ausência de configuração não produz cobrança ou envio fictício.

## Lambda e corte da borda

No auth, preservar as configurações existentes de backend/ADOT/New Relic. Acrescentar `IDENTITY_URL=http://<DNS-privado-do-NLB-novo>:8081` como Variable e `AUTH_SERVICE_TOKEN` como Secret. DB_* e o acesso JDBC saíram da função. Não tentar usar o CD antigo com o runtime novo; o pacote inclui o CD adaptado. Preflight exige os dois novos valores antes de plan/apply.

O apply gera plano e passa por `scripts/guard-academy-plan.py`, que recusa delete/replace e alterações gerenciadas IAM/EKS/RDS. Não usar esse guard em destroy; o destroy continua explicitamente confirmado e limitado ao state serverless. Identificar o state correto antes de qualquer execução. Não importar ou duplicar a função existente em outro state.

O primeiro apply publica a versão candidata, mas preserva por padrão a versão atual do alias prod. Obter auth_candidate_version no output e validar com `python scripts/test-candidate.py --function workshop-auth-cpf --version <numero>`, usando TEST_CPF e JWT_SECRET privados no ambiente. O script invoca somente a versão numerada, confirma elegibilidade/JWT e não imprime CPF/token nem altera alias. Depois definir AUTH_VERSION_OVERRIDE para a versão testada e executar o corte explicitamente. FASE4_ROUTES_ENABLED=true adiciona rotas específicas da fase4 pelo VPC Link existente. O `$default` continua apontando ao destino anterior; `/api/auth/cpf` continua na Lambda. Para voltar à borda anterior, definir FASE4_ROUTES_ENABLED=false e marcar allow_phase4_route_rollback no despacho manual. A exceção permite remover SOMENTE as rotas e a integração adicionais fase4; continua proibindo delete/replace de recursos antigos. Para a Lambda, AUTH_VERSION_OVERRIDE seleciona uma versão publicada anterior pelo alias prod, conservando o código/configuração imutáveis daquela versão. Planejar e validar juntos o rollback da borda e do alias. Não apenas restaurar variáveis DB_* no runtime HTTP.

Referências AWS: [integrações privadas HTTP API](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-private.html) e [prioridade de rotas](https://docs.aws.amazon.com/en_en/apigateway/latest/developerguide/http-api-develop-routes.html).

## Validação local sem conta

Em `integracao/`: `python configure.py` preserva o `.env` existente e acrescenta somente a credencial AUTH_SERVICE_TOKEN que faltar. Compose base + demo não habilita pagamentos nem SMTP.

Para pagamentos, copiar `mercado-pago.env.example` para um arquivo privado `mercado-pago.env`, preencher localmente e combinar `--env-file .env --env-file mercado-pago.env -f compose.yml -f compose.demo.yml -f compose.payments.yml`. A interpolação obrigatória recusa os campos ausentes. A URL HTTPS do webhook deve chegar ao Billing real; configurar essa URL na conta escolhida, sem publicar /internal.

O BDD/verify-phase4 também precisa das credenciais MP no ambiente do runner para consulta independente. Fora do BDD, pode usar `--provider-env-file mercado-pago.env`. O roteiro não cria pagamento fictício. Para aceitar cancelamento, usar OS paga, sem reparo iniciado, com insumos consumidos e estoque isolado: verifica recurso externo, estorno confirmado, movimentos e saldo e repete o cancelamento. Concomitância de outra OS no mesmo saldo faz o teste falhar em vez de atestar uma prova ambígua.

## PDF institucional

Preencher `ops/participants.json` com cinco objetos `{ "name": "Nome real", "identification": "Identificação real" }`. Não alterar flags de delivery-links.json antes das provas. `ops/build-report.py --final` recusa nomes/IDs ausentes ou repetidos, links inválidos, cobertura insuficiente e falta de BDD integrado real. Dry-run do Cucumber não preenche essa prova. O gerador pode ser executado no repo de plataforma exportado; requer `reportlab` e as evidências em docs/evidencias.

## Pendências externas efetivas

Conta Mercado Pago, valores secretos e IDs reais, sessão Academy ativa, recursos/driver existentes, execução integrada/restore/rollout, participantes, gravação do vídeo e publicação permanecem ações reais por realizar. Os arquivos e verificadores para essas etapas estão preparados; sua presença não equivale a execução.
