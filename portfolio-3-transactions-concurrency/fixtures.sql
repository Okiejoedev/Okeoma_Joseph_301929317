-- =====================================================================
-- Portfolio 3: demo fixtures (idempotent). Creates/reset a demo agent,
-- terminal and two demo customers with known balances so that every demo
-- starts from the same state.  Run before each demo scenario.
-- =====================================================================
BEGIN;
SET LOCAL search_path TO agentlink;

INSERT INTO agent (agent_code, super_agent_id, business_name, owner_name, phone, lga_code,
                   tier, daily_cashout_limit, onboarded_on)
VALUES ('AGL-DEMO01', 1, 'Okiejoe Demo POS', 'Demo Agent', '09099990001', 'IKJ', 'B', 100000, '2026-01-01')
ON CONFLICT (agent_code) DO NOTHING;

INSERT INTO terminal (terminal_id, serial_no, model, agent_id, status, assigned_on)
SELECT '2AGD0001', 'SNDEMO000001', 'PAX S90', agent_id, 'ACTIVE', '2026-01-01'
FROM agent WHERE agent_code = 'AGL-DEMO01'
ON CONFLICT (terminal_id) DO NOTHING;

INSERT INTO customer (phone, first_name, last_name, kyc_tier) VALUES
 ('08099990001', 'Ada',  'Demo', 2),
 ('08099990002', 'Bayo', 'Demo', 2)
ON CONFLICT (phone) DO NOTHING;

INSERT INTO wallet (owner_type, agent_id)
SELECT 'AGENT', agent_id FROM agent WHERE agent_code = 'AGL-DEMO01'
ON CONFLICT (agent_id) DO NOTHING;
INSERT INTO wallet (owner_type, customer_id)
SELECT 'CUSTOMER', customer_id FROM customer WHERE phone IN ('08099990001','08099990002')
ON CONFLICT (customer_id) DO NOTHING;

-- Remove everything previous demo runs created (all of it went through terminal 2AGD0001)
CREATE TEMP TABLE demo_txn ON COMMIT DROP AS
SELECT txn_id FROM pos_transaction WHERE terminal_id = '2AGD0001';
DELETE FROM commission   WHERE txn_id IN (SELECT txn_id FROM demo_txn);
DELETE FROM dispute      WHERE txn_id IN (SELECT txn_id FROM demo_txn);
DELETE FROM ledger_entry WHERE txn_id IN (SELECT txn_id FROM demo_txn);
DELETE FROM pos_transaction WHERE reversal_of IN (SELECT txn_id FROM demo_txn);
DELETE FROM pos_transaction WHERE txn_id IN (SELECT txn_id FROM demo_txn);

-- Known starting balances (opening = balance because demo wallets now have no ledger rows)
UPDATE wallet SET opening_balance = 50000,  balance = 50000,  version = 0
 WHERE customer_id = (SELECT customer_id FROM customer WHERE phone = '08099990001');
UPDATE wallet SET opening_balance = 20000,  balance = 20000,  version = 0
 WHERE customer_id = (SELECT customer_id FROM customer WHERE phone = '08099990002');
UPDATE wallet SET opening_balance = 300000, balance = 300000, version = 0
 WHERE agent_id = (SELECT agent_id FROM agent WHERE agent_code = 'AGL-DEMO01');

-- System fee wallet: recompute from its ledger so reconciliation still holds
UPDATE wallet w SET balance = w.opening_balance + COALESCE(
    (SELECT SUM(CASE direction WHEN 'C' THEN amount ELSE -amount END)
       FROM ledger_entry le WHERE le.wallet_id = w.wallet_id), 0)
 WHERE system_code = 'FEE_INCOME';
COMMIT;
