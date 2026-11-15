#!/usr/bin/env bash
# runall.sh - runs Portfolios 1-5 in order, saves each real log, commits and pushes each, then writes my_results.txt
# Usage: bash runall.sh      (or: bash runall.sh 3   to restart from Portfolio 3)
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"; cd "$REPO"
START="${1:-1}"
export PGHOST=localhost PGUSER=postgres PGPORT=5432
PSQL="psql -h localhost -U postgres -X -v ON_ERROR_STOP=1"
# Codespaces stops background programs when it sleeps: start the servers again if needed
pg_isready -h localhost -p 5432 -q && redis-cli ping >/dev/null 2>&1 && pgrep -x mongod >/dev/null || { echo "[runall] starting servers"; sudo bash scripts/start_servers.sh || { echo "!!! servers did not start - send Joseph the last lines"; exit 1; }; }
step() { # N folder function
  local N="$1" F="$2"
  echo; echo "================ PORTFOLIO $N ($F) ================"
  cd "$REPO/$F"; "$3" 2>&1 | tee "p${N}_output.log"; local rc=${PIPESTATUS[0]}; cd "$REPO"
  if [ "$rc" -ne 0 ]; then echo "!!! P$N FAILED - send Joseph the file $F/p${N}_output.log"; return 1; fi
  git add -A >/dev/null 2>&1; git commit -qm "Portfolio $N: real run output from my Codespace" >/dev/null 2>&1; git push -q >/dev/null 2>&1 || true
  echo "[runall] P$N done and committed"
}
p1() { set -e; cd "$REPO"; echo ">> rebuild (about 3 minutes)"; ./rebuild.sh; cd portfolio-1-database-design
  $PSQL -d agentlink -f 04_constraint_tests.sql; $PSQL -d agentlink -f 05_integrity_checks.sql
  echo "=== P1 row counts ==="; $PSQL -d agentlink -c "SELECT (SELECT count(*) FROM agentlink.pos_transaction) transactions, (SELECT count(*) FROM agentlink.ledger_entry) ledger_rows;" 2>&1 || true; }
p2() { set -e; rm -rf "$HOME/p2run"; cp -r "$REPO/portfolio-2-query-optimisation" "$HOME/p2run"; cd "$HOME/p2run"; python3 benchmark.py; }
p3() { set -e; $PSQL -d agentlink -f procedures.sql -q; python3 demos.py; }
p4() { set -e; python3 load_mongo.py; mongosh --quiet agentlink mongo_queries.js; python3 redis_demo.py; }
p5() { set -e; $PSQL -d agentlink -f 02_partitioning.sql
  echo "=== P5 PostgreSQL streaming replication ==="; sudo runuser -u postgres -- bash "$REPO/portfolio-5-distributed-cloud/01_pg_replication.sh"
  echo "=== P5 MongoDB replica set ==="; sudo env MONGOD="${MONGOD:-/usr/bin/mongod}" python3 03_mongo_replicaset.py
  echo "=== P5 MongoDB sharding ==="; sudo env MONGOD="${MONGOD:-/usr/bin/mongod}" python3 04_mongo_sharding.py; }
F1=portfolio-1-database-design; F2=portfolio-2-query-optimisation; F3=portfolio-3-transactions-concurrency; F4=portfolio-4-nosql; F5=portfolio-5-distributed-cloud
[ "$START" -le 1 ] && { step 1 $F1 p1 || exit 1; }
[ "$START" -le 2 ] && { step 2 $F2 p2 || exit 1; }
[ "$START" -le 3 ] && { step 3 $F3 p3 || exit 1; }
[ "$START" -le 4 ] && { step 4 $F4 p4 || exit 1; }
[ "$START" -le 5 ] && { step 5 $F5 p5 || exit 1; }
bash collect_results.sh && { code my_results.txt 2>/dev/null || true; }
echo "[runall] ALL DONE - my_results.txt is open. Copy everything in it and send it to Joseph."
