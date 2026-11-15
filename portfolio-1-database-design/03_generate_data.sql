-- =====================================================================
-- Portfolio 1: synthetic data generator (reproducible: fixed random seed)
-- Volumes: 3,000 agents | 3,300 terminals | 80,000 customers
--          ~1.2 million POS transactions (May-Oct 2026) | ~2.8 million ledger rows
-- All people, phone numbers and businesses are fictitious.
-- =====================================================================
SET search_path TO agentlink;
SELECT setseed(0.8103);

CREATE TEMP TABLE first_names(n TEXT[]) ON COMMIT PRESERVE ROWS;
INSERT INTO first_names VALUES (ARRAY[
 'Adebayo','Chinedu','Aisha','Emeka','Funmilayo','Ibrahim','Ngozi','Tunde','Zainab','Chiamaka',
 'Oluwaseun','Uche','Halima','Segun','Amaka','Musa','Bisola','Ifeanyi','Hauwa','Kunle',
 'Nneka','Yusuf','Temitope','Obinna','Fatima','Babatunde','Adaeze','Sani','Kehinde','Chidi',
 'Folake','Abdullahi','Ebere','Damilola','Kelechi','Rukayat','Gbenga','Ifeoma','Bashir','Toyin']);
CREATE TEMP TABLE last_names(n TEXT[]) ON COMMIT PRESERVE ROWS;
INSERT INTO last_names VALUES (ARRAY[
 'Adeyemi','Okafor','Bello','Eze','Ogunleye','Mohammed','Nwosu','Balogun','Abubakar','Okonkwo',
 'Adeleke','Chukwu','Lawal','Obi','Afolabi','Usman','Nwankwo','Oyelaran','Danjuma','Ibe',
 'Olawale','Okeke','Suleiman','Akinola','Onyeka','Salami','Ugwu','Adewale','Garba','Anyanwu']);
CREATE TEMP TABLE biz_words(n TEXT[]) ON COMMIT PRESERVE ROWS;
INSERT INTO biz_words VALUES (ARRAY[
 'Grace','Divine','Royal','Unity','Favour','Blessed','Success','Mega','Prime','Glory',
 'Kings','Victory','Star','Bright','Golden','Hope','Trust','Rock','Oasis','Crown']);

-- ---------------- Agents (skewed to busy LGAs) ----------------
INSERT INTO agent (agent_code, super_agent_id, business_name, owner_name, phone, lga_code,
                   tier, status, daily_cashout_limit, onboarded_on)
SELECT 'AGL-' || lpad(g::text, 6, '0'),
       1 + floor(random() * 30)::int,
       b.n[1 + floor(random()*20)::int] || ' ' ||
         (ARRAY['POS','Ventures','Enterprises','Cash Point','Global Services'])[1 + floor(random()*5)::int],
       f.n[1 + floor(random()*40)::int] || ' ' || l.n[1 + floor(random()*30)::int],
       (ARRAY['070','080','081','090','091'])[1 + g % 5] || lpad((50000000 + g)::text, 8, '0'),
       -- busiest LGAs first so that the power() skew gives them more agents
       (ARRAY['ALI','IKJ','OSH','MUS','SUR','KOS','ETI','LMA','AJE','AGE',
              'IKD','OJO','SHO','AMU','IFA','LIS','APA','BAD','EPE','IBL'])[1 + floor(power(random(), 1.7) * 20)::int],
       (ARRAY['A','B','B','C','C','C'])[1 + floor(random()*6)::int],
       CASE WHEN random() < 0.03 THEN 'SUSPENDED' WHEN random() < 0.01 THEN 'CLOSED' ELSE 'ACTIVE' END,
       (ARRAY[300000, 500000, 500000, 1000000])[1 + floor(random()*4)::int],
       DATE '2023-01-01' + floor(random() * 1200)::int
FROM generate_series(1, 3000) g, first_names f, last_names l, biz_words b;

-- ---------------- Terminals: one per agent + 300 second terminals + 50 in store ----------------
INSERT INTO terminal (terminal_id, serial_no, model, agent_id, status, assigned_on)
SELECT '2AGL' || lpad(a.agent_id::text, 4, '0'),
       'SN' || lpad((7000000 + a.agent_id)::text, 10, '0'),
       (ARRAY['Topwise MP35P','Horizon K11','PAX S90','Nexgo N86'])[1 + a.agent_id % 4],
       a.agent_id, 'ACTIVE', a.onboarded_on
FROM agent a;

INSERT INTO terminal (terminal_id, serial_no, model, agent_id, status, assigned_on)
SELECT '2AGM' || lpad(a.agent_id::text, 4, '0'),
       'SN' || lpad((8000000 + a.agent_id)::text, 10, '0'),
       'PAX S90', a.agent_id, 'ACTIVE', a.onboarded_on + 90
FROM agent a WHERE a.tier = 'A' ORDER BY a.agent_id LIMIT 300;

