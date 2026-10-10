#!/bin/bash
# Entrypoint script for Docker container
# Connects to NordVPN Israel, runs scraper, disconnects VPN

set -euo pipefail

echo "========================================="
echo "🐳 Yad2 Scraper (Docker + NordVPN)"
echo "========================================="

# Verify required env vars
if [[ -z "${NORDVPN_TOKEN:-}" ]]; then
  echo "❌ NORDVPN_TOKEN not set"
  exit 1
fi

if [[ -z "${GOOGLE_CREDENTIALS_JSON:-}" ]]; then
  echo "❌ GOOGLE_CREDENTIALS_JSON not set"
  exit 1
fi

# Create data directory
mkdir -p /app/data

echo ""
echo "🔗 Connecting to NordVPN (Israel)..."

# Login to NordVPN with token
if ! nordvpn login --token "$NORDVPN_TOKEN" 2>&1 | grep -q "Already logged in\|Successfully"; then
  echo "⚠️ NordVPN login issue, continuing anyway..."
fi

# Connect to Israeli server
nordvpn connect Israel
sleep 5

# Verify exit IP is Israeli
echo "🌍 Verifying exit country..."
VERIFIED=false
for attempt in 1 2 3; do
  IP_COUNTRY=$(curl -fsSL --max-time 10 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || echo "")
  
  if [[ "$IP_COUNTRY" == "IL" ]]; then
    echo "✅ Connected through Israeli exit IP"
    VERIFIED=true
    break
  else
    echo "⚠️ Country check ${attempt}/3: got '${IP_COUNTRY:-unknown}', retrying..."
    sleep 3
  fi
done

if [[ "$VERIFIED" != "true" ]]; then
  echo "❌ Failed to verify Israeli exit IP"
  nordvpn disconnect 2>/dev/null || true
  exit 1
fi

echo ""
echo "🕷️ Starting Yad2 scraper..."
echo ""

# Run the scraper
cd /app
SCRAPER_EXIT_CODE=0
if python3 scripts/main.py; then
  SCRAPER_EXIT_CODE=0
else
  SCRAPER_EXIT_CODE=$?
fi

echo ""
echo "🔌 Disconnecting VPN..."
nordvpn disconnect 2>/dev/null || true

echo ""
if [[ $SCRAPER_EXIT_CODE -eq 0 ]]; then
  echo "✅ Scraper completed successfully"
else
  echo "❌ Scraper failed with exit code $SCRAPER_EXIT_CODE"
fi

exit $SCRAPER_EXIT_CODE
