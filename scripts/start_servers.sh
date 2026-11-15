#!/usr/bin/env bash
# Starts the three database servers used by Portfolios 1-4 in the same layout as the evidence:
#   PostgreSQL 16 primary  : /srv/pg/primary      port 5432 (trust auth - coursework only)
#   MongoDB (single node)  : /srv/mongo/single    port 27017
#   Redis 7                : port 6379
# Usage (Ubuntu / WSL2):  sudo bash scripts/start_servers.sh
set -e
PGBIN=/usr/lib/postgresql/16/bin
MONGOD=${MONGOD:-$(command -v mongod)}

# --- PostgreSQL: create the cluster once, then start it
if [ ! -d /srv/pg/primary ]; then
  systemctl stop postgresql 2>/dev/null || service postgresql stop 2>/dev/null || true
  mkdir -p /srv/pg && chown postgres /srv/pg
  su postgres -c "$PGBIN/initdb -D /srv/pg/primary -A trust -U postgres" >/dev/null
fi
if ! $PGBIN/pg_isready -h localhost -p 5432 -q; then
  su postgres -c "$PGBIN/pg_ctl -D /srv/pg/primary -o '-p 5432 -c shared_buffers=512MB -c work_mem=16MB' -l /srv/pg/primary.log start" >/dev/null
fi

# --- MongoDB single node
mkdir -p /srv/mongo/single
if ! pgrep -f "dbpath /srv/mongo/single" >/dev/null; then
  "$MONGOD" --dbpath /srv/mongo/single --port 27017 --bind_ip 127.0.0.1 \
            --wiredTigerCacheSizeGB 0.5 --fork --logpath /srv/mongo/single.log >/dev/null
fi

# --- Redis (no persistence needed for the demos)
redis-cli ping >/dev/null 2>&1 || redis-server --port 6379 --daemonize yes --save "" >/dev/null

sleep 2
echo "PostgreSQL: $(psql -h localhost -U postgres -At -c 'SHOW server_version')"
echo "MongoDB   : $(mongosh --quiet --eval 'db.version()')"
echo "Redis     : $(redis-cli ping)"
