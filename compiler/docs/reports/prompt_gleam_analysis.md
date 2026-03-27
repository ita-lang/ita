# Prompt: Analise do Servidor Gleam para Migracao

Cole este prompt inteiro em uma conversa com IA junto com o codigo do seu servidor Gleam.

---

## Contexto

Estou avaliando migrar este servidor Gleam para uma linguagem propria chamada **Ita** que compila para Dart Kernel (.dill) e roda na Dart VM. Preciso de uma analise tecnica completa para mapear o gap entre o que o servidor faz e o que a linguagem Ita ja suporta.

## O que preciso que voce analise

### 1. Arquitetura Geral
- Qual o tipo de aplicacao? (API REST, GraphQL, WebSocket real-time, SSR, etc.)
- Qual o framework principal? (Wisp, Mist, Phoenix bridge, outro?)
- Quantas rotas/endpoints existem? Liste todos com metodo HTTP e path
- Tem middleware? Quais? (auth, cors, logging, rate limit, etc.)
- Qual o padrao de arquitetura? (MVC, Clean Architecture, hexagonal, etc.)
- Tem background jobs ou workers? O que fazem?

### 2. Banco de Dados
- Qual banco? (PostgreSQL, SQLite, MySQL, Redis, etc.)
- Usa ORM ou queries raw?
- Quantas tabelas/modelos existem? Liste com campos principais
- Tem migrations?
- Usa connection pooling?
- Tem transactions complexas?

### 3. Autenticacao e Seguranca
- Que tipo de auth? (JWT, session, OAuth, API keys, etc.)
- Tem RBAC (roles/permissoes)?
- Tem CORS configurado?
- Tem rate limiting?
- Tem CSRF protection?
- Tem validacao de input?

### 4. Comunicacao Externa
- Chama APIs externas? Quais?
- Tem WebSocket? Para que?
- Tem Server-Sent Events (SSE)?
- Tem upload/download de arquivos?
- Tem envio de email?
- Tem integracao com servicos cloud (S3, SQS, etc.)?

### 5. Dependencias
- Liste TODAS as dependencias do gleam.toml/mix.exs com o que cada uma faz
- Quais sao de Gleam puro vs Erlang/Elixir?
- Quais sao criticas (sem alternativa facil)?

### 6. Concorrencia e Performance
- Usa processos OTP/GenServer/Supervisor?
- Tem pub/sub ou message queues?
- Tem cache em memoria?
- Tem connection pooling?
- Quantas requests/segundo precisa aguentar?
- Tem operacoes CPU-intensive?

### 7. Deploy e Infra
- Onde roda? (Docker, Fly.io, AWS, VPS, etc.)
- Tem CI/CD?
- Tem health check endpoint?
- Tem graceful shutdown?
- Tem structured logging?
- Variaveis de ambiente usadas?

### 8. Testes
- Tem testes? Quantos?
- Que tipo? (unit, integration, e2e)
- Usa mocks?
- Qual o coverage aproximado?

### 9. Coisas do Elixir/Erlang que NAO sao Gleam
- Quais partes tiveram que ser escritas em Elixir/Phoenix? Por que?
- O que o Gleam nao conseguiu fazer que forcou o fallback?
- Quais libs Erlang/Elixir sao usadas via FFI?

## Formato da resposta

Responda em formato de tabela/lista para cada secao. No final, faca um resumo com:

1. **Complexidade geral** (simples, media, complexa)
2. **Features criticas** — lista das 5 features mais importantes para o servidor funcionar
3. **Dependencias externas criticas** — o que precisa existir como lib/driver
4. **Pontos de risco** — onde a migracao seria mais dificil
5. **Estimativa** — quais partes poderiam ser migradas hoje vs o que precisa ser construido antes
