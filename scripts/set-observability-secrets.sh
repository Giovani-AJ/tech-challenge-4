#!/usr/bin/env bash
# Grava no AWS Secrets Manager as chaves da observabilidade (New Relic, PagerDuty, Discord).
# Pergunta cada valor SEM ecoar no terminal (nada vai para histórico, tela ou Git) e
# preserva o SELFHEAL_TOKEN que o Terraform já gerou no mesmo segredo.
set -euo pipefail

SECRET_ID="${SECRET_ID:-togglemaster/dev/togglemaster-dev-observability}"
REGION="${AWS_REGION:-us-east-1}"

current=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ID" --query SecretString --output text)
token=$(printf '%s' "$current" | python -c "import sys,json; print(json.load(sys.stdin)['SELFHEAL_TOKEN'])")
[ -n "$token" ] || { echo "SELFHEAL_TOKEN não encontrado em $SECRET_ID" >&2; exit 1; }

ask() { # ask VAR "mensagem" [prefixo esperado]
  local v
  read -rsp "$2: " v; echo >&2
  [ -n "$v" ] || { echo "valor vazio, abortando" >&2; exit 1; }
  if [ -n "${3:-}" ] && [[ "$v" != $3* ]]; then echo "aviso: não começa com '$3' (confira se copiou o valor certo)" >&2; fi
  printf -v "$1" '%s' "$v"
}

ask NR  "New Relic license key (INGEST - LICENSE)"
ask PD  "PagerDuty Integration Key (Events API v2)"
ask DC  "Discord webhook URL" "https://discord.com/api/webhooks/"

payload=$(NR="$NR" PD="$PD" DC="$DC" TOKEN="$token" python -c "
import json,os
print(json.dumps({'NEW_RELIC_LICENSE_KEY':os.environ['NR'],'PAGERDUTY_INTEGRATION_KEY':os.environ['PD'],'DISCORD_WEBHOOK_URL':os.environ['DC'],'SELFHEAL_TOKEN':os.environ['TOKEN']}))")

aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET_ID" --secret-string "$payload" --query VersionId --output text >/dev/null
echo "OK: segredo $SECRET_ID atualizado (valores não exibidos)."
