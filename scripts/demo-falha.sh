#!/usr/bin/env bash
# DEMO de self-healing: injeta falha na memória dos pods do auth-service (/validate passa a
# responder 500) e gera tráfego contínuo (~8 min). O resto é automático:
# alerta Firing -> PagerDuty + Discord + self-healer (rollout restart).
# Requer CHAOS_ENABLED=true no ConfigMap do auth-service (já está no GitOps).
set -euo pipefail
NS=auth-service
MK=$(kubectl get secret auth-secret -n "$NS" -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

echo "Injetando falha nos pods do $NS..."
for p in $(kubectl get pods -n "$NS" -o name); do
  echo -n "  $p: "
  kubectl exec -n "$NS" "$p" -- wget -qO- --header="Authorization: Bearer $MK" --post-data="" \
    "http://localhost:8001/admin/chaos?mode=break"; echo
  # tráfego contínuo em cada pod (o erro precisa durar > 2 min para o alerta disparar)
  nohup kubectl exec -n "$NS" "$p" -- sh -c \
    'for i in $(seq 1 1200); do wget -q -T 2 -O /dev/null --header="Authorization: Bearer x" http://localhost:8001/validate; sleep 0.4; done' >/dev/null 2>&1 &
done

# tráfego no evaluation-service (que depende do auth) para o New Relic e o dashboard
nohup kubectl exec -n evaluation-service deploy/evaluation-service -- sh -c \
  'for i in $(seq 1 1200); do wget -q -T 3 -O /dev/null "http://localhost:8004/evaluate?user_id=f$i&flag_name=demo-flag"; sleep 0.4; done' >/dev/null 2>&1 &

echo "Falha injetada às $(date +%H:%M:%S). O alerta dispara em ~3-4 min."
echo "Acompanhe: kubectl get pods -n $NS -w   e   kubectl logs -n self-healing deploy/self-healer -f"
