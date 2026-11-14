# Auth em laboratório novo ou com infraestrutura existente

O runtime usa a identidade da OS por HTTP privado. Não acessa o RDS e não recebe
DB_PASSWORD. Mantém Java 21, LabRole, ADOT/New Relic, os nomes dos recursos e o
backend `serverless/terraform.tfstate`, separado de cluster/database.

## Novo laboratório: AUTH_DEPLOYMENT_MODE=fresh

1. Conferir a fundação e o NLB interno `workshop-fase4-internal`, na mesma VPC do
   cluster, com listener de negócio 80 e listener de identidade 8081.
2. Configurar as Variables do prod: AWS_REGION=us-east-1, TFSTATE_BUCKET com o bucket
   atual, TFSTATE_LOCK_TABLE com a tabela atual, ADOT_LAYER_ARN regional válido,
   AUTH_DEPLOYMENT_MODE=fresh e FASE4_ROUTES_ENABLED=false. Deixar
   AUTH_VERSION_OVERRIDE ausente/vazio na primeira execução. IDENTITY_URL é opcional:
   vazio descobre o DNS privado pelo NLB; um override deve ser exatamente esse DNS:8081.
3. JWT_SECRET e AUTH_SERVICE_TOKEN devem vir da **mesma fonte privada original** usada
   na plataforma/OS. Não gerar outros. AWS e NEW_RELIC_LICENSE_KEY vêm dos secrets da
   organização, com acesso selecionado para Auth. Não cadastrar credenciais SQL.
4. Executar o CD na main com action=plan. O guard também roda no plan e recusa alterações
   destrutivas, IAM/EKS/RDS e tentativa de ativar alias/rotas durante bootstrap.
5. Executar action=apply e confirmação `APLICAR SERVERLESS PROD`. Esse primeiro apply
   cria a função e publica uma versão candidata, além da infraestrutura base da API.
   Não consulta alias/NLB antigos e não cria alias prod, permissão de invocação pelo
   Gateway, rota de autenticação, rotas de negócio ou fallback `$default`.
   A URL da API existe, mas ainda não oferece o fluxo público. O post-check registra
   AUTH_CANDIDATE_VERSION e não exige resposta de uma rota ainda desabilitada.
6. Preparar uma identidade de demonstração **elegível na OS atual** e cadastrar seu CPF
   como TEST_CPF privado no prod. Executar action=validate, candidate_version com o
   número publicado. O teste confirma a configuração da versão, URL privada, tokens,
   ExecutedVersion, autenticação HTTP pela OS e assinatura/claims do JWT. Não move alias,
   não habilita rotas e não imprime CPF/JWT/segredos. Um CPF inexistente/inativo falha.
7. Após validação bem-sucedida, definir AUTH_VERSION_OVERRIDE com esse número e
   FASE4_ROUTES_ENABLED=true. Executar plan e apply. O apply **repete o teste da versão
   antes de qualquer mudança**, cria o alias/rota CPF e as rotas específicas para a nova
   borda. Nenhuma integração pública usa o listener 8081. O smoke usa a URL realmente
   produzida pelo Terraform; não reutiliza uma variável de URL da conta antiga.

Manter AUTH_VERSION_OVERRIDE preenchido depois da ativação. Esvaziá-lo não é rollback:
tentaria retirar o alias/rotas, e o guard recusará. Para publicar uma próxima candidata
sem mover prod, manter selecionada a versão anterior. Após testá-la, selecionar a nova.
O build pode publicar uma versão adicional durante a promoção; o alias sempre usa o
número explicitamente selecionado e testado, não `$LATEST` nem a versão recém-gerada
implicitamente. Para rollback, selecionar uma versão numerada compatível com as
credenciais/identidade atuais; o mesmo teste é obrigatório antes do apply.

## Ambiente legado: AUTH_DEPLOYMENT_MODE=legacy (padrão)

Manter esse modo quando o state já gerencia a infraestrutura antiga. O alias prod é
consultado e preservado quando AUTH_VERSION_OVERRIDE está vazio; o NLB antigo
`workshop-api-internal`, sua integração e o `$default` continuam presentes. A identidade
HTTP da candidata usa o NLB da plataforma Fase 4. A ativação de rotas novas continua
opt-in e exige uma versão HTTP testada. Não mudar um state existente para fresh para
contornar validação, nem importar a mesma função para um segundo state.

Os blocos `moved` convertem seis endereços gerenciados para `[0]` ao adicionar `count`,
preservando os objetos existentes. Não são imports nem replacements. O guard continua
recusando delete/replace de objetos antigos. A opção allow_phase4_route_rollback permite
somente remover as rotas/integração **adicionais** da Fase 4, mantendo o fallback legado.
No laboratório fresh não existe fallback antigo a ser reativado.

## Verificações e limites

O CI executa testes Java, fmt/validate, cinco cenários Terraform com provider e remote
state mockados, e testes Python do guard, candidato e smoke. Os mocks não acessam AWS.
Cobrem bootstrap sem legado, ativação numerada, preservação do legado e rejeição de
identidade/credenciais incompatíveis. O plan real ainda precisa confirmar inventário,
permissões do Academy, NLB disponível e compatibilidade da layer ADOT.

TEST_CPF requer dados de demonstração reais no banco da OS atual; testes unitários não
substituem essa validação. Pagamento/webhook/estorno e observabilidade continuam etapas
posteriores. Esta alteração não cria IAM, VPC, EKS, RDS nem modifica seus states.

Referências: [moved](https://developer.hashicorp.com/terraform/language/block/moved),
[private integration](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-private.html).
