```bash
#!/usr/bin/env bash
# Israeli NordVPN WireGuard connection for GitHub Actions.
# Usage: bash tools/il_vpn.sh up
#        bash tools/il_vpn.sh down

set -Eeuo pipefail

SCRIPT_VERSION="il-vpn-single-server-v1"
CONF="/etc/wireguard/nordil.conf"
API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bcountry_id%5D=105&filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=1"

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

log "Script version: $SCRIPT_VERSION"

case "${1:-up}" in
  down)
    log "Disconnecting"
    disconnect
    trap - EXIT
    log "Disconnected"
    exit 0
    ;;
  up)
    ;;
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

log "Retrieving Israeli server recommendation"

server_json="$(
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --retry 2 --retry-all-errors --retry-delay 2 \
    "$API_URL"
)" || fail "Could not retrieve Israeli WireGuard recommendation"

server_info="$(
  printf '%s' "$server_json" |
    python3 -c '
import json, sys

servers = json.load(sys.stdin)
if not isinstance(servers, list) or not servers:
    raise SystemExit("No recommended Israeli WireGuard servers returned")

for server in servers:
    if not isinstance(server, dict):
        continue

    hostname = server.get("hostname")
    endpoint = server.get("station")
    technology = next(
        (t for t in server.get("technologies", [])
         if t.get("identifier") == "wireguard_udp"),
        None,
    )
    if not hostname or not endpoint or not technology:
        continue

    public_key = next(
        (m.get("value") for m in technology.get("metadata", [])
         if m.get("name") == "public_key"),
        None,
    )
    values = (hostname, endpoint, public_key)
    if all(isinstance(v, str) and v and
           not any(c.isspace() for c in v) for v in values):
        print(*values, sep="\t")
        break
else:
    raise SystemExit("No usable Israeli WireGuard server found")
'
)" || fail "Could not parse Israeli server recommendation"

unset server_json

IFS=$'\t' read -r host ip pub <<< "$server_info"
unset server_info

[[ -n "$host" && -n "$ip" && -n "$pub" ]] ||
  fail "Incomplete server configuration"

log "Selected recommended server: $host"

# Remove any stale tunnel before creating a new configuration.
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

unset key

log "Starting WireGuard tunnel"
sudo wg-quick up "$CONF" ||
  fail "WireGuard could not start the selected tunnel"

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

if [[ "$country" != "IL" ]]; then
  fail "Tunnel did not verify an Israeli exit IP (country: ${country:-unknown})"
fi

log "Connected through $host; exit country is Israel"

# Keep the tunnel active for subsequent workflow steps.
trap - EXIT
exit 0
```
