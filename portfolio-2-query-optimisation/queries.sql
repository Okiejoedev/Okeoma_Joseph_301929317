-- =====================================================================
-- Portfolio 2: business queries for AgentLink Lagos
-- Each query is preceded by a marker line "-- @Qn | title" (used by benchmark.py)
-- =====================================================================
SET search_path TO agentlink;

-- @Q1 | Customer mini-statement: last 20 transactions of one customer (wallet app)
SELECT t.txn_ref, t.created_at, t.type_code, t.amount, t.fee, t.status, a.business_name
FROM pos_transaction t
JOIN agent a ON a.agent_id = t.agent_id
WHERE t.customer_id = 1234
ORDER BY t.created_at DESC
LIMIT 20;

-- @Q2 | Agent end-of-day summary for one agent and one day (POS terminal report)
SELECT type_code, status, count(*) AS txns, sum(amount) AS volume, sum(fee) AS fees
FROM pos_transaction
WHERE agent_id = 57
  AND created_at >= '2026-10-15' AND created_at < '2026-10-16'
GROUP BY type_code, status
ORDER BY type_code, status;

-- @Q3 | Daily cash-out limit check (runs before EVERY cash-out is approved)
SELECT COALESCE(sum(amount), 0) AS cashed_out_today
FROM pos_transaction
WHERE agent_id = 57 AND type_code = 'CASH_OUT' AND status = 'SUCCESS'
  AND created_at >= '2026-10-15' AND created_at < '2026-10-16';

-- @Q4 | Operations queue: failed transactions in the last 3 days not yet reversed
SELECT t.txn_id, t.txn_ref, t.agent_id, t.amount, t.created_at
FROM pos_transaction t
WHERE t.status = 'FAILED'
  AND t.created_at >= '2026-10-29'
ORDER BY t.created_at;

-- @Q5 | Wallet statement: all ledger postings to one agent wallet in October
SELECT le.created_at, le.direction, le.amount, t.txn_ref, t.type_code
FROM ledger_entry le
JOIN pos_transaction t ON t.txn_id = le.txn_id
WHERE le.wallet_id = 59
  AND le.created_at >= '2026-10-01' AND le.created_at < '2026-11-01'
ORDER BY le.created_at;

-- @Q6 | Dispute investigation: open disputes with their ledger postings
SELECT d.dispute_id, d.reason, t.txn_ref, t.amount, le.wallet_id, le.direction, le.amount AS posted
FROM dispute d
JOIN pos_transaction t ON t.txn_id = d.txn_id
JOIN ledger_entry le   ON le.txn_id = t.txn_id
WHERE d.status = 'OPEN'
ORDER BY d.opened_at;

-- @Q7 | Management report: October successful volume by LGA (large range scan)
SELECT l.lga_name, count(*) AS txns, sum(t.amount) AS volume
FROM pos_transaction t
JOIN agent a ON a.agent_id = t.agent_id
JOIN lga l   ON l.lga_code = a.lga_code
WHERE t.status = 'SUCCESS'
  AND t.created_at >= '2026-10-01' AND t.created_at < '2026-11-01'
GROUP BY l.lga_name
ORDER BY volume DESC;

-- @Q8 | Top 10 agents by October commission, ranked with a window function
SELECT * FROM (
    SELECT a.agent_code, a.business_name, sum(c.agent_amount) AS commission,
           RANK() OVER (ORDER BY sum(c.agent_amount) DESC) AS rnk
    FROM commission c
    JOIN pos_transaction t ON t.txn_id = c.txn_id
    JOIN agent a           ON a.agent_id = t.agent_id
    WHERE t.created_at >= '2026-10-01' AND t.created_at < '2026-11-01'
    GROUP BY a.agent_code, a.business_name
) r WHERE rnk <= 10;

-- @Q9 | Fraud signal: customers with 3+ cash-outs within 10 minutes (window function LAG)
SELECT customer_id, created_at, prev2
FROM (
    SELECT customer_id, created_at,
           LAG(created_at, 2) OVER (PARTITION BY customer_id ORDER BY created_at) AS prev2
    FROM pos_transaction
    WHERE type_code = 'CASH_OUT' AND customer_id IS NOT NULL
      AND created_at >= '2026-10-01'
) w
WHERE created_at - prev2 <= INTERVAL '10 minutes';
