-- Portfolio 1: integrity checks on the generated data
SET search_path TO agentlink;
\echo '--- Row counts'
SELECT 'lga' t, count(*) FROM lga UNION ALL SELECT 'super_agent', count(*) FROM super_agent
UNION ALL SELECT 'agent', count(*) FROM agent UNION ALL SELECT 'terminal', count(*) FROM terminal
UNION ALL SELECT 'customer', count(*) FROM customer UNION ALL SELECT 'wallet', count(*) FROM wallet
UNION ALL SELECT 'pos_transaction', count(*) FROM pos_transaction
UNION ALL SELECT 'ledger_entry', count(*) FROM ledger_entry
UNION ALL SELECT 'commission', count(*) FROM commission UNION ALL SELECT 'dispute', count(*) FROM dispute;

\echo '--- Transactions by type and status'
SELECT type_code, status, count(*), round(avg(amount),2) AS avg_amount
FROM pos_transaction GROUP BY 1,2 ORDER BY 1,2;

\echo '--- Double-entry check: transactions whose debits <> credits (expect 0)'
SELECT count(*) AS unbalanced_txns FROM (
  SELECT txn_id FROM ledger_entry GROUP BY txn_id
  HAVING SUM(amount) FILTER (WHERE direction='D') IS DISTINCT FROM SUM(amount) FILTER (WHERE direction='C')) x;

\echo '--- Wallet reconciliation: balance = opening + credits - debits (expect 0 mismatches)'
SELECT count(*) AS mismatched_wallets FROM wallet w
LEFT JOIN (SELECT wallet_id, SUM(CASE direction WHEN 'C' THEN amount ELSE -amount END) net
           FROM ledger_entry GROUP BY wallet_id) n USING (wallet_id)
WHERE w.balance <> w.opening_balance + COALESCE(n.net,0);

\echo '--- Whole system nets to zero movement (sum of all balances - openings = 0)'
SELECT SUM(balance) - SUM(opening_balance) AS net_movement FROM wallet;

\echo '--- Agents per LGA (top 5)'
SELECT l.lga_name, count(*) agents FROM agent a JOIN lga l USING (lga_code)
GROUP BY 1 ORDER BY 2 DESC LIMIT 5;
