#!/usr/bin/env bash
#
# Настройка Xray (VLESS + Reality) сразу с несколькими сайтами маскировки.
#
# Как это устроено:
#   - На порту 443 стоит «сортировщик»: он читает из первого пакета, какой сайт
#     (SNI) просит клиент, и передаёт соединение нужному Reality-входу.
#   - Для каждого сайта из списка есть свой Reality-вход (на 127.0.0.1 внутри
#     контейнера), ключи и UUID у всех общие.
#   - Для каждого устройства печатается по ссылке на каждый сайт. Импортируешь
#     их все в приложение, жмёшь «проверить все» — и видишь, какие работают.
#
# Запуск (на сервере, от root):
#   bash setup.sh                                  # первый запуск
#   bash setup.sh                                  # повторно: пересобрать конфиг, ключи сохраняются
#   TARGETS="www.samsung.com ya.ru" bash setup.sh  # свой список сайтов
#   FORCE=1 bash setup.sh                          # новые ключи (старые ссылки перестанут работать)
#
# Файлы в /opt/xray:
#   state.env    — ключи и IP сервера (секрет, не публиковать)
#   clients.list — устройства и их UUID
#   targets.txt  — сайты маскировки, по одному в строке (можно править руками)
#   config.json  — конфиг Xray, собирается из файлов выше
#   clients.txt  — ссылки для устройств
#
set -euo pipefail

XRAY_DIR="${XRAY_DIR:-/opt/xray}"
IMAGE="${IMAGE:-teddysun/xray:latest}"
CONTAINER="${CONTAINER:-xray}"
PORT="${PORT:-443}"
DEFAULT_TARGETS="www.samsung.com www.nvidia.com www.asus.com dl.google.com ya.ru"
DEFAULT_CLIENTS="android windows iphone"

STATE="$XRAY_DIR/state.env"
CLIENTS_LIST="$XRAY_DIR/clients.list"
TARGETS_FILE="$XRAY_DIR/targets.txt"
CONFIG="$XRAY_DIR/config.json"
CLIENTS_FILE="$XRAY_DIR/clients.txt"

