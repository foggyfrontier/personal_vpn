#!/usr/bin/env bash
#
# Самопроверка VPN с самого сервера.
#
# Запускает временный Xray-клиент на сервере и подключается им к своему же
# VPN по каждой ссылке (как это делает телефон), затем открывает через туннель
# https://ipinfo.io/ip. Российские сети в этой проверке не участвуют, поэтому:
#   - всё ✓ здесь, но не работает с телефона  → режут по дороге из РФ;
#   - ✗ здесь                                  → проблема в самом сервере.
#
# Запуск (на сервере, от root):  bash diagnose.sh
#
set -euo pipefail

XRAY_DIR="${XRAY_DIR:-/opt/xray}"
IMAGE="${IMAGE:-teddysun/xray:latest}"
CONTAINER="${CONTAINER:-xray}"
PORT="${PORT:-443}"
TEST_NAME="xray-selftest"
TEST_DIR="$(mktemp -d)"
trap 'docker rm -f "$TEST_NAME" >/dev/null 2>&1 || true; rm -rf "$TEST_DIR"' EXIT

die() { echo "Ошибка: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "запускай от root."
[[ -f "$XRAY_DIR/state.env" ]] || die "нет $XRAY_DIR/state.env. Сначала запусти setup.sh."
# shellcheck source=/dev/null
source "$XRAY_DIR/state.env"
uuid="$(awk 'NF {print $2; exit}' "$XRAY_DIR/clients.list")"
mapfile -t targets < <(grep -Eo 'sni=[^&]+' "$XRAY_DIR/clients.txt" | cut -d= -f2 | awk '!seen[$0]++')
[[ ${#targets[@]} -gt 0 ]] || die "не нашёл ссылок в $XRAY_DIR/clients.txt."

echo "==> Контейнер $CONTAINER:"
docker ps -a --filter "name=^${CONTAINER}$" --format '    {{.Status}}  {{.Ports}}'
echo

# Один клиент: для каждого сайта свой SOCKS-порт 2000N и свой выход.
inbounds="" outbounds="" rules=""
for i in "${!targets[@]}"; do
  t="${targets[$i]}"
  inbounds+="${inbounds:+,}
    { \"tag\": \"in-$i\", \"listen\": \"127.0.0.1\", \"port\": $((20001 + i)), \"protocol\": \"socks\", \"settings\": { \"udp\": false } }"
  outbounds+="${outbounds:+,}
    { \"tag\": \"out-$i\", \"protocol\": \"vless\",
      \"settings\": { \"vnext\": [{ \"address\": \"$SERVER_IP\", \"port\": $PORT,
        \"users\": [{ \"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\", \"encryption\": \"none\" }] }] },
      \"streamSettings\": { \"network\": \"tcp\", \"security\": \"reality\",
        \"realitySettings\": { \"serverName\": \"$t\", \"fingerprint\": \"chrome\",
          \"publicKey\": \"$PUBLIC_KEY\", \"shortId\": \"$SHORT_ID\" } } }"
  rules+="${rules:+,}
      { \"inboundTag\": [\"in-$i\"], \"outboundTag\": \"out-$i\" }"
done
cat >"$TEST_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [$inbounds
  ],
  "outbounds": [$outbounds
  ],
  "routing": { "rules": [$rules
  ] }
}
EOF

docker rm -f "$TEST_NAME" >/dev/null 2>&1 || true
docker run -d --name "$TEST_NAME" --network host \
  -v "$TEST_DIR/config.json:/etc/xray/config.json:ro" "$IMAGE" >/dev/null
sleep 2

echo "==> Проверяю каждую ссылку с самого сервера (ожидается IP $SERVER_IP):"
ok=0
for i in "${!targets[@]}"; do
  ip="$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$((20001 + i))" https://ipinfo.io/ip || true)"
  if [[ "$ip" == "$SERVER_IP" ]]; then
    echo "  ✓ ${targets[$i]}"
    ok=$((ok + 1))
  else
    echo "  ✗ ${targets[$i]} (ответ: '${ip:-нет}')"
  fi
done
echo

if [[ $ok -eq ${#targets[@]} ]]; then
  echo "Итог: сервер работает. Если с телефона не подключается, соединение режут по дороге из РФ."
else
  echo "Итог: сервер работает не полностью. Логи клиента и сервера:"
  docker logs --tail 20 "$TEST_NAME" 2>&1 | sed 's/^/  [клиент] /'
  docker logs --tail 20 "$CONTAINER" 2>&1 | sed 's/^/  [сервер] /'
fi
