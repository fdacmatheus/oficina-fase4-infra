#!/usr/bin/env bash
# Percorre a saga inteira pelos 3 serviços rodando localmente.
#   ./demo-saga.sh                 caminho feliz
#   ./demo-saga.sh pagamento       pagamento recusado (compensação: libera estoque)
#   ./demo-saga.sh execucao        execução falha (compensação: estorno + estoque)
#   ./demo-saga.sh recusa          cliente recusa o orçamento
# Requer: curl, jq, python3; serviços em 3001 (os), 3002 (billing), 3003 (execution);
# ADMIN_PASSWORD igual ao do .env do os-service.
set -euo pipefail

CENARIO="${1:-feliz}"
OS_URL=${OS_URL:-http://localhost:3001/api}
EXEC_URL=${EXEC_URL:-http://localhost:3003/api}
MAILHOG=${MAILHOG:-http://localhost:8025}
: "${ADMIN_PASSWORD:?defina ADMIN_PASSWORD (o mesmo do .env do os-service)}"

passo() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✔ %s\033[0m\n' "$*"; }

aguardar_status() {
  local alvo=$1 status=""
  for _ in $(seq 1 40); do
    status=$(curl -sf "$OS_URL/ordens-servico/$OS_ID" -H "$AUTH" | jq -r .status)
    [[ "$status" == "$alvo" ]] && { ok "OS #$OS_NUM em $status"; return; }
    sleep 0.5
  done
  echo "  ✘ esperava $alvo, OS está em $status" >&2
  exit 1
}

passo "Login do admin no os-service"
TOKEN=$(curl -sf "$OS_URL/auth/login" -H 'content-type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" | jq -r .accessToken)
AUTH="Authorization: Bearer $TOKEN"
ok "token obtido"

CLIENTE=$(curl -sf "$OS_URL/clientes" -H "$AUTH" | jq -r '.[0].id')
VEICULO=$(curl -sf "$OS_URL/veiculos" -H "$AUTH" | jq -r --arg c "$CLIENTE" '[.[] | select(.clienteId == $c)][0].id')
SERVICO=$(curl -sf "$OS_URL/servicos" -H "$AUTH" | jq -r '.[0].id')
PECA=$(curl -sf "$OS_URL/pecas" -H "$AUTH" | jq -r '.[0].id')
estoque() { curl -sf "$OS_URL/pecas/$PECA" -H "$AUTH" | jq -r .estoque; }
ESTOQUE_ANTES=$(estoque)

passo "Abrindo a OS (os-service grava a OS e o comando GerarOrcamento na mesma transação)"
OS=$(curl -sf "$OS_URL/ordens-servico" -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"clienteId\":\"$CLIENTE\",\"veiculoId\":\"$VEICULO\",\"servicos\":[{\"servicoId\":\"$SERVICO\"}],\"pecas\":[{\"pecaId\":\"$PECA\",\"quantidade\":2}]}")
OS_ID=$(jq -r .id <<<"$OS"); OS_NUM=$(jq -r .numero <<<"$OS")
ok "OS #$OS_NUM ($OS_ID) — estoque da peça: $ESTOQUE_ANTES"

passo "billing gera o orçamento → os-service notifica o cliente por e-mail"
aguardar_status AGUARDANDO_APROVACAO
LINK=""
for _ in $(seq 1 20); do
  LINK=$(curl -sf "$MAILHOG/api/v2/search?kind=containing&query=%23$OS_NUM" \
    | jq -r '.items[].Content.Body' | python3 -c 'import sys,quopri; sys.stdout.write(quopri.decodestring(sys.stdin.buffer.read()).decode())' | grep -oE 'http[^ ]+/orcamentos/[^ ]+' | head -1 | tr -d '\r' || true)
  [[ -n "$LINK" ]] && break; sleep 0.5
done
[[ -n "$LINK" ]] || { echo "  ✘ e-mail com o link não chegou" >&2; exit 1; }
ok "link do e-mail: $LINK"
BASE=${LINK%%\?*}; QS=${LINK#*\?}

if [[ "$CENARIO" == "recusa" ]]; then
  passo "Cliente recusa o orçamento"
  curl -sf -X POST "$BASE/recusar?$QS" >/dev/null
  aguardar_status CANCELADA
else
  passo "Cliente aprova → os-service reserva o estoque e manda CobrarOrcamento"
  curl -sf -X POST "$BASE/aprovar?$QS" >/dev/null
  aguardar_status AGUARDANDO_PAGAMENTO
  ok "estoque reservado: $ESTOQUE_ANTES → $(estoque)"

  CARTAO=fake-aprovado
  [[ "$CENARIO" == "pagamento" ]] && CARTAO=fake-recusado
  passo "Cliente paga no checkout transparente (cartão: $CARTAO)"
  for _ in $(seq 1 20); do
    R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/pagar?$QS" -H 'content-type: application/json' \
      -d "{\"cardToken\":\"$CARTAO\",\"paymentMethodId\":\"master\",\"installments\":1,\"payerEmail\":\"cliente@exemplo.com\"}")
    [[ "$R" == 2* || "$R" == 402 ]] && break; sleep 0.5   # 409 enquanto a cobrança ainda não foi criada
  done

  if [[ "$CENARIO" == "pagamento" ]]; then
    aguardar_status CANCELADA
  else
    aguardar_status AGUARDANDO_EXECUCAO

    passo "Mecânico executa no execution-service"
    for _ in $(seq 1 20); do
      curl -sf -X POST "$EXEC_URL/execucoes/$OS_ID/diagnostico" -H "$AUTH" -H 'content-type: application/json' \
        -d '{"observacao":"ruído no motor"}' >/dev/null && break; sleep 0.5
    done
    aguardar_status EM_EXECUCAO
    curl -sf -X POST "$EXEC_URL/execucoes/$OS_ID/reparo" -H "$AUTH" -H 'content-type: application/json' -d '{}' >/dev/null
    if [[ "$CENARIO" == "execucao" ]]; then
      curl -sf -X POST "$EXEC_URL/execucoes/$OS_ID/falhar" -H "$AUTH" -H 'content-type: application/json' \
        -d '{"motivo":"Elevador hidráulico quebrou"}' >/dev/null
      aguardar_status CANCELADA
    else
      curl -sf -X POST "$EXEC_URL/execucoes/$OS_ID/finalizar" -H "$AUTH" >/dev/null
      aguardar_status FINALIZADA
    fi
  fi
fi

sleep 2
passo "Estoque: antes $ESTOQUE_ANTES, agora $(estoque)"
passo "Histórico da OS #$OS_NUM"
curl -sf "$OS_URL/ordens-servico/$OS_ID/historico" -H "$AUTH" \
  | jq -r '.[] | "  \(.em | ./1000 | strftime("%H:%M:%S"))  \(.evento | .[0:22] | . + " " * (22 - length))  \(.statusAnterior // "-") → \(.statusNovo)  \(.detalhe // "")"'