die() { echo "Ошибка: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "запускай от root."
command -v docker >/dev/null || die "Docker не найден."
command -v openssl >/dev/null || die "openssl не найден (apt install openssl)."

mkdir -p "$XRAY_DIR"
chmod 700 "$XRAY_DIR"

# Конфиг от старой версии скрипта (без state.env) — ключи из него не переносим.
if [[ -f "$CONFIG" && ! -f "$STATE" && "${FORCE:-0}" != "1" ]]; then
  die "найден конфиг от старой версии скрипта. Запусти FORCE=1 bash $0
(ключи будут новые, ссылки на устройствах нужно будет импортировать заново)."
fi

# --- Ключи сервера ---------------------------------------------------------
if [[ "${FORCE:-0}" == "1" ]]; then
  rm -f "$STATE" "$CLIENTS_LIST"
fi

if [[ -f "$STATE" ]]; then
  # shellcheck source=/dev/null
  source "$STATE"
  echo "==> Использую сохранённые ключи из $STATE"
else
  echo "==> Генерирую ключи Reality (через образ $IMAGE)..."
  keys="$(docker run --rm --entrypoint xray "$IMAGE" x25519)"
  # Формат вывода: приватный ключ на первой строке, публичный на второй.
  PRIVATE_KEY="$(awk -F': ' 'NR==1 {print $NF}' <<<"$keys")"
  PUBLIC_KEY="$(awk -F': ' 'NR==2 {print $NF}' <<<"$keys")"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "не удалось разобрать вывод xray x25519:
$keys"
  SHORT_ID="$(openssl rand -hex 8)"
  echo "==> Определяю внешний IP сервера..."
  SERVER_IP="$(curl -fsS4 --max-time 10 https://ipinfo.io/ip)" || die "не удалось определить IP."
  cat >"$STATE" <<EOF
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
SERVER_IP=$SERVER_IP
EOF
  chmod 600 "$STATE"
fi

# --- Устройства ------------------------------------------------------------
if [[ ! -f "$CLIENTS_LIST" ]]; then
  names=("$@")
  [[ ${#names[@]} -gt 0 ]] || read -ra names <<<"$DEFAULT_CLIENTS"
  for name in "${names[@]}"; do
    echo "$name $(cat /proc/sys/kernel/random/uuid)"
  done >"$CLIENTS_LIST"
  chmod 600 "$CLIENTS_LIST"
elif [[ $# -gt 0 ]]; then
  echo "Внимание: устройства уже заданы в $CLIENTS_LIST, аргументы игнорирую."
fi

# --- Сайты маскировки ------------------------------------------------------
if [[ -n "${TARGETS:-}" ]]; then
  tr ' ' '\n' <<<"$TARGETS" >"$TARGETS_FILE"
elif [[ ! -f "$TARGETS_FILE" ]]; then
  tr ' ' '\n' <<<"$DEFAULT_TARGETS" >"$TARGETS_FILE"
fi

# Reality требует от сайта TLS 1.3 и HTTP/2, и сайт должен открываться с сервера.
check_target() {
  local out
  out="$(timeout 10 openssl s_client -connect "$1:443" -servername "$1" \
    -tls1_3 -alpn h2 </dev/null 2>/dev/null || true)"
  grep -q "TLSv1.3" <<<"$out" && grep -q "ALPN protocol: h2" <<<"$out"
}

echo "==> Проверяю сайты маскировки..."
targets=()
while read -r t; do
  [[ -n "$t" && "$t" != \#* ]] || continue
  if check_target "$t"; then
    echo "  ✓ $t"
    targets+=("$t")
  else
    echo "  ✗ $t — не подходит (нужны TLS 1.3 и HTTP/2), пропускаю"
  fi
done <"$TARGETS_FILE"
[[ ${#targets[@]} -gt 0 ]] || die "ни один сайт из $TARGETS_FILE не подошёл."

# --- Сборка config.json ----------------------------------------------------
clients_json=""
while read -r name uuid; do
  [[ -n "$name" ]] || continue
  [[ -z "$clients_json" ]] || clients_json+=", "
  clients_json+="{ \"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\", \"email\": \"$name\" }"
done <"$CLIENTS_LIST"

reality_inbounds=""
reality_tags=""
redirect_outbounds=""
sni_rules=""
for i in "${!targets[@]}"; do
  t="${targets[$i]}"
  port=$((10001 + i))
  reality_inbounds+=",
    {
      \"tag\": \"reality-$i\",
      \"listen\": \"127.0.0.1\",
      \"port\": $port,
      \"protocol\": \"vless\",
      \"settings\": { \"clients\": [$clients_json], \"decryption\": \"none\" },
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"dest\": \"$t:443\",
          \"serverNames\": [\"$t\"],
          \"privateKey\": \"$PRIVATE_KEY\",
          \"shortIds\": [\"$SHORT_ID\"]
        }
      },
      \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"] }
    }"
  reality_tags+="${reality_tags:+, }\"reality-$i\""
  redirect_outbounds+=",
    { \"tag\": \"to-reality-$i\", \"protocol\": \"freedom\", \"settings\": { \"redirect\": \"127.0.0.1:$port\" } }"
  sni_rules+="
      { \"inboundTag\": [\"sni-router\"], \"domain\": [\"full:$t\"], \"outboundTag\": \"to-reality-$i\" },"
done

cat >"$CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "sni-router",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": 10001, "network": "tcp" },
      "sniffing": { "enabled": true, "destOverride": ["tls"], "routeOnly": true }
    }$reality_inbounds
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" }$redirect_outbounds,
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [$sni_rules
      { "inboundTag": ["sni-router"], "outboundTag": "direct" },
      { "inboundTag": [$reality_tags], "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"], "outboundTag": "block" }
    ]
  }
}
EOF
chmod 644 "$CONFIG"

# --- Ссылки для устройств --------------------------------------------------
{
  echo "# Публичный ключ: $PUBLIC_KEY"
  echo "# shortId:        $SHORT_ID"
  while read -r name uuid; do
    [[ -n "$name" ]] || continue
    echo
    echo "## $name — импортируй все строки ниже разом"
    for t in "${targets[@]}"; do
      echo "vless://$uuid@$SERVER_IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$t&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$name-$t"
    done
  done <"$CLIENTS_LIST"
} >"$CLIENTS_FILE"
chmod 600 "$CLIENTS_FILE"

# --- Перезапуск, если контейнер уже есть -----------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "==> Перезапускаю контейнер $CONTAINER..."
  docker restart "$CONTAINER" >/dev/null
  sleep 2
  docker ps --filter "name=^${CONTAINER}$" --filter status=running -q | grep -q . \
    || die "Xray не запустился. Смотри: docker logs $CONTAINER"
fi

echo
echo "==> Готово. Ссылки для устройств (они же в $CLIENTS_FILE):"
grep -v '^# ' "$CLIENTS_FILE"
echo
echo "Скопируй блок строк своего устройства и импортируй в приложение из буфера обмена."
