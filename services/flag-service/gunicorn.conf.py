"""Configuração do gunicorn com OpenTelemetry (auto-instrumentação).

Por que no hook post_fork e não via `opentelemetry-instrument gunicorn ...`:
o gunicorn faz fork dos workers e as threads de exportação do OTel (BatchSpanProcessor)
não sobrevivem ao fork — os spans seriam gerados, mas nunca enviados. Inicializando
dentro de cada worker, antes de ele importar o app, o Flask/requests/psycopg2/botocore
são instrumentados e o exporter funciona.

Configuração por variáveis padrão do OTel (definidas no ConfigMap do serviço):
OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_PROTOCOL, etc.
Sem OTEL_EXPORTER_OTLP_ENDPOINT (dev local) nada é exportado.
"""
import os


def post_fork(server, worker):
    if not os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        server.log.info("OpenTelemetry desativado (OTEL_EXPORTER_OTLP_ENDPOINT nao definido).")
        return
    from opentelemetry.instrumentation.auto_instrumentation import initialize
    initialize()
    server.log.info("OpenTelemetry ativado no worker %s.", worker.pid)
