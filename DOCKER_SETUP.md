# Docker Setup Guide for Yad2 Scraper

This repo now includes a Docker setup that runs the scraper inside an Ubuntu container while connecting to NordVPN with an Israeli exit IP.

## Requirements

- Docker Desktop installed
- NordVPN token
- Google service account JSON
- Telegram token if you want notifications

## Setup

1. Copy the example env file:
   ```bash
   cp .env.example .env
   ```
2. Fill in the values in `.env`.
3. Build:
   ```bash
   docker compose build
   ```
4. Run:
   ```bash
   docker compose up
   ```

## Notes

- The container connects to NordVPN and verifies that the public IP is in Israel before running the scraper.
- The VPN is disconnected after the scraper exits.
- The `data/seen_properties.json` cache is kept in a Docker volume under `yad2-data`.

## Troubleshooting

### NordVPN login fails
Check that `NORDVPN_TOKEN` is valid and not expired.

### Exit IP is not Israel
The VPN may have connected to a non-Israeli server; the script will exit before scraping begins.

### Google Sheets or Telegram credentials are missing
Ensure the environment variables are set in `.env` and passed into the container via `docker-compose.yml`.

