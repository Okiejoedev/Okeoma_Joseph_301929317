# Portfolio 1: Database Design and Modelling

## Case study: AgentLink Lagos (simulated organisation)

| Item | Description |
|---|---|
| **Organisation** | *AgentLink Lagos*, a simulated POS agent-banking network across the 20 LGAs of Lagos State. It is fictional and not modelled on any real company's data. |
| **Nature of business** | Neighbourhood agents (kiosks, provision shops) use POS terminals to give cash withdrawals, accept deposits, send transfers and sell bill payments and airtime, mostly to people who live far from bank branches. Agents are grouped under licensed *super agents*, who share the commission. |
| **Database users** | Agents (through the POS app), customers (wallet app / USSD), super agents (supervision dashboards), operations & reconciliation staff, dispute/support officers, compliance/audit. |
| **Major data** | LGAs, super agents, agents, POS terminals, customers (with hashed BVN), wallets, transaction types, fee bands, POS transactions, double-entry ledger, commissions, disputes. |
| **Key operations** | Cash-out, cash-in, transfer, bill payment, airtime; reverse failed transactions; compute fees and commission; enforce agent daily cash-out limits; reconcile wallet balances against the ledger; handle customer disputes. |

## What is in this folder

| File | Purpose |
|---|---|
| `01_schema.sql` | DDL: 12 tables, PK/FK/UNIQUE/CHECK constraints, deferred double-entry trigger |
| `02_seed_reference.sql` | LGAs, transaction types, fee schedule, super agents, system wallets, `calc_fee()` |
| `03_generate_data.sql` | Reproducible synthetic data (`setseed`) of about 1.2M transactions and 3.2M ledger rows |
| `04_constraint_tests.sql` | 10 statements that **must fail**, which prove the constraints work → `evidence_constraint_tests.txt` |
| `05_integrity_checks.sql` | Row counts, double-entry and reconciliation checks → `evidence_integrity_checks.txt` |
| `er_diagram.mmd / .png / .svg` | Entity-relationship diagram (Mermaid, crow's-foot notation) |
| `normalisation.md` | UNF → 1NF → 2NF → 3NF → BCNF walkthrough and justified denormalisation |

## How to run

```bash
./rebuild.sh                     # from the repo root; drops and recreates database "agentlink"
psql -d agentlink -f portfolio-1-database-design/04_constraint_tests.sql
psql -d agentlink -f portfolio-1-database-design/05_integrity_checks.sql
```
Tested on PostgreSQL 16.15. The full load takes about 2.5 minutes and produces an 822 MB database.

## Key design decisions

1. **Double-entry ledger.** Every money movement is written as balanced debit/credit rows in `ledger_entry`. A `DEFERRABLE INITIALLY DEFERRED` constraint trigger rejects any transaction whose debits ≠ credits **at COMMIT time** (test 8). This is how real payment systems make money impossible to create or lose silently.
2. **Exact money types.** `NUMERIC(14,2)` instead of `FLOAT`, which avoids rounding errors on Naira amounts.
3. **Idempotency through constraints.** `txn_ref` is UNIQUE, so a POS terminal that retries after a network timeout cannot post the same withdrawal twice (test 2). `reversal_of` is UNIQUE, so a transaction can be reversed only once (test 7).
4. **Wallet integrity in the database, not just the app.** `wallet_one_owner` makes sure a wallet belongs to exactly one agent, customer or system account. `wallet_no_overdraft` blocks negative customer and agent balances (test 3).
5. **Privacy by design.** The raw BVN is never stored. Only a SHA-256 hash is kept, for matching (see course Study Session 6 on data privacy).
6. **No secondary indexes yet.** Only PK/UNIQUE indexes exist, so that Portfolio 2 can measure the effect of each index I add.

## Evidence (from `evidence_integrity_checks.txt`)

| Table | Rows |
|---|---:|
| agent | 3,000 |
| terminal | 3,350 |
| customer | 80,000 |
| wallet | 83,002 |
| pos_transaction | 1,209,721 |
| ledger_entry | 3,223,039 |
| commission | 889,051 |

* Unbalanced transactions: **0**
* Wallets whose balance ≠ opening + credits − debits: **0**
* Net movement across all wallets: **₦0.00** (money is conserved)
