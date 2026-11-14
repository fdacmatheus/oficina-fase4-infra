# Fase 4 · Arquitetura de microsserviços

Visão geral da plataforma. O detalhe de cada serviço está no README do próprio repositório; a saga orquestrada (fluxo, compensações e a escolha por orquestração) está descrita em detalhe no README do [`oficina-os-service`](https://github.com/fdacmatheus/oficina-os-service).

## Serviços

| Repositório | Responsabilidade | Banco | Fila de entrada (SQS) |
|---|---|---|---|
| `oficina-os-service` | Clientes, veículos, catálogo (serviços, peças, estoque), ordem de serviço e histórico. **Orquestrador da saga.** | PostgreSQL | `os-eventos` |
| `oficina-billing-service` | Orçamento, aprovação do cliente, cobrança e estorno no Mercado Pago (API de Orders), webhook | PostgreSQL (instância própria) | `billing-comandos` |
| `oficina-execution-service` | Fila de execução, diagnóstico e reparo, linha do tempo da execução | DynamoDB | `execution-comandos` |

Plataforma (evolução dos repositórios da Fase 3):

| Repositório | Responsabilidade |
|---|---|
| `oficina-fase4-infra` | EKS, API Gateway, as duas Lambdas (casca), NLB interno por serviço, Secrets Manager da plataforma, observabilidade (Prometheus, Grafana, Tempo, Loki, OTel Collector) e o ambiente local |
| `oficina-fase4-lambda-auth` | Código das Lambdas: emissão de token por CPF e authorizer JWT |

## Visão geral

```mermaid
flowchart LR
    U[Cliente / Postman / Mercado Pago]

    subgraph AWS["AWS · us-east-1 (Learner Lab)"]
        GW["API Gateway HTTP API<br/>/auth · /os · /billing · /execution"]
        AUTHZ{{Lambda authorizer<br/>JWT · cache 5 min}}
        TOKEN[Lambda token<br/>CPF → JWT 15 min]
        SM[(Secrets Manager<br/>oficina/plataforma/segredos)]

        subgraph VPC["VPC default"]
            VL[VPC Link]
            subgraph EKS["EKS oficina-eks · 2-4 × t3.medium"]
                NLBOS[NLB interno os] --> OS[os-service<br/>orquestrador da saga]
                NLBB[NLB interno billing] --> B[billing-service]
                NLBE[NLB interno execution] --> E[execution-service]
                subgraph MON["namespace monitoring"]
                    OTEL[OTel Collector] --> TEMPO[Tempo]
                    OTEL --> LOKI[Loki]
                    TEMPO -. service graph .-> PROM[Prometheus]
                    PROM --> GRAF[Grafana<br/>NLB público]
                    TEMPO --> GRAF
                    LOKI --> GRAF
                end
            end
            RDSOS[(RDS Postgres<br/>os)]
            RDSB[(RDS Postgres<br/>billing)]
        end

        DDB[(DynamoDB<br/>oficina-execucoes)]
        QOS[[SQS os-eventos + DLQ]]
        QB[[SQS billing-comandos + DLQ]]
        QE[[SQS execution-comandos + DLQ]]
    end

    MP[Mercado Pago]

    U --> GW
    GW -. rotas protegidas .-> AUTHZ
    GW -- POST /auth --> TOKEN
    GW --> VL --> NLBOS & NLBB & NLBE
    TOKEN -- /api/internos · x-chave-interna --> NLBOS
    TOKEN & AUTHZ -. lê .-> SM

    OS --> RDSOS
    B --> RDSB
    E --> DDB
    OS -- comandos --> QB --> B
    OS -- comandos --> QE --> E
    B -- eventos --> QOS
    E -- eventos --> QOS
    QOS --> OS
    B <--> MP

    OS & B & E -. OTLP traces/logs .-> OTEL
    PROM -. scrape /api/metrics .-> OS & B & E
```

- **Entrada única**: os NLBs são internos; só o API Gateway (via VPC Link) e a Lambda de token (dentro da VPC) os alcançam.
- **Banco por serviço**: nenhum serviço lê o banco de outro; a conversa é por SQS (saga) ou REST.
- **Segredos**: `oficina/plataforma/segredos` é a fonte única de `JWT_SECRET`, `JWT_REFRESH_SECRET`, `ADMIN_PASSWORD` e `INTERNAL_API_KEY`; cada serviço guarda as credenciais do próprio banco em `oficina/<servico>/database`.
- **Observabilidade**: métricas (Prometheus), traces (Tempo) e logs (Loki) correlacionados por `trace_id` e por `correlationId` = id da OS.

Cada serviço tem seu próprio Terraform para o banco e a fila de entrada. Nenhum serviço lê o banco de outro: a conversa é por mensagem (SQS) ou REST.

## Saga orquestrada

Resumo abaixo; a descrição completa (inclusive o porquê de orquestração e não coreografia) está no README do `oficina-os-service`.

O `os-service` guarda o estado da saga junto com a OS, na mesma transação. Ele manda **comandos** para a fila de cada serviço e recebe **eventos** na sua fila.

```mermaid
sequenceDiagram
    participant OS as os-service (orquestrador)
    participant B as billing-service
    participant MP as Mercado Pago
    participant E as execution-service

    OS->>OS: abre OS (RECEBIDA)
    OS->>B: GerarOrcamento
    B-->>OS: OrcamentoGerado → AGUARDANDO_APROVACAO
    Note over B: cliente aprova pelo link do orçamento
    B-->>OS: OrcamentoAprovado
    OS->>OS: reserva estoque das peças
    OS->>B: CobrarOrcamento → AGUARDANDO_PAGAMENTO
    B->>MP: POST /v1/orders (X-Idempotency-Key)
    MP-->>B: webhook: pago
    B-->>OS: PagamentoAprovado
    OS->>E: AgendarExecucao → AGUARDANDO_EXECUCAO
    E-->>OS: ExecucaoAtualizada (EM_DIAGNOSTICO) → EM_EXECUCAO
    E-->>OS: ExecucaoFinalizada → FINALIZADA
```

### Compensações

| Falha | Compensação | Estado final |
|---|---|---|
| Cliente recusa o orçamento | — | CANCELADA |
| Estoque insuficiente ao reservar | `CancelarOrcamento` no billing | CANCELADA |
| Pagamento recusado ou expirado | libera estoque | CANCELADA |
| Execução falha | `EstornarPagamento` (refund no MP) + libera estoque | CANCELADA |

### Garantias

- **Outbox transacional** nos serviços com Postgres: a mudança de estado e a mensagem a publicar são gravadas na mesma transação; um publicador envia para o SQS depois. Nada se perde se o processo cair entre o commit e o envio.
- **Consumidores idempotentes**: cada mensagem tem `messageId`; o consumidor registra os já processados e ignora repetidos (o SQS entrega *at least once*).
- **Idempotência no Mercado Pago**: `X-Idempotency-Key` = `<osId>:<etapa>`.
- **Rastreio**: `correlationId` = id da OS, propagado em toda mensagem e em todo log JSON.

## Ambiente local

Floci (emulador de AWS: SQS, DynamoDB, Secrets Manager) + Postgres em container. Os segredos ficam em `.env` local, fora do git; os repositórios são públicos e só trazem `.env.example` com valores falsos. `gitleaks` roda no CI.

## Qualidade

Cobertura mínima de **95%** (linhas, branches, funções e statements) em cada serviço, travada no `coverageThreshold` do Jest — o CI falha abaixo disso. O requisito da fase é 80%.
