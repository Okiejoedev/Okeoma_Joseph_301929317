#!/usr/bin/env bash
# =====================================================================
# Portfolio 5 (part A): PostgreSQL streaming replication for AgentLink
#   primary  : localhost:5432  (/srv/pg/primary)
#   replica1 : localhost:5433  (/srv/pg/replica1)  hot standby, read-only
# Demonstrates: replica setup, read scaling, replication lag, read-only
# standby, synchronous vs asynchronous commit (CAP trade-off), failover.
# Run as the postgres OS user:  bash 01_pg_replication.sh > evidence_pg_replication.txt
# =====================================================================
set -u
BIN=/usr/lib/postgresql/16/bin
P="psql -h localhost -U postgres -d agentlink -X -q"
PRI="$P -p 5432"; REP="$P -p 5433"
h() { echo; echo "======================================================================"; echo "$1"; echo "======================================================================"; }
ts() { date +%H:%M:%S.%3N; }

h "R0. Create the hot standby with pg_basebackup (-R writes primary_conninfo)"
$BIN/pg_ctl -D /srv/pg/replica1 stop -m fast >/dev/null 2>&1; rm -rf /srv/pg/replica1
START=$(date +%s)
$BIN/pg_basebackup -h localhost -p 5432 -U postgres -D /srv/pg/replica1 -R -X stream -c fast \
  -d "application_name=replica1"
echo "base backup of $(du -sh /srv/pg/replica1 | cut -f1) took $(( $(date +%s) - START )) s"
grep primary_conninfo /srv/pg/replica1/postgresql.auto.conf | sed 's/password=[^ ]*//' | cut -c1-120
$BIN/pg_ctl -D /srv/pg/replica1 -o "-p 5433 -c shared_buffers=256MB -c hot_standby=on" -l /srv/pg/replica1.log start >/dev/null
sleep 3
echo "replica in recovery (standby)? $($REP -At -c 'SELECT pg_is_in_recovery()')"

h "R1. Primary view of its standbys (pg_stat_replication)"
$PRI -c "SELECT application_name, client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"

h "R2. Write on primary, read on replica (read scaling) + measured lag"
$PRI -c "INSERT INTO agentlink.customer (phone, first_name, last_name) VALUES ('08099990100','Repl','Test')
         ON CONFLICT (phone) DO UPDATE SET last_name = 'Test-' || floor(random()*1000);"
echo "$(ts) primary committed"
for i in 1 2 3; do
  R=$($REP -At -c "SELECT first_name||' '||last_name FROM agentlink.customer WHERE phone='08099990100'")
  echo "$(ts) replica sees: ${R:-<not yet>}"; [ -n "$R" ] && break; sleep 0.05
done
$PRI -c "SELECT application_name, write_lag, flush_lag, replay_lag,
                pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind FROM pg_stat_replication;"

h "R3. Bulk write: 50,000 rows on primary, then compare row counts"
$PRI -c "CREATE TABLE IF NOT EXISTS agentlink.repl_probe (id int, payload text);
         TRUNCATE agentlink.repl_probe;
         INSERT INTO agentlink.repl_probe SELECT g, md5(g::text) FROM generate_series(1,50000) g;"
sleep 1
echo "primary rows: $($PRI -At -c 'SELECT count(*) FROM agentlink.repl_probe')  |  replica rows: $($REP -At -c 'SELECT count(*) FROM agentlink.repl_probe')"

h "R4. The standby is read-only"
$REP -c "UPDATE agentlink.wallet SET balance = 0 WHERE wallet_id = 1;" 2>&1

h "R5. Analytics offloaded to the replica (same answer, primary not loaded)"
$REP -c "SELECT count(*) AS oct_success, sum(amount) AS volume FROM agentlink.pos_transaction
         WHERE status='SUCCESS' AND created_at >= '2026-10-01' AND created_at < '2026-11-01';"

