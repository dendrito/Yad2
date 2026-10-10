```bash
#!/usr/bin/env bash
# Israeli NordVPN WireGuard connection for GitHub Actions.
# Usage: bash tools/il_vpn.sh up
#        bash tools/il_vpn.sh down

set -Eeuo pipefail

CONF="/etc/wireguard/nordil.conf"
MAX_SERVERS=20
API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bcountry_id%5D=105&filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=100"

log() {
  printf 'VPN: %s\n' "$*"
}

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

disconnect() {
  sudo wg-quick down "$CONF" >/dev/null 2>&1 || true
  sudo rm -f "$CONF"
}

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    log "Cleaning up after failure (exit code: $status)"
    disconnect
  fi
}
trap cleanup EXIT

case "${1:-up}" in
  down)
    log "Disconnecting"
    disconnect
    trap - EXIT
    log "Disconnected"
    exit 0
    ;;
  up) ;;
  *)
    echo "Usage: $0 [up|down]" >&2
    exit 2
    ;;
esac

: "${NORDVPN_TOKEN:?Add the NORDVPN_TOKEN repository secret}"

command -v curl >/dev/null 2>&1 || fail "curl is missing"
command -v python3 >/dev/null 2>&1 || fail "python3 is missing"

if ! command -v wg-quick >/dev/null 2>&1; then
  log "Installing WireGuard tools"
  sudo apt-get update -qq
  sudo apt-get install -y -qq wireguard-tools resolvconf
fi

log "Retrieving NordVPN credentials"

credentials="$(
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --retry 2 --retry-all-errors --retry-delay 2 \
    -u "token:${NORDVPN_TOKEN}" \
    "https://api.nordvpn.com/v1/users/services/credentials"
)" || fail "Could not retrieve NordVPN credentials"

key="$(
  printf '%s' "$credentials" |
    python3 -c '
import json, sys
data = json.load(sys.stdin)
key = data.get("nordlynx_private_key")
if not isinstance(key, str) or not key.strip():
    raise SystemExit("No usable private key in NordVPN response")
print(key)
'
)" || fail "Could not parse NordVPN credentials"

unset credentials
[[ -n "$key" ]] || fail "Empty NordVPN private key"
echo "::add-mask::$key"

log "Retrieving Israeli server recommendations"

server_json="$(
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --retry 2 --retry-all-errors --retry-delay 2 \
    "$API_URL"
)" || fail "Could not retrieve Israeli WireGuard recommendations"

run_number="${GITHUB_RUN_NUMBER:-1}"

server_lines="$(
  printf '%s' "$server_json" |
    RUN_NUMBER="$run_number" MAX_SERVERS="$MAX_SERVERS" python3 -c '
import json, os, sys

servers = json.load(sys.stdin)
if not isinstance(servers, list):
    raise SystemExit("Unexpected server response")

usable = []
seen = set()

for server in servers:
    if not isinstance(server, dict):
        continue

    hostname = server.get("hostname")
    endpoint = server.get("station")

    if not hostname or not endpoint or hostname in seen:
        continue

    technology = next(
        (t for t in server.get("technologies", [])
         if t.get("identifier") == "wireguard_udp"),
        None,
    )
    if not technology:
        continue

    public_key = next(
        (m.get("value") for m in technology.get("metadata", [])
         if m.get("name") == "public_key"),
        None,
    )
    if not public_key:
        continue

    values = (hostname, endpoint, public_key)
    if any(not isinstance(v, str) or not v or
           any(c.isspace() for c in v) for v in values):
        continue

    seen.add(hostname)
    usable.append((hostname, endpoint, public_key))

if not usable:
    raise SystemExit("No usable Israeli WireGuard servers found")

offset = (int(os.environ["RUN_NUMBER"]) - 1) % len(usable)
usable = usable[offset:] + usable[:offset]
usable = usable[:int(os.environ["MAX_SERVERS"])]

for hostname, endpoint, public_key in usable:
    print(f"{hostname}\t{endpoint}\t{public_key}")
'
)" || fail "Could not parse server recommendations"

unset server_json

mapfile -t servers <<< "$server_lines"
unset server_lines

count="${#servers[@]}"
(( count > 0 )) || fail "No usable server candidates"

log "Found $count candidates; run $run_number determines starting position"

for index in "${!servers[@]}"; do
  IFS=$'\t' read -r host ip pub <<< "${servers[$index]}"

  log "Attempt $((index + 1))/$count: $host"
  disconnect

  sudo install -m 600 /dev/null "$CONF"
  sudo tee "$CONF" >/dev/null <<WG
[Interface]
PrivateKey = ${key}
Address = 10.5.0.2/32
DNS = 103.86.96.100

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${ip}:51820
PersistentKeepalive = 25
WG

  log "Starting WireGuard tunnel"
  if ! sudo wg-quick up "$CONF"; then
    log "Tunnel setup failed for $host; trying next candidate"
    disconnect
    continue
  fi

  log "Verifying exit country"
  country=""

  for attempt in 1 2 3; do
    country="$(
      curl --fail --silent \
        --connect-timeout 5 --max-time 15 \
        "https://ipinfo.io/country" 2>/dev/null || true
    )"
    country="$(printf '%s' "$country" | tr -d '[:space:]')"

    [[ "$country" == "IL" ]] && break

    log "Country check $attempt/3 did not confirm Israel"
    sleep 3
  done

  if [[ "$country" == "IL" ]]; then
    log "Connected through $host; exit country is Israel"
    trap - EXIT
    exit 0
  fi

  log "Country verification failed for $host: ${country:-unknown}"
  disconnect
done

fail "All $count server candidates failed verification"
```