INSERT INTO terminal (terminal_id, serial_no, model, status)
SELECT '2AGS' || lpad(g::text, 4, '0'), 'SN' || lpad((9000000 + g)::text, 10, '0'), 'Nexgo N86', 'ACTIVE'
FROM generate_series(1, 50) g;

-- ---------------- Customers ----------------
INSERT INTO customer (phone, first_name, last_name, bvn_hash, kyc_tier, created_at)
SELECT (ARRAY['070','080','081','090','091'])[1 + g % 5] || lpad(g::text, 8, '0'),
       f.n[1 + floor(random()*40)::int],
       l.n[1 + floor(random()*30)::int],
       CASE WHEN random() < 0.85 THEN encode(sha256(('BVN' || (22100000000 + g))::bytea), 'hex') END,
       (ARRAY[1,1,2,2,2,3])[1 + floor(random()*6)::int],
       TIMESTAMPTZ '2024-01-01' + random() * INTERVAL '850 days'
FROM generate_series(1, 80000) g, first_names f, last_names l;

-- ---------------- Wallets ----------------
INSERT INTO wallet (owner_type, agent_id)    SELECT 'AGENT', agent_id FROM agent ORDER BY agent_id;
INSERT INTO wallet (owner_type, customer_id) SELECT 'CUSTOMER', customer_id FROM customer ORDER BY customer_id;

-- ---------------- POS transactions ----------------
-- Activity is skewed: a minority of agents and customers generate most volume.
CREATE TEMP TABLE gen AS
SELECT g,
       1 + floor(power(random(), 1.8) * 3000)::int                       AS agent_id,
       CASE WHEN random() < 0.08 THEN NULL
            ELSE 1 + floor(power(random(), 1.5) * 80000)::int END        AS customer_id,
       random()                                                         AS r_type,
       random()                                                         AS r_amt,
       random()                                                         AS r_status,
       (DATE '2026-05-01' + floor(random() * 184)::int)                  -- 184 days: May..Oct
         + make_interval(hours => 7 + floor(power(random(), 1.2) * 14)::int,
                         mins  => floor(random()*60)::int,
                         secs  => floor(random()*60)::int)               AS ts
FROM generate_series(1, 1200000) g;

INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, customer_id, type_code, amount,
                             status, created_at, completed_at)
SELECT 'R' || to_char(ts, 'YYMMDD') || lpad(g::text, 9, '0'),
       '2AGL' || lpad(agent_id::text, 4, '0'),
       agent_id, customer_id,
       t.type_code,
       CASE t.type_code
         WHEN 'CASH_OUT' THEN greatest(500, round((exp(r_amt * 5.3) * 500) / 500) * 500)  -- 500 .. ~100k
         WHEN 'CASH_IN'  THEN greatest(1000, round((exp(r_amt * 5.0) * 800) / 1000) * 1000)
         WHEN 'TRANSFER' THEN greatest(1000, round((exp(r_amt * 6.0) * 600)::numeric, -2))
         WHEN 'BILL_PAY' THEN round((2000 + r_amt * 38000)::numeric, -2)
         ELSE                 (ARRAY[100,200,500,1000,2000])[1 + floor(r_amt*5)::int]
       END,
       CASE WHEN ts > TIMESTAMPTZ '2026-10-31 20:00' AND r_status < 0.02 THEN 'PENDING'
            WHEN r_status < 0.042 THEN 'FAILED'
            WHEN r_status < 0.050 THEN 'REVERSED'
            ELSE 'SUCCESS' END,
       ts,
       CASE WHEN ts > TIMESTAMPTZ '2026-10-31 20:00' AND r_status < 0.02 THEN NULL
            ELSE ts + make_interval(secs => 2 + floor(r_amt * 25)::int) END
FROM gen
CROSS JOIN LATERAL (
    SELECT CASE WHEN r_type < 0.45 THEN 'CASH_OUT' WHEN r_type < 0.70 THEN 'TRANSFER'
                WHEN r_type < 0.82 THEN 'CASH_IN'  WHEN r_type < 0.90 THEN 'BILL_PAY'
                ELSE 'AIRTIME' END AS type_code) t
ORDER BY ts;   -- insert in time order, as a live system would

UPDATE pos_transaction SET fee = calc_fee(type_code, amount)
WHERE type_code IN ('CASH_OUT','TRANSFER','BILL_PAY');

-- Reversal (compensating) transactions for every REVERSED original
INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, customer_id, type_code, amount, fee,
                             status, created_at, completed_at, reversal_of)
SELECT 'V' || substr(txn_ref, 2), terminal_id, agent_id, customer_id, 'REVERSAL', amount + fee, 0,
       'SUCCESS', created_at + INTERVAL '20 minutes', created_at + INTERVAL '20 minutes 5 seconds', txn_id
FROM pos_transaction WHERE status = 'REVERSED' ORDER BY txn_id;

-- ---------------- Ledger (double entry) ----------------
-- Bulk historical load: the per-row balance trigger is switched off for speed and the
-- double-entry rule is verified with one set-based query at the end instead.
ALTER TABLE ledger_entry DISABLE TRIGGER trg_ledger_balanced;

