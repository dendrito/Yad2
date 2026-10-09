#!/usr/bin/env bash
# Connect this GitHub Actions runner to an Israeli NordVPN server over NordLynx (WireGuard), or disconnect.
#
#   tools/il_vpn.sh up      # needs the repo secret NORDVPN_TOKEN (Nord Account → NordVPN → Manual setup → access token)
#   tools/il_vpn.sh down
#
# Used only to reach Israeli sites that refuse foreign IP addresses but allow crawling. The crawler's own rules
# still apply through the tunnel: robots.txt, pacing, and stopping at login or bot walls.
set -euo pipefail
CONF=/etc/wireguard/nordil.conf

if [ "${1:-}" = "down" ]; then
  sudo wg-quick down "$CONF" 2>/dev/null || true
  sudo rm -f "$CONF"
  echo "Israeli VPN disconnected"
  exit 0
fi

: "${NORDVPN_TOKEN:?Add the NORDVPN_TOKEN repository secret (Nord Account → NordVPN → Manual setup → generate an access token)}"
command -v wg-quick >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq wireguard-tools resolvconf >/dev/null; }

# Private key for NordLynx, from your account (never printed: masked in the log).
key=$(curl -sf --max-time 30 -u "token:${NORDVPN_TOKEN}" https://api.nordvpn.com/v1/users/services/credentials \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['nordlynx_private_key'])") \
  || { echo "::error::NordVPN refused the access token (expired or wrong?)"; exit 1; }
echo "::add-mask::$key"

# NordVPN's recommended Israeli WireGuard server (Israel = country 105 in NordVPN's API).
read -r host ip pub < <(curl -sf --max-time 30 \
  "https://api.nordvpn.com/v1/servers/recommendations?filters\[country_id\]=105&filters\[servers_technologies\]\[identifier\]=wireguard_udp&limit=1" \
  | python3 -c "
import json, sys
s = json.load(sys.stdin)[0]
t = next(t for t in s['technologies'] if t['identifier'] == 'wireguard_udp')
print(s['hostname'], s['station'], next(m['value'] for m in t['metadata'] if m['name'] == 'public_key'))")

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
sudo wg-quick up "$CONF" >/dev/null

country=""
for i in 1 2 3; do
  country=$(curl -s --max-time 15 https://ipinfo.io/country || true)
  [ "$country" = "IL" ] && break
  sleep 3
done
if [ "$country" != "IL" ]; then
  echo "::error::The tunnel to ${host} is up but the exit country is '${country:-unknown}', not IL"
  sudo wg-quick down "$CONF" || true
  exit 1
fi
echo "Connected through ${host}: traffic now leaves from Israel"
