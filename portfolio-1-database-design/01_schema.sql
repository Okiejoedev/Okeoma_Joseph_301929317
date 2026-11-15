-- =====================================================================
-- AgentLink Lagos (simulated) - POS Agent Banking Network
-- Portfolio 1: Relational schema (PostgreSQL 16)
-- Author: Joseph Okeoma | MIT 8103 Advanced Database Systems
-- =====================================================================
-- Design notes
--  * Money is stored as NUMERIC(14,2) (exact decimal), never FLOAT.
--  * Every table has a surrogate or natural PRIMARY KEY; business identifiers
--    (agent_code, txn_ref, phone, serial_no) are protected with UNIQUE.
--  * Only PK / UNIQUE indexes exist at this stage. Secondary indexes are
--    added deliberately in Portfolio 2 so that their effect can be measured.
-- =====================================================================

DROP SCHEMA IF EXISTS agentlink CASCADE;
CREATE SCHEMA agentlink;
SET search_path TO agentlink;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE lga (
    lga_code   CHAR(3)      PRIMARY KEY,                 -- e.g. 'IKJ'
    lga_name   VARCHAR(40)  NOT NULL UNIQUE,
    state      VARCHAR(20)  NOT NULL DEFAULT 'Lagos'
);

CREATE TABLE txn_type (
    type_code    VARCHAR(10)  PRIMARY KEY,               -- CASH_IN, CASH_OUT ...
    description  VARCHAR(80)  NOT NULL,
    moves_cash   BOOLEAN      NOT NULL                   -- physical cash changes hands?
);

-- Fee bands depend only on (type, amount range) -> separate table (3NF)
CREATE TABLE fee_band (
    band_id     SERIAL        PRIMARY KEY,
    type_code   VARCHAR(10)   NOT NULL REFERENCES txn_type(type_code),
    min_amount  NUMERIC(14,2) NOT NULL CHECK (min_amount >= 0),
    max_amount  NUMERIC(14,2) NOT NULL,
    flat_fee    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (flat_fee >= 0),
    pct_fee     NUMERIC(5,4)  NOT NULL DEFAULT 0 CHECK (pct_fee BETWEEN 0 AND 0.05),
    CHECK (max_amount > min_amount),
    UNIQUE (type_code, min_amount)
);

-- ---------------------------------------------------------------------
-- Network participants
-- ---------------------------------------------------------------------
CREATE TABLE super_agent (
    super_agent_id    SERIAL       PRIMARY KEY,
    name              VARCHAR(80)  NOT NULL UNIQUE,
    licence_no        VARCHAR(20)  NOT NULL UNIQUE,
    commission_share  NUMERIC(4,3) NOT NULL CHECK (commission_share BETWEEN 0 AND 1)
);

