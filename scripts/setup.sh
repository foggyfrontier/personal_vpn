#!/usr/bin/env bash
#
# Первоначальная настройка Xray (VLESS + Reality).
#
# Что делает скрипт:
#   1. Генерирует пару ключей Reality (x25519) и shortId.
#   2. Создаёт по одному UUID на каждого клиента (устройство).
#   3. Пишет конфиг сервера в /opt/xray/config.json.
#   4. Сохраняет ссылки для клиентов в /opt/xray/clients.txt и печатает их
#      (и QR-коды, если установлен qrencode).
#
# Запуск (на сервере, от root):
#   bash setup.sh                     # клиенты по умолчанию: android windows iphone
#   bash setup.sh phone laptop        # свои имена клиентов
#   SNI=www.example.com bash setup.sh # другой сайт для маскировки
#
# Повторный запуск не перезапишет существующий конфиг: новые ключи сломают
# уже настроенные устройства. Чтобы всё же пересоздать: FORCE=1 bash setup.sh
#
set -euo pipefail

XRAY_DIR="${XRAY_DIR:-/opt/xray}"
IMAGE="${IMAGE:-teddysun/xray:latest}"
# Сайт, под который маскируемся. Должен открываться из РФ и поддерживать TLS 1.3.
SNI="${SNI:-www.microsoft.com}"
PORT="${PORT:-443}"

CONFIG="$XRAY_DIR/config.json"
CLIENTS_FILE="$XRAY_DIR/clients.txt"

die() { echo "Ошибка: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "запускай от root."
command -v docker >/dev/null || die "Docker не найден."
command -v openssl >/dev/null || die "openssl не найден (apt install openssl)."

if [[ -f "$CONFIG" && "${FORCE:-0}" != "1" ]]; then
  die "$CONFIG уже существует. Ссылки клиентов лежат в $CLIENTS_FILE.
Чтобы пересоздать всё с новыми ключами: FORCE=1 bash $0"
fi

clients=("$@")
[[ ${#clients[@]} -gt 0 ]] || clients=(android windows iphone)

echo "==> Генерирую ключи Reality (через образ $IMAGE)..."
keys="$(docker run --rm --entrypoint xray "$IMAGE" x25519)"
# Формат вывода: "PrivateKey: ..." на первой строке, публичный ключ на второй.
private_key="$(awk -F': ' 'NR==1 {print $NF}' <<<"$keys")"
public_key="$(awk -F': ' 'NR==2 {print $NF}' <<<"$keys")"
[[ -n "$private_key" && -n "$public_key" ]] || die "не удалось разобрать вывод xray x25519:
$keys"

short_id="$(openssl rand -hex 8)"

echo "==> Определяю внешний IP сервера..."
server_ip="$(curl -fsS4 --max-time 10 https://ipinfo.io/ip)" || die "не удалось определить IP."

# Список клиентов для конфига и ссылки для устройств.
clients_json=""
links=""
for name in "${clients[@]}"; do
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  [[ -z "$clients_json" ]] || clients_json+=","
  clients_json+="
          { \"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\", \"email\": \"$name\" }"
  links+="$name vless://$uuid@$server_ip:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#vpn-$name
"
done

mkdir -p "$XRAY_DIR"
chmod 700 "$XRAY_DIR"

echo "==> Пишу $CONFIG"
cat >"$CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [$clients_json
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$SNI:443",
          "serverNames": ["$SNI"],
          "privateKey": "$private_key",
          "shortIds": ["$short_id"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
chmod 644 "$CONFIG"

# Публичный ключ нужен только клиентам, но сохраним его рядом на всякий случай.
{
  echo "# Публичный ключ: $public_key"
  echo "# shortId:        $short_id"
  echo "# SNI:            $SNI"
  echo "$links"
} >"$CLIENTS_FILE"
chmod 600 "$CLIENTS_FILE"

echo
echo "==> Готово. Ссылки для устройств (они же в $CLIENTS_FILE):"
echo
while read -r name link; do
  [[ -n "$name" ]] || continue
  echo "--- $name ---"
  echo "$link"
  if command -v qrencode >/dev/null; then
    qrencode -t ansiutf8 "$link"
  fi
  echo
done <<<"$links"

command -v qrencode >/dev/null || echo "Совет: apt install qrencode — тогда скрипт покажет QR-коды для телефона."
echo "Дальше: запусти стек из docker-compose.yml в Portainer (см. README)."
