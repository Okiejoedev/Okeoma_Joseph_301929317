-- =====================================================================
-- Portfolio 2: query rewriting experiments (run AFTER indexes.sql)
--   psql -d agentlink -f rewrites.sql > evidence_rewrites.txt
-- =====================================================================
SET search_path TO agentlink;
\pset pager off

\echo '=================================================================='
\echo 'R1. Non-sargable predicate: casting the column hides it from the index'
\echo '=================================================================='
\echo '--- R1a. created_at::date = ... (function applied to the column)'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM pos_transaction WHERE agent_id = 57 AND created_at::date = DATE '2026-10-15';
\echo '--- R1b. half-open range on the raw column (sargable)'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM pos_transaction WHERE agent_id = 57
  AND created_at >= '2026-10-15' AND created_at < '2026-10-16';

\echo '=================================================================='
\echo 'R2. NOT IN vs NOT EXISTS: a correctness bug, not only a speed issue'
\echo '    Question: how many customers cashed out but NEVER deposited (CASH_IN)?'
\echo '=================================================================='
\echo '--- R2a. NOT IN: the subquery returns NULL customer_ids (walk-in card users)'
SELECT count(*) AS not_in_result FROM customer c
WHERE c.customer_id IN (SELECT customer_id FROM pos_transaction WHERE type_code='CASH_OUT')
  AND c.customer_id NOT IN (SELECT customer_id FROM pos_transaction WHERE type_code='CASH_IN');
\echo '--- R2b. NOT EXISTS: correct answer'
SELECT count(*) AS not_exists_result FROM customer c
WHERE EXISTS     (SELECT 1 FROM pos_transaction t WHERE t.customer_id=c.customer_id AND t.type_code='CASH_OUT')
  AND NOT EXISTS (SELECT 1 FROM pos_transaction t WHERE t.customer_id=c.customer_id AND t.type_code='CASH_IN');
\echo '--- R2c. plan of the NOT EXISTS version (hash anti-join)'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM customer c
WHERE EXISTS     (SELECT 1 FROM pos_transaction t WHERE t.customer_id=c.customer_id AND t.type_code='CASH_OUT')
  AND NOT EXISTS (SELECT 1 FROM pos_transaction t WHERE t.customer_id=c.customer_id AND t.type_code='CASH_IN');

\echo '=================================================================='
\echo 'R3. Indexes cannot fix a large aggregate -> pre-aggregate with a MATERIALIZED VIEW'
\echo '=================================================================='
DROP MATERIALIZED VIEW IF EXISTS mv_agent_month;
\timing on
CREATE MATERIALIZED VIEW mv_agent_month AS
SELECT t.agent_id, date_trunc('month', t.created_at)::date AS month,
       count(*) FILTER (WHERE t.status='SUCCESS')               AS success_txns,
       sum(t.amount) FILTER (WHERE t.status='SUCCESS')          AS success_volume,
       COALESCE(sum(c.agent_amount), 0)                         AS agent_commission
FROM pos_transaction t
LEFT JOIN commission c ON c.txn_id = t.txn_id
GROUP BY t.agent_id, date_trunc('month', t.created_at)::date;
CREATE UNIQUE INDEX ON mv_agent_month (agent_id, month);   -- needed for REFRESH ... CONCURRENTLY
\timing off
ANALYZE mv_agent_month;

\echo '--- R3a. Q8 (top 10 agents by commission) on the base tables'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM (
    SELECT a.agent_code, sum(c.agent_amount) AS commission,
           RANK() OVER (ORDER BY sum(c.agent_amount) DESC) AS rnk
    FROM commission c JOIN pos_transaction t ON t.txn_id = c.txn_id
    JOIN agent a ON a.agent_id = t.agent_id
    WHERE t.created_at >= '2026-10-01' AND t.created_at < '2026-11-01'
    GROUP BY a.agent_code) r WHERE rnk <= 10;

\echo '--- R3b. Same question answered from the materialized view'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM (
    SELECT a.agent_code, m.agent_commission AS commission,
           RANK() OVER (ORDER BY m.agent_commission DESC) AS rnk
    FROM mv_agent_month m JOIN agent a USING (agent_id)
    WHERE m.month = DATE '2026-10-01') r WHERE rnk <= 10;

\echo '--- R3c. Both return the same top 10 (EXCEPT should return 0 rows)'
(SELECT a.agent_code, sum(c.agent_amount) FROM commission c JOIN pos_transaction t ON t.txn_id=c.txn_id
   JOIN agent a ON a.agent_id=t.agent_id
  WHERE t.created_at >= '2026-10-01' AND t.created_at < '2026-11-01' GROUP BY 1 ORDER BY 2 DESC LIMIT 10)
EXCEPT
(SELECT a.agent_code, m.agent_commission FROM mv_agent_month m JOIN agent a USING (agent_id)
  WHERE m.month = DATE '2026-10-01' ORDER BY 2 DESC LIMIT 10);

\echo '--- R3d. Cost of keeping it fresh (nightly job, readers are not blocked)'
\timing on
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_agent_month;
\timing off

\echo '=================================================================='
\echo 'R4. Planner statistics: estimated vs actual rows for a skewed column'
\echo '=================================================================='
EXPLAIN (ANALYZE, COSTS ON, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM pos_transaction WHERE status = 'PENDING';
SELECT attname, n_distinct, most_common_vals, most_common_freqs
FROM pg_stats WHERE schemaname='agentlink' AND tablename='pos_transaction' AND attname='status';
