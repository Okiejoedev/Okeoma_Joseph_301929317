-- =====================================================================
-- Portfolio 3: transactional business logic for AgentLink Lagos
--   cash_out()   - customer withdraws cash at an agent's POS
--   reverse_txn()- compensating transaction for a debited-but-not-paid txn
--   wallet_transfer() - wallet-to-wallet transfer with ordered locking
-- These are FUNCTIONS: they run inside the caller's transaction, so the caller
-- decides COMMIT or ROLLBACK, and any RAISE aborts everything the function did.
-- =====================================================================
SET search_path TO agentlink;

CREATE OR REPLACE FUNCTION cash_out(p_ref VARCHAR, p_terminal VARCHAR,
                                    p_customer INT, p_amount NUMERIC)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_agent   agent%ROWTYPE;
    v_fee     NUMERIC := calc_fee('CASH_OUT', p_amount);
    v_cw      wallet%ROWTYPE;     -- customer wallet
    v_aw      wallet%ROWTYPE;     -- agent wallet
    v_today   NUMERIC;
    v_txn     BIGINT;
    v_fee_w   BIGINT := (SELECT wallet_id FROM wallet WHERE system_code = 'FEE_INCOME');
BEGIN
    SELECT a.* INTO v_agent FROM terminal t JOIN agent a USING (agent_id)
     WHERE t.terminal_id = p_terminal AND t.status = 'ACTIVE';
    IF NOT FOUND OR v_agent.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Terminal % is not assigned to an active agent', p_terminal;
    END IF;

    -- Lock both wallets in a FIXED ORDER (lowest wallet_id first) to avoid deadlocks.
    -- The agent wallet lock also serialises concurrent cash-outs at the same agent,
    -- which makes the daily-limit check below safe from write skew.
    PERFORM 1 FROM wallet
     WHERE customer_id = p_customer OR agent_id = v_agent.agent_id
     ORDER BY wallet_id FOR UPDATE;
    SELECT * INTO v_cw FROM wallet WHERE customer_id = p_customer;
    SELECT * INTO v_aw FROM wallet WHERE agent_id   = v_agent.agent_id;

    SELECT COALESCE(SUM(amount), 0) INTO v_today FROM pos_transaction
     WHERE agent_id = v_agent.agent_id AND type_code = 'CASH_OUT' AND status = 'SUCCESS'
       AND created_at >= date_trunc('day', now());
    IF v_today + p_amount > v_agent.daily_cashout_limit THEN
        RAISE EXCEPTION 'Agent % daily cash-out limit exceeded (used %, limit %)',
              v_agent.agent_code, v_today, v_agent.daily_cashout_limit;
    END IF;

    IF v_cw.balance < p_amount + v_fee THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, needed %', v_cw.balance, p_amount + v_fee;
    END IF;

    INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, customer_id, type_code,
                                 amount, fee, status, completed_at)
    VALUES (p_ref, p_terminal, v_agent.agent_id, p_customer, 'CASH_OUT',
            p_amount, v_fee, 'SUCCESS', clock_timestamp())
    RETURNING txn_id INTO v_txn;

    INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount) VALUES
        (v_txn, v_cw.wallet_id, 'D', p_amount + v_fee),
        (v_txn, v_aw.wallet_id, 'C', p_amount);
    IF v_fee > 0 THEN
        INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount) VALUES (v_txn, v_fee_w, 'C', v_fee);
        UPDATE wallet SET balance = balance + v_fee WHERE wallet_id = v_fee_w;
    END IF;

    UPDATE wallet SET balance = balance - (p_amount + v_fee), version = version + 1
     WHERE wallet_id = v_cw.wallet_id;
    UPDATE wallet SET balance = balance + p_amount, version = version + 1
     WHERE wallet_id = v_aw.wallet_id;
    RETURN v_txn;
END $$;


CREATE OR REPLACE FUNCTION reverse_txn(p_txn BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_orig pos_transaction%ROWTYPE;
    v_rev  BIGINT;
BEGIN
    -- Lock the original row: two support officers cannot reverse it at the same time
    SELECT * INTO v_orig FROM pos_transaction WHERE txn_id = p_txn FOR UPDATE;
    IF v_orig.status <> 'SUCCESS' THEN
        RAISE EXCEPTION 'Txn % cannot be reversed (status %)', p_txn, v_orig.status;
    END IF;

    PERFORM 1 FROM wallet WHERE wallet_id IN (SELECT wallet_id FROM ledger_entry WHERE txn_id = p_txn)
     ORDER BY wallet_id FOR UPDATE;

    UPDATE pos_transaction SET status = 'REVERSED' WHERE txn_id = p_txn;
    INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, customer_id, type_code, amount,
                                 status, completed_at, reversal_of)
    VALUES ('V' || substr(v_orig.txn_ref, 2), v_orig.terminal_id, v_orig.agent_id, v_orig.customer_id,
            'REVERSAL', v_orig.amount + v_orig.fee, 'SUCCESS', clock_timestamp(), p_txn)
    RETURNING txn_id INTO v_rev;

    INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount)
    SELECT v_rev, wallet_id, CASE direction WHEN 'D' THEN 'C' ELSE 'D' END, amount
      FROM ledger_entry WHERE txn_id = p_txn;

    UPDATE wallet w SET balance = w.balance + x.delta, version = w.version + 1
      FROM (SELECT wallet_id, SUM(CASE direction WHEN 'D' THEN amount ELSE -amount END) AS delta
              FROM ledger_entry WHERE txn_id = p_txn GROUP BY wallet_id) x
     WHERE w.wallet_id = x.wallet_id;
    RETURN v_rev;
END $$;


-- Wallet-to-wallet transfer. p_ordered = FALSE deliberately locks in argument order
-- (source first) so that the deadlock demo can reproduce the bug.
CREATE OR REPLACE FUNCTION wallet_transfer(p_ref VARCHAR, p_from BIGINT, p_to BIGINT,
                                           p_amount NUMERIC, p_ordered BOOLEAN DEFAULT TRUE,
                                           p_pause NUMERIC DEFAULT 0)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_txn BIGINT; v_bal NUMERIC;
BEGIN
    IF p_ordered THEN
        PERFORM 1 FROM wallet WHERE wallet_id IN (p_from, p_to) ORDER BY wallet_id FOR UPDATE;
    ELSE
        PERFORM 1 FROM wallet WHERE wallet_id = p_from FOR UPDATE;
        PERFORM pg_sleep(p_pause);                       -- widen the race window for the demo
        PERFORM 1 FROM wallet WHERE wallet_id = p_to   FOR UPDATE;
    END IF;
    SELECT balance INTO v_bal FROM wallet WHERE wallet_id = p_from;
    IF v_bal < p_amount THEN RAISE EXCEPTION 'Insufficient funds in wallet %', p_from; END IF;

    INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, type_code, amount, status, completed_at)
    VALUES (p_ref, '2AGD0001', (SELECT agent_id FROM terminal WHERE terminal_id = '2AGD0001'),
            'TRANSFER', p_amount, 'SUCCESS', clock_timestamp())
    RETURNING txn_id INTO v_txn;
    INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount)
    VALUES (v_txn, p_from, 'D', p_amount), (v_txn, p_to, 'C', p_amount);
    UPDATE wallet SET balance = balance - p_amount, version = version + 1 WHERE wallet_id = p_from;
    UPDATE wallet SET balance = balance + p_amount, version = version + 1 WHERE wallet_id = p_to;
    RETURN v_txn;
END $$;
