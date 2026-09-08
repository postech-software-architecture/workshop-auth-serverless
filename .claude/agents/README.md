# Agentes deste repositorio

Prompts-modelo copiados do repositorio canonico
[workshop-service-fase1](https://github.com/postech-software-architecture/workshop-service-fase1)
(`.claude/agents/`), conforme o plano de orquestracao da Fase 3.

| Agente | Papel neste repo |
|---|---|
| `serverless-lambda` | Dono do conteudo deste repositorio |
| `repo-governance` | Settings, branch protection, Environments e secrets |
| `cicd-pipelines` | Conteudo de `.github/workflows/**` |

**Regra de fronteira:** exatamente um agente escreve num dado caminho.
Cada prompt declara `Owns` e `Nao toca`.

A fonte canonica e o repo da aplicacao. Ao alterar um prompt, altere lá
e replique aqui — nao divirja.