CREATE TABLE agent (
    agent_id             SERIAL        PRIMARY KEY,
    agent_code           VARCHAR(10)   NOT NULL UNIQUE,          -- 'AGL-000123'
    super_agent_id       INT           NOT NULL REFERENCES super_agent(super_agent_id),
    business_name        VARCHAR(80)   NOT NULL,
    owner_name           VARCHAR(80)   NOT NULL,
    phone                VARCHAR(11)   NOT NULL UNIQUE
                         CHECK (phone ~ '^0[789][01][0-9]{8}$'),  -- Nigerian mobile format
    lga_code             CHAR(3)       NOT NULL REFERENCES lga(lga_code),
    tier                 CHAR(1)       NOT NULL DEFAULT 'C' CHECK (tier IN ('A','B','C')),
    status               VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE'
                         CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    daily_cashout_limit  NUMERIC(14,2) NOT NULL DEFAULT 500000 CHECK (daily_cashout_limit > 0),
    onboarded_on         DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE terminal (
    terminal_id   VARCHAR(8)   PRIMARY KEY,                  -- '2AGL0001'
    serial_no     VARCHAR(20)  NOT NULL UNIQUE,
    model         VARCHAR(30)  NOT NULL,
    agent_id      INT          REFERENCES agent(agent_id),   -- NULL = in store / unassigned
    status        VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                  CHECK (status IN ('ACTIVE','FAULTY','RETRIEVED')),
    assigned_on   DATE,
    CHECK ((agent_id IS NULL) = (assigned_on IS NULL))
);

CREATE TABLE customer (
    customer_id  SERIAL       PRIMARY KEY,
    phone        VARCHAR(11)  NOT NULL UNIQUE CHECK (phone ~ '^0[789][01][0-9]{8}$'),
    first_name   VARCHAR(40)  NOT NULL,
    last_name    VARCHAR(40)  NOT NULL,
    bvn_hash     CHAR(64)     UNIQUE,          -- SHA-256 of BVN; raw BVN is never stored
    kyc_tier     SMALLINT     NOT NULL DEFAULT 1 CHECK (kyc_tier BETWEEN 1 AND 3),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Wallets and money movement (double-entry)
-- ---------------------------------------------------------------------
CREATE TABLE wallet (
    wallet_id    BIGSERIAL     PRIMARY KEY,
    owner_type   VARCHAR(8)    NOT NULL CHECK (owner_type IN ('AGENT','CUSTOMER','SYSTEM')),
    agent_id     INT           UNIQUE REFERENCES agent(agent_id),
    customer_id  INT           UNIQUE REFERENCES customer(customer_id),
    system_code  VARCHAR(20)   UNIQUE,         -- FEE_INCOME, SETTLEMENT, OPENING
    opening_balance NUMERIC(14,2) NOT NULL DEFAULT 0, -- migrated from legacy system on 2026-05-01
    balance      NUMERIC(14,2) NOT NULL DEFAULT 0,   -- = opening_balance + credits - debits
    version      INT           NOT NULL DEFAULT 0,   -- used for optimistic locking (P3)
    status       VARCHAR(8)    NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN')),
    -- exactly one kind of owner
    CONSTRAINT wallet_one_owner CHECK (
        (owner_type = 'AGENT'    AND agent_id IS NOT NULL AND customer_id IS NULL AND system_code IS NULL) OR
        (owner_type = 'CUSTOMER' AND customer_id IS NOT NULL AND agent_id IS NULL AND system_code IS NULL) OR
        (owner_type = 'SYSTEM'   AND system_code IS NOT NULL AND agent_id IS NULL AND customer_id IS NULL)),
    -- only internal system wallets may go negative
    CONSTRAINT wallet_no_overdraft CHECK (owner_type = 'SYSTEM' OR balance >= 0)
);

CREATE TABLE pos_transaction (
    txn_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_ref       VARCHAR(20)   NOT NULL UNIQUE,    -- retrieval reference no. sent by the POS
    terminal_id   VARCHAR(8)    NOT NULL REFERENCES terminal(terminal_id),
    agent_id      INT           NOT NULL REFERENCES agent(agent_id),  -- agent AT THE TIME of txn
    customer_id   INT           REFERENCES customer(customer_id),     -- NULL for walk-in card users
    type_code     VARCHAR(10)   NOT NULL REFERENCES txn_type(type_code),
    amount        NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    fee           NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fee >= 0),
    status        VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','SUCCESS','FAILED','REVERSED')),
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    completed_at  TIMESTAMPTZ,
    reversal_of   BIGINT        UNIQUE REFERENCES pos_transaction(txn_id),  -- a txn is reversed at most once
    CHECK (completed_at IS NULL OR completed_at >= created_at),
    CHECK ((type_code = 'REVERSAL') = (reversal_of IS NOT NULL))
);

CREATE TABLE ledger_entry (
    entry_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id      BIGINT        NOT NULL REFERENCES pos_transaction(txn_id),
    wallet_id   BIGINT        NOT NULL REFERENCES wallet(wallet_id),
    direction   CHAR(1)       NOT NULL CHECK (direction IN ('D','C')),
    amount      NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE commission (
    txn_id              BIGINT        PRIMARY KEY REFERENCES pos_transaction(txn_id),
    agent_amount        NUMERIC(10,2) NOT NULL CHECK (agent_amount >= 0),
    super_agent_amount  NUMERIC(10,2) NOT NULL CHECK (super_agent_amount >= 0)
);

CREATE TABLE dispute (
    dispute_id   SERIAL       PRIMARY KEY,
    txn_id       BIGINT       NOT NULL REFERENCES pos_transaction(txn_id),
    customer_id  INT          NOT NULL REFERENCES customer(customer_id),
    reason       VARCHAR(30)  NOT NULL
                 CHECK (reason IN ('DEBITED_NOT_PAID','DOUBLE_DEBIT','WRONG_AMOUNT','FRAUD')),
    status       VARCHAR(10)  NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','REFUNDED','REJECTED')),
    opened_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    resolved_at  TIMESTAMPTZ,
    CHECK (resolved_at IS NULL OR resolved_at >= opened_at),
    CHECK ((status = 'OPEN') = (resolved_at IS NULL))
);

-- ---------------------------------------------------------------------
-- Double-entry rule: for every transaction, total debits = total credits.
-- Enforced by a DEFERRED constraint trigger, checked at COMMIT time, so a
-- transaction may insert its entries one by one before it is validated.
-- ---------------------------------------------------------------------
CREATE FUNCTION check_txn_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d NUMERIC; c NUMERIC;
BEGIN
    SELECT COALESCE(SUM(amount) FILTER (WHERE direction='D'),0),
           COALESCE(SUM(amount) FILTER (WHERE direction='C'),0)
      INTO d, c
      FROM ledger_entry WHERE txn_id = NEW.txn_id;
    IF d <> c THEN
        RAISE EXCEPTION 'Unbalanced ledger for txn %: debits % <> credits %', NEW.txn_id, d, c;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_ledger_balanced
    AFTER INSERT ON ledger_entry
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_txn_balanced();

COMMENT ON SCHEMA agentlink IS 'Simulated POS agent banking network for MIT 8103 portfolio';
