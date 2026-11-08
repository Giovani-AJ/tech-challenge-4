#!/usr/bin/env bash
# Mostra, em cada pod do auth-service, se a falha injetada ainda existe e o status do /validate.
set -euo pipefail
NS=auth-service
MK=$(kubectl get secret auth-secret -n "$NS" -o jsonpath='{.data.MASTER_KEY}' | base64 -d)
for p in $(kubectl get pods -n "$NS" -o name); do
  echo "$p"
  echo -n "  falha injetada? "
  kubectl exec -n "$NS" "$p" -- wget -qO- --header="Authorization: Bearer $MK" http://localhost:8001/admin/chaos; echo
  echo -n "  /validate -> "
  kubectl exec -n "$NS" "$p" -- wget -S -qO /dev/null --header="Authorization: Bearer x" \
    http://localhost:8001/validate 2>&1 | grep -m1 "HTTP/" || true
done
echo "(401 = saudável: o serviço respondeu normalmente a uma chave inválida; 500 = falha ativa)"
