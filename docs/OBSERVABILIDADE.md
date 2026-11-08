# Observabilidade (Fase 4)

Tudo é entregue por GitOps: `gitops/argocd-applications/*.yaml` (Applications) +
`gitops/observability/*` (values e recursos). Namespace: `monitoring`.

| Application | Chart | Função |
|---|---|---|
| `kube-prometheus-stack` | prometheus-community 86.1.0 | Prometheus, Grafana, Alertmanager |
| `loki` | grafana/loki 7.5.0 (SingleBinary) | armazenamento/consulta de logs |
| `otel-collector-gateway` | opentelemetry-collector 0.178.2 | recebe OTLP dos serviços e roteia |
| `otel-collector-agent` | opentelemetry-collector 0.178.2 (DaemonSet) | lê logs de todos os pods e envia ao gateway |
| `observability-resources` | YAML puro | dashboards do Grafana (ConfigMaps) |

## Fluxo da telemetria

```
pods (stdout) ──► otel-agent (DaemonSet, filelog + k8sattributes) ──┐
                                                                     ▼
microsserviços ── OTLP :4317/:4318 ──────────────────────────► otel-gateway
                                                                     │
          logs    ──► Loki (OTLP nativo, /otlp)                      │
          metrics ──► Prometheus (remote write)                      │
          traces  ──► spanmetrics (métricas RED no Prometheus)       │
                  └─► APM New Relic (fase C)                         ▼
```

Endpoint OTLP para os serviços: `http://otel-gateway.monitoring.svc:4318` (HTTP)
ou `otel-gateway.monitoring.svc:4317` (gRPC).

## Métricas RED a partir dos traces

O conector `spanmetrics` do gateway gera `traces_span_metrics_calls_total{service_name,status_code,span_kind}`.
O dashboard e o alerta de 5xx (fase D) usam essa métrica, então funcionam igual para os
serviços Go e Python assim que a instrumentação (fase B) estiver no ar.

## Dashboard

`ToggleMaster - Saúde do Ecossistema` (uid `togglemaster-overview`): nós/pods/CPU/memória,
req/s e % de erro por serviço, tráfego do ingress e painel de logs do Loki ao vivo.

## Acesso

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

## Migração a partir da Fase 3

O Prometheus/Grafana eram um `helm_release` do Terraform (`module.monitoring`). Agora
são do ArgoCD; o módulo foi removido. Em um cluster já existente, o próximo
`terraform apply` desinstala o release antigo e o ArgoCD instala o novo.

## Capacidade

A stack adiciona ~6 pods (Loki, gateway, 1 agent por nó, Alertmanager). Com o limite
de pods por nó do t3.medium, se houver `Pending`, suba `node_max_size`/`node_desired_size`.

## Instrumentação dos serviços (Fase B)

| Serviço | Linguagem | Como |
|---|---|---|
| auth-service | Go | SDK OTel + `otelhttp` (servidor) + `otelsql` (spans de SQL) — `otel.go` |
| evaluation-service | Go | `otelhttp` servidor e cliente (propaga `traceparent` a flag/targeting), `redisotel`, span PRODUCER no SQS com `traceparent` em `MessageAttributes` |
| flag / targeting-service | Python | auto-instrumentação (Flask, requests, psycopg2) inicializada no `post_fork` do gunicorn (`gunicorn.conf.py`) |
| analytics-service | Python | Flask + botocore + span CONSUMER que extrai o `traceparent` da mensagem SQS (o trace continua após a fila) |

Config 100% por env (ConfigMaps): `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, etc.
Sem `OTEL_EXPORTER_OTLP_ENDPOINT` o tracing fica desligado (docker-compose local).
`/health` é filtrado para as probes não poluírem traces nem as métricas RED.

Validado localmente (docker-compose + Collector com exporter `debug`): um `GET /evaluate`
gera **um único trace** com evaluation → Redis → flag-service → SELECT, targeting-service →
SELECT e auth-service (`/validate` + SQL). O trecho SQS → analytics só pode ser exercitado na
AWS (não há SQS local).

## APM, alertas e self-healing (Fases C, D e E)

```
OTel gateway ── traces ──► New Relic (APM, Service Map, trace distribuído)
Prometheus (spanmetrics) ─► Grafana Alerting: "HTTP 5xx > 5% por serviço" (for 2m)
                                   │  contact point "togglemaster-oncall"
                                   ├─► PagerDuty  (abre o incidente)
                                   ├─► Discord    (ChatOps, mensagem detalhada)
                                   └─► self-healer (webhook, Bearer token)
                                          └─► PATCH no Deployment = `kubectl rollout restart`
```

- **Segredos** (nunca no Git): ficam no Secrets Manager em
  `togglemaster/dev/togglemaster-dev-observability` e chegam ao cluster por ExternalSecret.
  O Terraform cria o "slot" com `REPLACE_ME`; preencha uma vez:

  ```bash
  aws secretsmanager put-secret-value --region us-east-1 \
    --secret-id togglemaster/dev/togglemaster-dev-observability \
    --secret-string '{"NEW_RELIC_LICENSE_KEY":"...","PAGERDUTY_INTEGRATION_KEY":"...","DISCORD_WEBHOOK_URL":"...","SELFHEAL_TOKEN":"<mantenha o valor gerado>"}'
  ```
  Atenção: `put-secret-value` substitui o JSON inteiro, então copie o `SELFHEAL_TOKEN` atual antes
  (`aws secretsmanager get-secret-value ...`). Depois force a sincronização:
  `kubectl annotate externalsecret -n monitoring observability-secrets force-sync=$(date +%s) --overwrite`
  (idem em `self-healing`) e reinicie o Grafana e o gateway.
- **Alerta:** `gitops/observability/alerting/grafana-alerting.yaml`. Uma instância por
  `service_name`; os labels `selfheal_namespace/selfheal_deployment` dizem ao self-healer o alvo.
  Anti alert-fatigue: agrupa por alerta+serviço, `repeat_interval` 4h e ignora serviços com
  pouco tráfego.
- **Self-healing:** `gitops/self-healing/` (script `healer.py` em ConfigMap, Python stdlib).
  Exige token, só age nos 5 deployments (allowlist + RBAC com `resourceNames`) e tem cooldown de
  5 min por deployment para não entrar em loop de restart.
