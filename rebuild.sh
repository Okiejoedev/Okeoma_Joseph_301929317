#!/usr/bin/env bash
# Rebuilds the AgentLink database from scratch (Portfolio 1 scripts).
# Usage: ./rebuild.sh   (expects PostgreSQL on localhost:5432, user postgres)
set -euo pipefail
cd "$(dirname "$0")/portfolio-1-database-design"
PSQL="psql -U ${PGUSER:-postgres} -h ${PGHOST:-localhost} -p ${PGPORT:-5432} -v ON_ERROR_STOP=1 -q"
dropdb --if-exists -U ${PGUSER:-postgres} -h ${PGHOST:-localhost} -p ${PGPORT:-5432} agentlink
createdb -U ${PGUSER:-postgres} -h ${PGHOST:-localhost} -p ${PGPORT:-5432} agentlink
for f in 01_schema.sql 02_seed_reference.sql 03_generate_data.sql; do
  echo ">> $f"; $PSQL -d agentlink -f "$f" > /dev/null
done
echo "Done."
