-- =====================================================================
-- Portfolio 2: indexes added after analysing the "before" execution plans
-- Each index is linked to the query (or queries) whose plan justified it.
-- =====================================================================
SET search_path TO agentlink;

-- Q1: equality on customer_id + ORDER BY created_at DESC LIMIT 20.
-- A composite B-tree in the same order lets PostgreSQL read just 20 index
-- entries and stop. No sort is needed and the other rows are never touched.
CREATE INDEX idx_txn_customer_time ON pos_transaction (customer_id, created_at DESC);

-- Q2 + Q3: equality on agent_id + range on created_at.
-- INCLUDE puts the extra columns in the leaf pages so the limit check (Q3)
-- can run as an INDEX-ONLY scan without visiting the table heap.
CREATE INDEX idx_txn_agent_time ON pos_transaction (agent_id, created_at)
    INCLUDE (type_code, status, amount, fee);

-- Q4: only about 4% of rows are FAILED. A PARTIAL index stores only those rows,
-- so it is small and cheap to maintain.
CREATE INDEX idx_txn_failed_time ON pos_transaction (created_at) WHERE status = 'FAILED';

-- Q5: wallet statement = equality on wallet_id + date range.
CREATE INDEX idx_ledger_wallet_time ON ledger_entry (wallet_id, created_at);

-- Q6 (and the double-entry trigger in P3): PostgreSQL does NOT index foreign keys
-- automatically. Joining ledger_entry by txn_id needs this index.
CREATE INDEX idx_ledger_txn ON ledger_entry (txn_id);

-- Q7 / Q8 / Q9: the rows were inserted in time order, so created_at is strongly correlated
-- with physical position. A BRIN index keeps one tiny summary per block range
-- (KBs instead of MBs) and lets range scans skip the blocks outside October.
CREATE INDEX idx_txn_created_brin ON pos_transaction USING brin (created_at);

-- Q9: partition by customer, ordered by time, cash-outs only -> partial composite index
CREATE INDEX idx_txn_cashout_cust_time ON pos_transaction (customer_id, created_at)
    WHERE type_code = 'CASH_OUT' AND customer_id IS NOT NULL;

ANALYZE pos_transaction;
ANALYZE ledger_entry;
