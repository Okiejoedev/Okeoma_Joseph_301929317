-- Portfolio 1: each statement below SHOULD FAIL, proving the constraint works.
-- Run with: psql -d agentlink -f 04_constraint_tests.sql   (no ON_ERROR_STOP)
SET search_path TO agentlink;
\set VERBOSITY terse

\echo '[1] Invalid Nigerian phone number on a customer (CHECK)'
INSERT INTO customer (phone, first_name, last_name) VALUES ('12345', 'Test', 'User');

\echo '[2] Duplicate retrieval reference number - POS retry must not double-post (UNIQUE)'
INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, type_code, amount)
SELECT txn_ref, terminal_id, agent_id, type_code, amount FROM pos_transaction WHERE txn_id = 1;

\echo '[3] Customer wallet overdraft (CHECK wallet_no_overdraft)'
UPDATE wallet SET balance = -1 WHERE customer_id = 1;

\echo '[4] Wallet with two owners (CHECK wallet_one_owner)'
INSERT INTO wallet (owner_type, agent_id, customer_id) VALUES ('AGENT', 1, 1);

\echo '[5] Transaction on a terminal that does not exist (FOREIGN KEY)'
INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, type_code, amount)
VALUES ('RTEST000000001', 'XXXX9999', 1, 'CASH_OUT', 5000);

\echo '[6] Zero / negative amount (CHECK amount > 0)'
INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, type_code, amount)
VALUES ('RTEST000000002', '2AGL0001', 1, 'CASH_OUT', 0);

\echo '[7] Reversing the same transaction twice (UNIQUE reversal_of)'
INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, type_code, amount, status, reversal_of)
SELECT 'VTEST000000003', terminal_id, agent_id, 'REVERSAL', amount, 'SUCCESS', reversal_of
FROM pos_transaction WHERE type_code = 'REVERSAL' LIMIT 1;

\echo '[8] Unbalanced double entry - debit without matching credit (DEFERRED constraint trigger at COMMIT)'
BEGIN;
INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, customer_id, type_code, amount, status)
VALUES ('RTEST000000004', '2AGL0001', 1, 1, 'CASH_OUT', 5000, 'SUCCESS');
INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount)
VALUES (currval(pg_get_serial_sequence('pos_transaction','txn_id')),
        (SELECT wallet_id FROM wallet WHERE customer_id = 1), 'D', 5000);
\echo '    (insert accepted for now - checked at COMMIT)'
COMMIT;

\echo '[9] Resolved dispute without a resolution time (CHECK)'
INSERT INTO dispute (txn_id, customer_id, reason, status) VALUES (1, 1, 'DOUBLE_DEBIT', 'REFUNDED');

\echo '[10] Unknown transaction type (FOREIGN KEY to txn_type)'
INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, type_code, amount)
VALUES ('RTEST000000005', '2AGL0001', 1, 'LOAN', 5000);

\echo '--- Confirm nothing leaked in:'
SELECT count(*) AS test_rows FROM pos_transaction WHERE txn_ref LIKE '_TEST%';
