#!/usr/bin/env bash
#
# Смена сайта, под который маскируется Reality (SNI / target).
# Ключи и UUID не меняются: на устройствах достаточно поменять поле SNI
# или заново импортировать ссылку.
#
# Запуск (на сервере, от root):
#   bash set-target.sh www.samsung.com
#   bash set-target.sh --check www.samsung.com www.nvidia.com   # только проверить, ничего не меняя
#
set -euo pipefail

XRAY_DIR="${XRAY_DIR:-/opt/xray}"
CONTAINER="${CONTAINER:-xray}"
CONFIG="$XRAY_DIR/config.json"
CLIENTS_FILE="$XRAY_DIR/clients.txt"

die() { echo "Ошибка: $*" >&2; exit 1; }

# Reality требует от сайта TLS 1.3 и HTTP/2 (ALPN h2).
check_host() {
  local host="$1" out
  out="$(timeout 10 openssl s_client -connect "$host:443" -servername "$host" \
    -tls1_3 -alpn h2 </dev/null 2>/dev/null || true)"
  if ! grep -q "TLSv1.3" <<<"$out"; then
    echo "  ✗ $host: нет TLS 1.3 или сайт недоступен с сервера"; return 1
  fi
  if ! grep -q "ALPN protocol: h2" <<<"$out"; then
    echo "  ✗ $host: нет HTTP/2"; return 1
  fi
  echo "  ✓ $host: TLS 1.3 + HTTP/2"
}

if [[ "${1:-}" == "--check" ]]; then
  shift
  [[ $# -gt 0 ]] || die "укажи хотя бы один сайт."
  for h in "$@"; do check_host "$h" || true; done
  exit 0
fi

[[ $# -eq 1 ]] || die "использование: bash $0 <сайт>   или   bash $0 --check <сайт>..."
new="$1"
[[ $EUID -eq 0 ]] || die "запускай от root."
[[ -f "$CONFIG" ]] || die "$CONFIG не найден. Сначала запусти setup.sh."

old="$(sed -n 's/.*"serverNames": \["\([^"]*\)"\].*/\1/p' "$CONFIG")"
[[ -n "$old" ]] || die "не удалось найти текущий SNI в $CONFIG."

echo "==> Проверяю $new..."
check_host "$new" || die "этот сайт не подходит, попробуй другой."

echo "==> Меняю $old -> $new"
cp "$CONFIG" "$CONFIG.bak"
sed -i \
  -e "s|\"dest\": \"$old:443\"|\"dest\": \"$new:443\"|" \
  -e "s|\"serverNames\": \[\"$old\"\]|\"serverNames\": [\"$new\"]|" \
  "$CONFIG"
if [[ -f "$CLIENTS_FILE" ]]; then
  sed -i -e "s|sni=$old&|sni=$new\&|g" -e "s|^# SNI: .*|# SNI:            $new|" "$CLIENTS_FILE"
fi

echo "==> Перезапускаю контейнер $CONTAINER..."
docker restart "$CONTAINER" >/dev/null
sleep 2
if ! docker ps --filter "name=^${CONTAINER}$" --filter status=running -q | grep -q .; then
  cp "$CONFIG.bak" "$CONFIG"
  docker restart "$CONTAINER" >/dev/null
  die "Xray не запустился с новым конфигом, вернул старый. Смотри: docker logs $CONTAINER"
fi

echo
echo "Готово. На устройствах поменяй SNI (serverName) на: $new"
echo "Или заново импортируй ссылку:"
grep -v '^#' "$CLIENTS_FILE" | sed '/^$/d'
