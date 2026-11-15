#!/usr/bin/env bash
# setup.sh - one-time environment setup for Joseph Okeoma's Advanced Database Portfolio (AgentLink Lagos)
# MIT 8103, matric 2026/A/MIT/0790. Target: GitHub Codespaces (Ubuntu). Run from the repo root:  bash setup.sh
# Installs PostgreSQL 16, MongoDB 8, Redis and the Python drivers, then starts all three servers
# in the same layout as the evidence (PostgreSQL /srv/pg/primary on 5432, MongoDB 27017, Redis 6379).
set -euo pipefail
echo "=== AgentLink setup: Joseph Okeoma, 2026/A/MIT/0790 ==="
if [ "${SKIP_APT:-0}" != "1" ]; then
  # Codespaces blocker: expired Yarn apt key breaks apt-get update
  sudo rm -f /etc/apt/sources.list.d/yarn.list
  sudo apt-get update -y
  sudo apt-get install -y curl ca-certificates gnupg lsb-release python3-pip redis-server jq
  if ! dpkg -s postgresql-16 >/dev/null 2>&1; then
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor --yes -o /usr/share/keyrings/postgresql-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y postgresql-16 postgresql-contrib postgresql-client-16
  fi
  if ! dpkg -s mongodb-org >/dev/null 2>&1; then
    curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y mongodb-org
  fi
fi
# Python drivers, installed system-wide because Portfolio 5 runs two scripts with sudo
sudo pip3 install --break-system-packages "psycopg[binary]" pymongo redis matplotlib
# The packaged PostgreSQL cluster would take port 5432; the project uses its own cluster in /srv/pg/primary
sudo pg_ctlcluster 16 main stop 2>/dev/null || true
# Start PostgreSQL (/srv/pg/primary), MongoDB (/srv/mongo/single) and Redis
sudo bash scripts/start_servers.sh
# TCP logins from localhost need no password (coursework only), as in the evidence runs
sudo runuser -u postgres -- /usr/lib/postgresql/16/bin/psql -h localhost -U postgres -Atc "SELECT 'PostgreSQL ' || current_setting('server_version')"
echo "SETUP-OK: PostgreSQL, MongoDB and Redis are running. Next: bash runall.sh"
