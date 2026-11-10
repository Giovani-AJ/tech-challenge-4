# tech-challenge-4 — ToggleMaster (Pós DevOps, Tech Challenge Fase 4)

Observabilidade total e resposta ativa sobre o ToggleMaster: monitoramento open source no
Kubernetes (Prometheus, Loki, Grafana), padronização com OpenTelemetry Collector, APM no
New Relic (traces distribuídos e Service Map) e alertas que abrem incidente (PagerDuty), avisam
no Discord e acionam um self-healing automático.

O repositório continua sendo o monorepo das fases anteriores: infraestrutura como código,
os 5 microsserviços, pipeline DevSecOps e GitOps com ArgoCD.

## Fase 4 em um olhar

```
microsserviços (Go/Python, instrumentados com OpenTelemetry)
   │  OTLP (traces e métricas)            pods (stdout)
   ▼                                          │
OTel Collector gateway  ◄── OTel Collector agent (DaemonSet, lê os logs)
   ├─► Loki          (logs)                   → Grafana (dashboard e Explore)
   ├─► Prometheus    (métricas RED via spanmetrics) → Grafana (dashboard e alerta)
   └─► New Relic     (traces, métricas, Service Map)

Grafana Alerting: HTTP 5xx > 5% por 2 min
   ├─► PagerDuty (incidente)  ├─► Discord (ChatOps)  └─► self-healer → rollout restart
```

| O quê | Onde |
| --- | --- |
| Stack de observabilidade (Helm via ArgoCD) | `gitops/observability/` e `gitops/argocd-applications/` |
| Self-healing | `gitops/self-healing/` |
| Instrumentação OpenTelemetry | `services/*` (`otel.go`, `gunicorn.conf.py`) |
| Arquitetura e roteiro da falha proposital | `docs/OBSERVABILIDADE.md` |
| Religar/desligar o ambiente | `docs/RELIGAR.md` e `scripts/` |
| Evidências | `docs/evidencias/` |

## Das fases anteriores (Fase 3)

Monorepo com infraestrutura como código, os 5 microsserviços do ToggleMaster, pipeline
DevSecOps e GitOps — tudo num só repositório, substituindo o provisionamento manual
da Fase 2.

Veja `ESTRUTURA.md` para o mapa completo de pastas e o racional de cada decisão, e
`docs/RUNBOOK.md` para o passo a passo operacional (do zero até os serviços rodando).

## Estrutura

```
terraform/          # IaC: rede, EKS, RDS x3, Redis, DynamoDB, SQS, ECR, OIDC, ArgoCD, ESO
gitops/              # manifests que o ArgoCD sincroniza (Application aponta pra cá)
services/
  auth-service/        # Go
  flag-service/         # Python/Flask
  targeting-service/     # Python/Flask
  evaluation-service/     # Go
  analytics-service/       # Python/Flask
.github/workflows/    # 1 workflow de CI por serviço, filtrado por path
docs/                # RUNBOOK, ARQUITETURA, relatório de entrega
```

## Por onde começar

Siga `docs/RUNBOOK.md`. Resumo rápido do que já está feito e do que falta em
`ESTRUTURA.md` (seção "Estado atual").
