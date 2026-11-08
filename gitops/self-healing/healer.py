"""Self-healing: recebe o webhook do Grafana Alerting e faz o equivalente a
`kubectl rollout restart deployment/<nome>` (PATCH na annotation restartedAt do pod
template), sem intervenção humana.

Segurança / anti-loop (alert fatigue e "restart storm"):
  - exige `Authorization: Bearer <SELFHEAL_TOKEN>`;
  - só age em alertas `firing` que tragam os labels selfheal_namespace/selfheal_deployment;
  - allowlist fixa de deployments (os 5 microsserviços);
  - cooldown por deployment (COOLDOWN_SECONDS) para não reiniciar em loop;
  - RBAC mínimo: só `patch` nos 5 deployments (ver rbac.yaml).
Somente biblioteca padrão do Python (roda em python:3.11-alpine puro).
"""
import json
import os
import ssl
import sys
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("SELFHEAL_TOKEN", "")
COOLDOWN = int(os.environ.get("COOLDOWN_SECONDS", "300"))
DRY_RUN = os.environ.get("DRY_RUN") == "1"
ALLOWED = {
    ("auth-service", "auth-service"),
    ("flag-service", "flag-service"),
    ("targeting-service", "targeting-service"),
    ("evaluation-service", "evaluation-service"),
    ("analytics-service", "analytics-service"),
}
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
last_restart = {}


def log(msg, **kv):
    print(json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "msg": msg, **kv}, ensure_ascii=False), flush=True)


def rollout_restart(namespace, deployment):
    """PATCH idêntico ao que o `kubectl rollout restart` envia."""
    now = datetime.now(timezone.utc).isoformat()
    body = {"spec": {"template": {"metadata": {"annotations": {"kubectl.kubernetes.io/restartedAt": now}}}}}
    if DRY_RUN:
        log("DRY_RUN: restart simulado", namespace=namespace, deployment=deployment)
        return
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    url = f"https://kubernetes.default.svc/apis/apps/v1/namespaces/{namespace}/deployments/{deployment}"
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), method="PATCH",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/strategic-merge-patch+json"})
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
        log("rollout restart executado", namespace=namespace, deployment=deployment, http_status=resp.status)


def handle_alerts(payload):
    results = []
    for alert in payload.get("alerts", []):
        labels = alert.get("labels", {})
        ns, dep = labels.get("selfheal_namespace"), labels.get("selfheal_deployment")
        name = labels.get("alertname", "?")
        if alert.get("status") != "firing":
            results.append({"alert": name, "action": "ignorado (resolved)"})
            continue
        if not ns or not dep:
            results.append({"alert": name, "action": "ignorado (sem labels selfheal_*)"})
            continue
        if (ns, dep) not in ALLOWED:
            log("alvo fora da allowlist", namespace=ns, deployment=dep)
            results.append({"alert": name, "action": "negado (fora da allowlist)"})
            continue
        key = f"{ns}/{dep}"
        wait = COOLDOWN - (time.time() - last_restart.get(key, 0))
        if wait > 0:
            log("cooldown ativo, restart pulado", target=key, restante_s=int(wait))
            results.append({"alert": name, "action": f"cooldown ({int(wait)}s restantes)"})
            continue
        log("alerta firing -> self-healing", alert=name, target=key)
        try:
            rollout_restart(ns, dep)
            last_restart[key] = time.time()
            results.append({"alert": name, "action": f"rollout restart {key}"})
        except Exception as e:  # noqa: BLE001
            log("falha ao reiniciar", target=key, erro=str(e))
            results.append({"alert": name, "action": f"erro: {e}"})
    return results


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        self._send(200, {"status": "ok"}) if self.path == "/health" else self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if self.path != "/heal":
            return self._send(404, {"error": "not found"})
        if not TOKEN or self.headers.get("Authorization") != f"Bearer {TOKEN}":
            log("requisição não autorizada", origem=self.client_address[0])
            return self._send(401, {"error": "unauthorized"})
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except json.JSONDecodeError:
            return self._send(400, {"error": "json inválido"})
        self._send(200, {"results": handle_alerts(payload)})

    def log_message(self, *a):  # silencia o log padrão (usamos log() estruturado)
        pass


if __name__ == "__main__":
    if not TOKEN:
        log("SELFHEAL_TOKEN ausente"); sys.exit(1)
    log("self-healer iniciado", cooldown_s=COOLDOWN, dry_run=DRY_RUN)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
