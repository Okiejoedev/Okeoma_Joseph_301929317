-- =====================================================================
-- Portfolio 5 (part B): horizontal fragmentation inside PostgreSQL
-- pos_transaction re-created as a RANGE-partitioned table (one partition per month).
-- Run: psql -d agentlink -f 02_partitioning.sql > evidence_partitioning.txt
-- =====================================================================
SET search_path TO agentlink;
\pset pager off
DROP TABLE IF EXISTS txn_part CASCADE;

CREATE TABLE txn_part (
    txn_id       BIGINT        NOT NULL,
    txn_ref      VARCHAR(20)   NOT NULL,
    terminal_id  VARCHAR(8)    NOT NULL,
    agent_id     INT           NOT NULL,
    customer_id  INT,
    type_code    VARCHAR(10)   NOT NULL,
    amount       NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    fee          NUMERIC(10,2) NOT NULL,
    status       VARCHAR(10)   NOT NULL,
    created_at   TIMESTAMPTZ   NOT NULL,
    PRIMARY KEY (txn_id, created_at)          -- the partition key must be part of the PK
) PARTITION BY RANGE (created_at);

CREATE TABLE txn_2026_05 PARTITION OF txn_part FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE txn_2026_06 PARTITION OF txn_part FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE txn_2026_07 PARTITION OF txn_part FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE txn_2026_08 PARTITION OF txn_part FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE txn_2026_09 PARTITION OF txn_part FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE txn_2026_10 PARTITION OF txn_part FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE txn_2026_11 PARTITION OF txn_part FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE txn_default PARTITION OF txn_part DEFAULT;

INSERT INTO txn_part
SELECT txn_id, txn_ref, terminal_id, agent_id, customer_id, type_code, amount, fee, status, created_at
FROM pos_transaction;
CREATE INDEX ON txn_part (agent_id, created_at);      -- created on every partition automatically
ANALYZE txn_part;

\echo '--- P1. Rows per fragment (partition)'
SELECT tableoid::regclass AS partition, count(*) AS rows,
       pg_size_pretty(pg_relation_size(tableoid::regclass)) AS size
FROM txn_part GROUP BY tableoid ORDER BY 1;

\echo '--- P2. Partition PRUNING: October report touches only txn_2026_10'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*), sum(amount) FROM txn_part
WHERE status = 'SUCCESS' AND created_at >= '2026-10-01' AND created_at < '2026-11-01';

\echo '--- P3. Same report on the unpartitioned 1.2M-row table (uses the BRIN index from Portfolio 2)'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*), sum(amount) FROM pos_transaction
WHERE status = 'SUCCESS' AND created_at >= '2026-10-01' AND created_at < '2026-11-01';

\echo '--- P4. Data retention: archive May instantly (DETACH) vs row-by-row DELETE'
CREATE TEMP TABLE txn_flat AS SELECT * FROM txn_part;           -- unpartitioned copy for comparison
CREATE INDEX ON txn_flat (created_at);
\echo 'DELETE May rows from the unpartitioned copy:'
\timing on
DELETE FROM txn_flat WHERE created_at < '2026-06-01';
\timing off
\echo 'DETACH the May partition (becomes a standalone archive table):'
\timing on
ALTER TABLE txn_part DETACH PARTITION txn_2026_05;
\timing off
ALTER TABLE txn_2026_05 RENAME TO archive_txn_2026_05;
SELECT 'archive_txn_2026_05' AS archive_table, count(*) FROM archive_txn_2026_05;
SELECT count(*) AS rows_left_in_txn_part FROM txn_part;

\echo '--- P5. Same idea across sites: list-partition by region (horizontal fragmentation by location)'
CREATE TABLE agent_frag (LIKE agent) PARTITION BY LIST (lga_code);
CREATE TABLE agent_island   PARTITION OF agent_frag FOR VALUES IN ('ETI','LIS','IBL','EPE');
CREATE TABLE agent_mainland PARTITION OF agent_frag DEFAULT;
INSERT INTO agent_frag SELECT * FROM agent;
SELECT tableoid::regclass AS fragment, count(*) FROM agent_frag GROUP BY 1;
\echo 'In a distributed deployment each fragment would live at the site that uses it most (see MongoDB zone sharding).'

DROP TABLE agent_frag, archive_txn_2026_05, txn_part CASCADE;