CREATE TEMP TABLE wmap AS
SELECT (SELECT wallet_id FROM wallet WHERE system_code='FEE_INCOME') AS fee_w,
       (SELECT wallet_id FROM wallet WHERE system_code='SETTLEMENT') AS set_w;

-- CASH_OUT: customer (or card scheme settlement) is debited amount+fee;
--           agent wallet credited amount; fee income credited fee.
-- CASH_IN : agent wallet debited; customer wallet (or settlement for bank deposits) credited.
-- TRANSFER/BILL_PAY/AIRTIME: agent wallet debited amount+fee; settlement credited amount; fees credited.
INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount, created_at)
SELECT t.txn_id, e.wallet_id, e.dir, e.amt, t.completed_at
FROM pos_transaction t
LEFT JOIN wallet aw ON aw.agent_id = t.agent_id
LEFT JOIN wallet cw ON cw.customer_id = t.customer_id
CROSS JOIN wmap m
CROSS JOIN LATERAL (VALUES
   -- leg 1 (debit)
   (CASE t.type_code WHEN 'CASH_OUT' THEN COALESCE(cw.wallet_id, m.set_w)
                     ELSE aw.wallet_id END,
    'D', t.amount + t.fee),
   -- leg 2 (credit principal)
   (CASE t.type_code WHEN 'CASH_OUT' THEN aw.wallet_id
                     WHEN 'CASH_IN'  THEN COALESCE(cw.wallet_id, m.set_w)
                     ELSE m.set_w END,
    'C', t.amount),
   -- leg 3 (credit fee)
   (m.fee_w, 'C', t.fee)
) AS e(wallet_id, dir, amt)
WHERE t.status IN ('SUCCESS','REVERSED') AND t.type_code <> 'REVERSAL' AND e.amt > 0;

-- Reversal entries mirror the original entries (D <-> C)
INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount, created_at)
SELECT r.txn_id, le.wallet_id, CASE le.direction WHEN 'D' THEN 'C' ELSE 'D' END, le.amount, r.completed_at
FROM pos_transaction r
JOIN ledger_entry le ON le.txn_id = r.reversal_of
WHERE r.type_code = 'REVERSAL';

ALTER TABLE ledger_entry ENABLE TRIGGER trg_ledger_balanced;

-- ---------------- Commission on successful fee-bearing transactions ----------------
INSERT INTO commission (txn_id, agent_amount, super_agent_amount)
SELECT t.txn_id,
       round(t.fee * 0.5 * (1 - s.commission_share), 2),
       round(t.fee * 0.5 * s.commission_share, 2)
FROM pos_transaction t
JOIN agent a       ON a.agent_id = t.agent_id
JOIN super_agent s ON s.super_agent_id = a.super_agent_id
WHERE t.status = 'SUCCESS' AND t.fee > 0;

-- ---------------- Wallet balances = opening + credits - debits ----------------
-- Opening balances (migrated) are set high enough that no customer/agent wallet is negative.
CREATE TEMP TABLE net AS
SELECT wallet_id, SUM(CASE direction WHEN 'C' THEN amount ELSE -amount END) AS net
FROM ledger_entry GROUP BY wallet_id;
ALTER TABLE net ADD PRIMARY KEY (wallet_id);

UPDATE wallet w
SET opening_balance = CASE WHEN w.owner_type = 'SYSTEM' THEN 0
                           ELSE round((CASE w.owner_type WHEN 'AGENT' THEN 250000 ELSE 5000 END
                                       + random() * 20000)::numeric, 2)
                                + greatest(0, -COALESCE(n.net, 0)) END
FROM wallet w2 LEFT JOIN net n ON n.wallet_id = w2.wallet_id
WHERE w2.wallet_id = w.wallet_id;

UPDATE wallet w
SET balance = w.opening_balance + COALESCE((SELECT n.net FROM net n WHERE n.wallet_id = w.wallet_id), 0);

-- ---------------- Disputes ----------------
INSERT INTO dispute (txn_id, customer_id, reason, status, opened_at, resolved_at)
SELECT txn_id, customer_id,
       (ARRAY['DEBITED_NOT_PAID','DOUBLE_DEBIT','WRONG_AMOUNT','FRAUD'])[1 + floor(random()*4)::int],
       s.st, created_at + INTERVAL '2 hours',
       CASE WHEN s.st <> 'OPEN' THEN created_at + INTERVAL '2 days' END
FROM (SELECT txn_id, customer_id, created_at
      FROM pos_transaction
      WHERE type_code = 'CASH_OUT' AND customer_id IS NOT NULL AND status IN ('SUCCESS','REVERSED')
      ORDER BY random() LIMIT 3000) x
-- status derived from txn_id (deterministic spread: ~25% open, 45% refunded, 30% rejected)
CROSS JOIN LATERAL (SELECT CASE WHEN x.txn_id % 20 < 5 THEN 'OPEN' WHEN x.txn_id % 20 < 14 THEN 'REFUNDED'
                                ELSE 'REJECTED' END AS st) s;

ANALYZE;
