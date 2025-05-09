#!/bin/bash

# Цвета
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${YELLOW}--- Шаг 1: Введите параметры подключения ---${NC}"

read -rp "$(echo -e "${YELLOW}Введите ETHEREUM_HOSTS: ${NC}")" ETHEREUM_HOSTS
read -rp "$(echo -e "${YELLOW}Введите RPC_URL: ${NC}")" RPC_URL
read -rp "$(echo -e "${YELLOW}Введите VALIDATOR_PRIVATE_KEY (без '0x'): ${NC}")" VALIDATOR_PRIVATE_KEY
read -rp "$(echo -e "${YELLOW}Введите ATTESTER (ваш EOA адрес): ${NC}")" ATTESTER
read -rp "$(echo -e "${YELLOW}Введите PROPOSER_EOA (ваш EOA адрес): ${NC}")" PROPOSER_EOA
read -rp "$(echo -e "${YELLOW}Введите TELEGRAM_BOT_TOKEN: ${NC}")" TELEGRAM_BOT_TOKEN
read -rp "$(echo -e "${YELLOW}Введите TELEGRAM_USER_ID: ${NC}")" TELEGRAM_USER_ID

echo -e "${GREEN}Данные успешно получены. Продолжаем...${NC}"

# Пути
SCRIPT_DIR="$HOME/aztec-validator-script"
SCRIPT_PATH="$SCRIPT_DIR/aztec_validator.sh"
LOG_DIR="$SCRIPT_DIR/log"
LOG_FILE="$LOG_DIR/aztec_validator.log"
ENV_PATH="$SCRIPT_DIR/.env"

# Константы
MAX_ATTEMPTS=12
SLEEP_SECONDS=5
STAKING_ASSET_HANDLER="0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2"
L1_CHAIN_ID=11155111

echo -e "${YELLOW}--- Шаг 2: Создание директорий и файлов ---${NC}"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Сохраняем переменные в .env
cat > "$ENV_PATH" <<EOF
ETHEREUM_HOSTS=$ETHEREUM_HOSTS
RPC_URL=$RPC_URL
VALIDATOR_PRIVATE_KEY=$VALIDATOR_PRIVATE_KEY
ATTESTER=$ATTESTER
PROPOSER_EOA=$PROPOSER_EOA
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_USER_ID=$TELEGRAM_USER_ID
LOG_FILE=$LOG_FILE
MAX_ATTEMPTS=$MAX_ATTEMPTS
SLEEP_SECONDS=$SLEEP_SECONDS
STAKING_ASSET_HANDLER=$STAKING_ASSET_HANDLER
L1_CHAIN_ID=$L1_CHAIN_ID
EOF

echo -e "${GREEN}.env сохранён в ${ENV_PATH}${NC}"

echo -e "${YELLOW}--- Шаг 3: Генерация исполняемого скрипта ---${NC}"

cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash

ENV_PATH="$(dirname "$0")/.env"
if [ -f "$ENV_PATH" ]; then
  set -o allexport
  source "$ENV_PATH"
  set +o allexport
else
  echo "Env file not found: $ENV_PATH"
  exit 1
fi

COMMAND="/root/.aztec/bin/aztec add-l1-validator \
  --l1-rpc-urls $ETHEREUM_HOSTS \
  --private-key 0x$VALIDATOR_PRIVATE_KEY \
  --attester $ATTESTER \
  --proposer-eoa $PROPOSER_EOA \
  --staking-asset-handler $STAKING_ASSET_HANDLER \
  --l1-chain-id $L1_CHAIN_ID"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_telegram() {
  local MESSAGE=$1
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
       -d chat_id="$TELEGRAM_USER_ID" \
       -d text="$MESSAGE" > /dev/null
}

check_tx_status() {
  local HASH=$1
  local ATTEMPT=1

  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    log "Checking tx status (attempt $ATTEMPT)..."
    STATUS=$(curl -s -X POST "$RPC_URL" \
      -H "Content-Type: application/json" \
      -d '{
        "jsonrpc":"2.0",
        "method":"eth_getTransactionReceipt",
        "params":["'"$HASH"'"],
        "id":1
      }')

    TX_STATUS=$(echo "$STATUS" | grep -o '"status":"0x[01]"' | cut -d':' -f2 | tr -d '"')

    if [[ -z "$TX_STATUS" ]]; then
      log "Transaction is still pending..."
    elif [[ "$TX_STATUS" == "0x1" ]]; then
      log "Transaction SUCCESS"
      send_telegram "✅ AZTEC Validator: SUCCESS\nTx: https://sepolia.ethplorer.io/tx/$HASH"
      return 0
    elif [[ "$TX_STATUS" == "0x0" ]]; then
      log "Transaction FAILED"
      send_telegram "❌ AZTEC Validator: FAILED\nTx: https://sepolia.ethplorer.io/tx/$HASH"
      return 1
    fi

    ((ATTEMPT++))
    sleep "$SLEEP_SECONDS"
  done

  log "Transaction not confirmed after $((MAX_ATTEMPTS * SLEEP_SECONDS)) seconds"
  send_telegram "⚠️ AZTEC Validator: TX not confirmed after timeout\nTx: https://sepolia.ethplorer.io/tx/$HASH"
  return 1
}

log "Starting validator registration..."

OUTPUT=$(eval "$COMMAND" 2>&1)
log "Command output:"
echo "$OUTPUT" | tee -a "$LOG_FILE"

if echo "$OUTPUT" | grep -q "ValidatorQuotaFilledUntil"; then
  log "Quota filled. Stopping script."
  send_telegram "⚠️ AZTEC Validator: Quota filled. Try later."
  exit 0
fi

TX_HASH=$(echo "$OUTPUT" | grep -oE 'Transaction hash: 0x[a-fA-F0-9]{64}' | awk '{print $3}')

if [[ -z "$TX_HASH" ]]; then
  log "Transaction hash not found. Aborting."
  send_telegram "❌ AZTEC Validator: Transaction hash not found."
  exit 1
fi

log "Transaction hash found: $TX_HASH"
send_telegram "📤 AZTEC Validator: TX sent\nHash: $TX_HASH\nhttps://sepolia.ethplorer.io/tx/$TX_HASH"

if check_tx_status "$TX_HASH"; then
  exit 0
else
  log "Retrying registration..."
  exec "$0"
fi
EOF

chmod +x "$SCRIPT_PATH"
chmod +x "$LOG_FILE"

echo -e "${GREEN}Скрипт создан и сделан исполняемым: $SCRIPT_PATH${NC}"

echo -e "${YELLOW}--- Шаг 4: Добавление cron-задачи ---${NC}"

CRON_JOB="*/2 * * * * $SCRIPT_PATH >> $LOG_FILE 2>&1"
( crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_JOB" ) | crontab -

echo -e "${GREEN}Cron задача добавлена:${NC} $CRON_JOB"
echo -e "${YELLOW}⚠️ Скрипт будет выполняться каждый день в 23:49 CEST.${NC}"

echo -e "${YELLOW}--- Шаг 5: Тестовый запуск через 10 секунд ---${NC}"
timeout 10
"$SCRIPT_PATH"
