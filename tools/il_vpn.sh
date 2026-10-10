```bash
#!/usr/bin/env bash
# Connect to an Israeli NordVPN server using WireGuard.
#
# Usage:
#   bash tools/il_vpn.sh up
#   bash tools/il_vpn.sh down
#
# Required GitHub Actions secret: NORDVPN_TOKEN
# GITHUB_RUN_NUMBER rotates the starting server between runs.

set -Eeuo pipefail

CONF="/etc/wireguard/nordil.conf"
MAX_SERVERS=20
API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bcountry_id%5D=105&filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=100"

disconnect() {
  sudo wg-quick down "$CONF" >/dev/null 2>&1 || true
  sudo rm -f "$CONF"
}

cleanup_on_exit() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "VPN: cleaning up after failure"
    disconnect
  fi
}
trap cleanup_on_exit EXIT

fail() {
  echo "::error::$*"
  exit 1
}

if [[ "${1:-up}" == "down" ]]; then
  echo "VPN: disconnecting"
  disconnect
  trap - EXIT
  printf '%s\n' "Israeli VPN disconnected"
  exit 0
fi

if [[ "${1:-up}" != "up" ]]; then
  echo "Usage: $0 [up|down]" >&2
  exit 2
fi

: "${NORDVPN_TOKEN:?Add the NORDVPN_TOKEN repository secret}"

command -v curl >/dev/null 2>&1 || fail "curl is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed"

if ! command -v wg-quick >/dev/null 2>&1; then
  echo "VPN: installing WireGuard tools"
  sudo apt-get update -qq
  sudo apt-get install -y -qq wireguard-tools resolvconf
fi

echo "VPN: retrieving NordVPN credentials"

# Do not enable shell tracing here: the token is passed as a curl argument.
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
print(json.load(sys.stdin)["nordlynx_private_key"])
'
)" || fail "Could not parse NordVPN credentials"

unset credentials
[[ -n "$key" ]] || fail "NordVPN returned an empty private key"
echo "::add-mask::$key"

echo "VPN: retrieving Israeli WireGuard server recommendations"

server_json="$(
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --retry 2 --retry-all-errors --retry-delay 2 \
    "$API_URL"
)" || fail "Could not retrieve Israeli WireGuard recommendations"

echo "VPN: parsing and deduplicating server recommendations"

run_number="${GITHUB_RUN_NUMBER:-1}"

server_lines="$(
  printf '%s' "$server_json" |
    RUN_NUMBER="$run_number" MAX_SERVERS="$MAX_SERVERS" python3 -c '
import json, os, sys

servers = json.load(sys.stdin)
unique = []
seen = set()

for server in servers:
    hostname = server.get("hostname")
    endpoint = server.get("station")

    if not hostname or not endpoint or hostname in seen:
        continue

    technology = next(
        (
            t for t in server.get("technologies", [])
            if t.get("identifier") == "wireguard_udp"
        ),
        None,
    )
    if not technology:
        continue

    public_key = next(
        (
            m.get("value")
            for m in technology.get("metadata", [])
            if m.get("name") == "public_key"
        ),
        None,
    )
    if not public_key:
        continue

    seen.add(hostname)
    unique.append((hostname, endpoint, public_key))

if not unique:
    sys.exit("No usable Israeli WireGuard recommendations were returned")

offset = (int(os.environ.get("RUN_NUMBER", "1")) - 1) % len(unique)
unique = unique[offset:] + unique[:offset]
unique = unique[:int(os.environ["MAX_SERVERS"])]

for hostname, endpoint, public_key in unique:
    print(f"{hostname}\t{endpoint}\t{public_key}")
'
)" || fail "Could not parse Israeli server recommendations"

unset server_json

mapfile -t servers <<< "$server_lines"
unset server_lines

server_count="${#servers[@]}"
[[ "$server_count" -gt 0 ]] || fail "No usable Israeli servers found"

echo "VPN: found ${server_count} distinct usable server recommendations"

for index in "${!servers[@]}"; do
  IFS=$'\t' read -r host ip pub <<< "${servers[$index]}"

  echo "VPN: attempt $((index + 1))/${server_count} using ${host}"

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

  if ! sudo wg-quick up "$CONF" >/dev/null; then
    echo "VPN: tunnel setup failed for ${host}; trying the next server"
    disconnect
    continue
  fi

  echo "VPN: checking exit country for ${host}"

  country=""
  for check in 1 2 3; do
    country="$(
      curl --fail --silent \
        --connect-timeout 5 --max-time 15 \
        "https://ipinfo.io/country" 2>/dev/null || true
    )"
    country="$(printf '%s' "$country" | tr -d '[:space:]')"

    [[ "$country" == "IL" ]] && break
    sleep 3
  done

  if [[ "$country" == "IL" ]]; then
    echo "VPN: connected through ${host}; exit country verified as Israel"
    trap - EXIT
    exit 0
  fi

  echo "VPN: exit verification failed for ${host} (country: ${country:-unknown})"
  disconnect
done

fail "All ${server_count} distinct server attempts failed; no verified Israeli connection"
```
