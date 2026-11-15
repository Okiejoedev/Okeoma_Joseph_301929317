# Normalisation: from the agent's paper sheet to the AgentLink schema

Many POS agents in Lagos still keep a handwritten daily record in an exercise book. I used that record as the unnormalised starting point and worked through each normal form, writing down the functional dependencies (FDs) at every step.

## 0. Unnormalised form (UNF): one row per agent per day

```
DAILY_SHEET( agent_code, agent_name, agent_phone, lga_name, state, super_agent, sa_share,
             terminal_serial, sheet_date,
             { line_no, txn_ref, time, customer_phone, customer_name, type, type_desc,
               amount, fee, status } )      <- repeating group
```

Problems: the transaction list is a repeating group, so the sheet cannot be queried or totalled reliably. An agent who changes phone number has to be corrected on every sheet.

## 1. First Normal Form (1NF)

I removed the repeating group so that each row holds one transaction and every value is atomic.

```
SHEET_LINE( agent_code, sheet_date, line_no, txn_ref, time, agent_name, agent_phone, lga_name,
            state, super_agent, sa_share, terminal_serial, customer_phone, customer_name,
            type, type_desc, amount, fee, status )
PK = (agent_code, sheet_date, line_no)      candidate key: txn_ref
```

## 2. Second Normal Form (2NF): remove partial dependencies

FDs on part of the composite key:

* `agent_code -> agent_name, agent_phone, lga_name, state, super_agent, sa_share`

These attributes depend only on `agent_code`, not on the whole key, so they move to **AGENT**. I also promote `txn_ref` (the POS retrieval reference number) to primary key of the transaction relation, because it identifies a transaction on its own.

```
AGENT( agent_code, agent_name, agent_phone, lga_name, state, super_agent, sa_share )
POS_TRANSACTION( txn_ref, agent_code, terminal_serial, created_at, customer_phone, customer_name,
                 type, type_desc, amount, fee, status )
```

## 3. Third Normal Form (3NF): remove transitive dependencies

| Transitive dependency | Anomaly if kept | New relation |
|---|---|---|
| `txn_ref -> customer_phone -> customer_name` | A customer's name is stored once per transaction, so it can go stale | **CUSTOMER** |
| `txn_ref -> type -> type_desc` | Renaming a transaction type means updating 1.2 million rows | **TXN_TYPE** |
| `txn_ref -> (type, amount) -> fee` | Fee rules exist only implicitly inside past rows | **FEE_BAND** |
| `agent_code -> lga_name -> state` | State is repeated for every agent | **LGA** |
| `agent_code -> super_agent -> sa_share` | Changing a share means updating every agent row | **SUPER_AGENT** |
| `terminal_serial -> model, status` | Terminal data is repeated per transaction | **TERMINAL** |

## 4. BCNF check

Every determinant in the final relations is a candidate key:

* `TERMINAL`: `terminal_id` and `serial_no` are both candidate keys (both UNIQUE).
* `FEE_BAND`: `(type_code, min_amount) -> max_amount, flat_fee, pct_fee`, and `(type_code, min_amount)` is UNIQUE.
* `WALLET`: `agent_id`, `customer_id` and `system_code` are each UNIQUE when present.
* `LEDGER_ENTRY` and `COMMISSION`: all attributes depend on the key alone.

So the schema is in BCNF. The one intentional exception is described below.

## 5. Deliberate, controlled redundancy

| Column | Looks redundant because… | Why it is kept |
|---|---|---|
| `pos_transaction.agent_id` | It looks derivable from `terminal.agent_id` | Terminals are retrieved and reassigned. The agent **at the time of the transaction** is a historical fact, not a derived value. Commission and disputes depend on it. |
| `pos_transaction.fee` | It looks derivable from `FEE_BAND` | The fee schedule changes over time. The fee actually charged must not change when the tariff is updated. |
| `wallet.balance` | It equals `opening_balance + credits − debits` from `LEDGER_ENTRY` | Reading a balance by summing millions of ledger rows on every POS request is too slow. The stored balance is updated in the same ACID transaction as the ledger (Portfolio 3) and checked by `05_integrity_checks.sql`, which finds **0 mismatches**. |

The ledger is the source of truth and `balance` is a cache of it. That keeps the redundancy safe.
