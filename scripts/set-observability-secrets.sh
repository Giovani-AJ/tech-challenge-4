#!/usr/bin/env bash
# Grava no AWS Secrets Manager as chaves da observabilidade (New Relic, PagerDuty, Discord).
# Pergunta cada valor SEM ecoar no terminal (nada vai para histórico, tela ou Git) e
# preserva o SELFHEAL_TOKEN que o Terraform já gerou no mesmo segredo.
# Enter em branco = mantém o valor que já está gravado (dá para trocar só uma chave).
set -euo pipefail

SECRET_ID="${SECRET_ID:-togglemaster/dev/togglemaster-dev-observability}"
REGION="${AWS_REGION:-us-east-1}"

current=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ID" --query SecretString --output text)
token=$(printf '%s' "$current" | python -c "import sys,json; print(json.load(sys.stdin)['SELFHEAL_TOKEN'])")
[ -n "$token" ] || { echo "SELFHEAL_TOKEN não encontrado em $SECRET_ID" >&2; exit 1; }

getcur() { printf '%s' "$current" | python -c "import sys,json; print(json.load(sys.stdin).get('$1',''))"; }
CUR_NR=$(getcur NEW_RELIC_LICENSE_KEY); CUR_PD=$(getcur PAGERDUTY_INTEGRATION_KEY); CUR_DC=$(getcur DISCORD_WEBHOOK_URL)

ask() { # ask VAR "mensagem" VALOR_ATUAL [prefixo esperado]
  local v
  read -rsp "$2 (Enter = manter atual): " v; echo >&2
  if [ -z "$v" ]; then
    if [ -z "$3" ] || [ "$3" = "REPLACE_ME" ]; then echo "sem valor atual, informe um" >&2; exit 1; fi
    v="$3"; echo "  mantido." >&2
  elif [ -n "${4:-}" ] && [[ "$v" != $4* ]]; then
    echo "  aviso: não começa com '$4' (confira se copiou o valor certo)" >&2
  fi
  printf -v "$1" '%s' "$v"
}

ask NR  "New Relic license key (INGEST - LICENSE)" "$CUR_NR"
ask PD  "PagerDuty Integration Key (Events API v2)" "$CUR_PD"
ask DC  "Discord webhook URL" "$CUR_DC" "https://discord.com/api/webhooks/"

payload=$(NR="$NR" PD="$PD" DC="$DC" TOKEN="$token" python -c "
import json,os
print(json.dumps({'NEW_RELIC_LICENSE_KEY':os.environ['NR'],'PAGERDUTY_INTEGRATION_KEY':os.environ['PD'],'DISCORD_WEBHOOK_URL':os.environ['DC'],'SELFHEAL_TOKEN':os.environ['TOKEN']}))")

aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET_ID" --secret-string "$payload" --query VersionId --output text >/dev/null
echo "OK: segredo $SECRET_ID atualizado (valores não exibidos)."