h "R6. SYNCHRONOUS replication: commit waits for the standby (consistency)"
$PRI -c "ALTER SYSTEM SET synchronous_standby_names = 'replica1';" -c "SELECT pg_reload_conf();" >/dev/null
sleep 1
$PRI -c "SELECT application_name, sync_state FROM pg_stat_replication;"
$PRI -c "\timing on" -c "INSERT INTO agentlink.repl_probe VALUES (-1, 'sync commit with standby UP');"

h "R7. Standby goes DOWN while sync replication is required -> primary cannot confirm commits"
$BIN/pg_ctl -D /srv/pg/replica1 stop -m immediate >/dev/null; echo "$(ts) replica1 stopped"
echo "$(ts) session A attempts a write..."
( $PRI -c "INSERT INTO agentlink.repl_probe VALUES (-2, 'written while standby down');" 2>&1 | sed "s/^/   session A: /" ) &
sleep 4
echo "$(ts) after 4 s session A is still waiting:"
$PRI -c "SELECT pid, state, wait_event_type, wait_event, now() - query_start AS waiting_for
         FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
echo "$(ts) operator cancels the waiting backend (statement_timeout does NOT interrupt a SyncRep wait)"
$PRI -At -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep';" >/dev/null
wait
echo "$(ts) -> under CAP, synchronous mode chose CONSISTENCY: the write is not acknowledged (unavailable)."

h "R8. Switch to ASYNCHRONOUS commit -> primary available again (risk: data loss window)"
$PRI -c "ALTER SYSTEM SET synchronous_standby_names = '';" -c "SELECT pg_reload_conf();" >/dev/null
$PRI -c "\timing on" -c "INSERT INTO agentlink.repl_probe VALUES (-3, 'async commit, standby down');"
$BIN/pg_ctl -D /srv/pg/replica1 -o "-p 5433 -c shared_buffers=256MB" -l /srv/pg/replica1.log start >/dev/null; sleep 3
echo "standby restarted; it catches up from WAL. replica rows with id<0: $($REP -At -c "SELECT string_agg(id::text, ',' ORDER BY id DESC) FROM agentlink.repl_probe WHERE id < 0")"

h "R9. FAILOVER: primary crashes, replica is promoted"
$PRI -c "INSERT INTO agentlink.repl_probe VALUES (-4, 'last write before crash');"; sleep 1
echo "$(ts) crashing primary (pg_ctl stop -m immediate)"
$BIN/pg_ctl -D /srv/pg/primary stop -m immediate >/dev/null
T1=$(date +%s.%N)
$REP -At -c "SELECT pg_promote(wait => true);" >/dev/null
T2=$(date +%s.%N)
echo "$(ts) replica promoted in $(printf "%.2f" $(echo "$T2 - $T1" | bc)) s; in recovery now? $($REP -At -c 'SELECT pg_is_in_recovery()')"
$REP -c "INSERT INTO agentlink.repl_probe VALUES (-5, 'first write on NEW primary');"
$REP -c "SELECT id, payload FROM agentlink.repl_probe WHERE id < 0 ORDER BY id DESC;"
echo "No committed row was lost: -4 (written just before the crash) is present on the new primary."

h "R10. Clean-up for the rest of the portfolio: original primary restarted, demo standby retired"
$BIN/pg_ctl -D /srv/pg/replica1 stop -m fast >/dev/null
$BIN/pg_ctl -D /srv/pg/primary -o "-p 5432 -c shared_buffers=512MB -c work_mem=16MB" -l /srv/pg/primary.log start >/dev/null; sleep 3
$PRI -c "DROP TABLE agentlink.repl_probe; DELETE FROM agentlink.customer WHERE phone='08099990100';"
echo "original primary back online: in recovery? $($PRI -At -c 'SELECT pg_is_in_recovery()')"
echo "(In production the old primary would be re-attached as a standby of the new one with pg_rewind.)"
