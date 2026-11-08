#!/usr/bin/env bash
# Gera tráfego realista por alguns minutos (dashboard do Grafana e New Relic ficam com dados).
# Uso: bash scripts/gera-trafego.sh [minutos]   (padrão: 5)
set -euo pipefail
MIN="${1:-5}"
N=$((MIN * 120))   # 1 requisição a cada 0,5 s
POD=$(kubectl get pods -n ingress-nginx --no-headers | awk '{print $1}' | head -1)

# Pelo ingress (passa pelo nginx): o prefixo /evaluate é reescrito, por isso /evaluate/evaluate.
nohup kubectl exec -n ingress-nginx "$POD" -- sh -c \
  "for i in \$(seq 1 $N); do curl -s -o /dev/null \"http://localhost/evaluate/evaluate?user_id=g\$i&flag_name=demo-flag\"; sleep 0.5; done" >/dev/null 2>&1 &

# Direto no evaluation-service.
nohup kubectl exec -n evaluation-service deploy/evaluation-service -- sh -c \
  "for i in \$(seq 1 $N); do wget -q -T 3 -O /dev/null \"http://localhost:8004/evaluate?user_id=h\$i&flag_name=demo-flag\"; sleep 0.5; done" >/dev/null 2>&1 &

echo "Tráfego iniciado em segundo plano por ~${MIN} min."
