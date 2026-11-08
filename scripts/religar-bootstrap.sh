#!/usr/bin/env bash
# Depois que os serviços sobem (pods Running), prepara os dados do ambiente recriado:
#   1) cria as tabelas nos 3 bancos RDS (rodando de dentro do cluster: os bancos só aceitam a VPC)
#   2) gera a chave de API do evaluation-service e grava no Secrets Manager
#   3) cria a flag e a regra de demonstração (demo-flag, 50%)
# Uso: bash scripts/religar-bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")/.."
REGION=us-east-1

echo "== 1/3 Tabelas dos bancos"
for s in auth flag targeting; do
  URL=$(aws secretsmanager get-secret-value --region $REGION \
    --secret-id "togglemaster/dev/togglemaster-dev-$s-db" --query SecretString --output text \
    | python -c "import sys,json;print(json.load(sys.stdin)['DATABASE_URL'])")
  # init.sql cria o banco e troca de conexão; o RDS já criou o banco, então só as tabelas interessam
  tr -d '\r' < "services/$s-service/db/init.sql" | sed -E '/^CREATE DATABASE/d;/^[\]c /d' \
    | kubectl run "psql-$s" -i --rm --restart=Never --image=postgres:15-alpine --env="U=$URL" \
        --command -- sh -c 'psql "$U?sslmode=require" -v ON_ERROR_STOP=1 -f - >/dev/null'
  echo "  $s: ok"
done

echo "== 2/3 Chave de API do evaluation-service"
kubectl rollout status deployment/auth-service -n auth-service --timeout=300s >/dev/null
MK=$(kubectl get secret auth-secret -n auth-service -o jsonpath='{.data.MASTER_KEY}' | base64 -d)
KEY=$(kubectl exec -n auth-service deploy/auth-service -- wget -qO- \
  --header="Authorization: Bearer $MK" --header="Content-Type: application/json" \
  --post-data='{"name":"evaluation-service"}' http://localhost:8001/admin/keys \
  | python -c "import sys,json;print(json.load(sys.stdin)['key'])")
aws secretsmanager put-secret-value --region $REGION \
  --secret-id togglemaster/dev/togglemaster-dev-evaluation-service-api-key \
  --secret-string "{\"SERVICE_API_KEY\":\"$KEY\"}" >/dev/null
kubectl annotate externalsecret evaluation-secret -n evaluation-service force-sync="$(date +%s)" --overwrite >/dev/null
sleep 8
kubectl delete pod -n evaluation-service --all --wait=false >/dev/null
echo "  chave gravada e evaluation-service reiniciado"

echo "== 3/3 Flag e regra de demonstração"
kubectl rollout status deployment/flag-service -n flag-service --timeout=300s >/dev/null
kubectl rollout status deployment/targeting-service -n targeting-service --timeout=300s >/dev/null
kubectl exec -n flag-service deploy/flag-service -- wget -qO- \
  --header="Authorization: Bearer $KEY" --header="Content-Type: application/json" \
  --post-data='{"name":"demo-flag","description":"flag de demonstracao","is_enabled":true}' \
  http://127.0.0.1:8002/flags >/dev/null
kubectl exec -n targeting-service deploy/targeting-service -- wget -qO- \
  --header="Authorization: Bearer $KEY" --header="Content-Type: application/json" \
  --post-data='{"flag_name":"demo-flag","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}' \
  http://127.0.0.1:8003/rules >/dev/null
echo "  demo-flag criada"
echo "Pronto. Teste: bash scripts/gera-trafego.sh 2"
