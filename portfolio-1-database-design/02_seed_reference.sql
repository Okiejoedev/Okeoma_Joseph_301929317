-- Portfolio 1: reference data for AgentLink Lagos (simulated)
SET search_path TO agentlink;

-- The 20 Local Government Areas of Lagos State
INSERT INTO lga (lga_code, lga_name) VALUES
 ('AGE','Agege'), ('AJE','Ajeromi-Ifelodun'), ('ALI','Alimosho'), ('AMU','Amuwo-Odofin'),
 ('APA','Apapa'), ('BAD','Badagry'), ('EPE','Epe'), ('ETI','Eti-Osa'),
 ('IBL','Ibeju-Lekki'), ('IFA','Ifako-Ijaiye'), ('IKJ','Ikeja'), ('IKD','Ikorodu'),
 ('KOS','Kosofe'), ('LIS','Lagos Island'), ('LMA','Lagos Mainland'), ('MUS','Mushin'),
 ('OJO','Ojo'), ('OSH','Oshodi-Isolo'), ('SHO','Shomolu'), ('SUR','Surulere');

INSERT INTO txn_type (type_code, description, moves_cash) VALUES
 ('CASH_OUT', 'Customer withdraws cash from agent (card or wallet debit)', TRUE),
 ('CASH_IN',  'Customer deposits cash with agent into wallet/account',     TRUE),
 ('TRANSFER', 'Agent sends funds to a bank account on customer''s behalf', FALSE),
 ('BILL_PAY', 'Electricity / cable TV bill payment',                       FALSE),
 ('AIRTIME',  'Airtime or data top-up',                                    FALSE),
 ('REVERSAL', 'Compensating entry that reverses a failed/disputed txn',     FALSE);

-- Fictional fee schedule (illustrative; not a real operator's tariff)
INSERT INTO fee_band (type_code, min_amount, max_amount, flat_fee, pct_fee) VALUES
 ('CASH_OUT',     0.00,     5000.00, 100, 0),
 ('CASH_OUT',  5000.00,    10000.00, 200, 0),
 ('CASH_OUT', 10000.00,    20000.00, 300, 0),
 ('CASH_OUT', 20000.00, 10000000.00,   0, 0.0150),
 ('TRANSFER',     0.00,     5000.00,  50, 0),
 ('TRANSFER',  5000.00,    50000.00, 100, 0),
 ('TRANSFER', 50000.00, 10000000.00, 150, 0),
 ('BILL_PAY',     0.00, 10000000.00, 100, 0);
-- CASH_IN, AIRTIME and REVERSAL have no fee band -> fee = 0

INSERT INTO super_agent (name, licence_no, commission_share)
SELECT 'Super Agent ' || chr(64 + ((g-1) % 26) + 1) || CASE WHEN g > 26 THEN '2' ELSE '' END || ' Ltd',
       'SA/LAG/' || lpad(g::text, 4, '0'),
       round((0.20 + (g % 5) * 0.05)::numeric, 3)
FROM generate_series(1, 30) g;

-- Internal system wallets
INSERT INTO wallet (owner_type, system_code) VALUES
 ('SYSTEM','FEE_INCOME'), ('SYSTEM','SETTLEMENT');

-- Helper: fee for a given type and amount
CREATE OR REPLACE FUNCTION calc_fee(p_type VARCHAR, p_amount NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT round(flat_fee + pct_fee * p_amount, 2)
           FROM fee_band
          WHERE type_code = p_type
            AND p_amount >= min_amount AND p_amount < max_amount), 0);
$$;
