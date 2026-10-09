```bash
#!/usr/bin/env bash
# Connect through up to 20 distinct Israeli NordVPN WireGuard servers.
#
# Usage:
#   tools/il_vpn.sh up
#   tools/il_vpn.sh down
#
# Required GitHub Actions secret: NORDVPN_TOKEN
# GITHUB_RUN_NUMBER rotates the starting server between workflow runs.

set -euo pipefail

CONF=/etc/wireguard/nordil.conf
MAX_SERVERS=20
API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bcountry_id%5D=105&filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=100"

disconnect() {
  sudo wg-quick down "$CONF" 2>/dev/null || true
  sudo rm -f "$CONF"
}

if [[ "${1:-}" == "down" ]]; then
  disconnect
  echo "Israeli VPN disconnected"
  exit 0
fi

if [[ "${1:-up}" != "up" ]]; then
  echo "Usage: $0 [up|down]" >&2
  exit 2
fi

: "${NORDVPN_TOKEN:?Add the NORDVPN_TOKEN repository secret}"

command -v curl >/dev/null || {
  echo "::error::curl is required"
  exit 1
}
command -v python3 >/dev/null || {
  echo "::error::python3 is required"
  exit 1
}

if ! command -v wg-quick >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq wireguard-tools resolvconf
fi

# Retrieve the private key. Never print it.
credentials=$(curl --fail --silent --show-error \
  --max-time 30 --retry 3 --retry-all-errors --retry-delay 2 \
  -u "token:${NORDVPN_TOKEN}" \
  https://api.nordvpn.com/v1/users/services/credentials) || {
    echo "::error::Could not retrieve NordVPN credentials"
    exit 1
  }

key=$(printf '%s' "$credentials" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["nordlynx_private_key"])') || {
    echo "::error::Could not parse NordVPN credentials"
    exit 1
  }

unset credentials
echo "::add-mask::$key"

# Fetch candidate servers and deduplicate by hostname.
server_json=$(curl --fail --silent --show-error \
  --max-time 30 --retry 3 --retry-all-errors --retry-delay 2 \
  "$API_URL") || {
    echo "::error::Could not retrieve Israeli WireGuard server list"
    exit 1
  }

# Output hostname, endpoint IP, and public key as tab-separated records.
# Rotate the starting point using the workflow run number.
run_number="${GITHUB_RUN_NUMBER:-1}"

server_lines=$(printf '%s' "$server_json" |
  RUN_NUMBER="$run_number" python3 -c '
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
        (t for t in server.get("technologies", [])
         if t.get("identifier") == "wireguard_udp"),
        None
    )
    if not technology:
        continue

    metadata = technology.get("metadata", [])
    public_key = next(
        (m.get("value") for m in metadata
         if m.get("name") == "public_key"),
        None
    )
    if not public_key:
        continue

    seen.add(hostname)
    unique.append((hostname, endpoint, public_key))

if not unique:
    sys.exit("No usable Israeli WireGuard servers returned")

offset = (int(os.environ.get("RUN_NUMBER", "1")) - 1) % len(unique)
unique = unique[offset:] + unique[:offset]
unique = unique[:20]

for hostname, endpoint, public_key in unique:
    print(f"{hostname}\t{endpoint}\t{public_key}")
') || {
    echo "::error::Could not parse the Israeli server list"
    exit 1
  }

unset server_json

# Load candidate servers into an array.
mapfile -t servers <<< "$server_lines"
unset server_lines

if [[ "${#servers[@]}" -eq 0 ]]; then
  echo "::error::No usable Israeli servers found"
  exit 1
fi

echo "Will try up to ${#servers[@]} distinct Israeli servers."

# Each hostname is tried at most once during this run.
for index in "${!servers[@]}"; do
  IFS=$'\t' read -r host ip pub <<< "${servers[$index]}"

  attempt=$((index + 1))
  echo "Trying Israeli server ${attempt}/${#servers[@]}: ${host}"

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
    echo "Could not establish tunnel through ${host}."
    disconnect
    continue
  fi

  country=""
  for check in 1 2 3; do
    country=$(curl --fail --silent --max-time 15 \
      https://ipinfo.io/country 2>/dev/null || true)
    country=$(printf '%s' "$country" | tr -d '[:space:]')

    if [[ "$country" == "IL" ]]; then
      echo "Connected through ${host}; Israeli exit country verified."
      exit 0
    fi

    sleep 3
  done

  echo "Exit country verification failed for ${host}: ${country:-unknown}."
  disconnect
done

echo "::error::All ${#servers[@]} distinct server attempts failed."
exit 1
```
