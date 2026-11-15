# Portfolio 3: Transactions and Concurrency

Money moves at an AgentLink POS only through database transactions. This portfolio shows how commit, rollback, savepoints, isolation levels and locking protect customer wallets when many terminals act on the same rows at once.

## Files

| File | Purpose |
|---|---|
| `procedures.sql` | `cash_out()`, `reverse_txn()`, `wallet_transfer()`: PL/pgSQL business transactions |
| `fixtures.sql` | Resets a demo agent (limit ₦100,000) and two demo customers (Ada ₦50,000, Bayo ₦20,000) |
| `demos.py` | Runs 12 scenarios with two real database sessions (A and B) and prints a time-stamped log |
| `evidence_demos.txt` | Full output of `python3 demos.py` |
| `evidence_server_log_deadlock.txt` | PostgreSQL server-log entry for the deadlock in D11 |

Run: `psql -d agentlink -f procedures.sql && python3 demos.py > evidence_demos.txt`

## Scenarios and results (from `evidence_demos.txt`)

| # | Scenario | What happened | Concept |
|---|---|---|---|
| D1 | Cash-out ₦10,000 | 1 txn row + 3 ledger rows (D ₦10,300 / C ₦10,000 / C ₦300 fee) committed together. Ada 50,000 → 39,700, agent 300,000 → 310,000. 0 reconciliation errors | **Atomicity, durability** |
| D2 | Bayo withdraws ₦25,000 with ₦20,000 | `Insufficient funds` exception → ROLLBACK. Explicit ROLLBACK after a cancelled cash-out → 0 rows persisted | **Rollback** |
| D3 | 3 bill payments in one txn | The 2nd hits `wallet_no_overdraft`. `ROLLBACK TO SAVEPOINT` undoes only that one | **Savepoints** |
| D4 | POS session killed before COMMIT | `pg_terminate_backend` → server discards the work; balances unchanged | **Atomicity on failure** |
| D5 | Two tellers debit Ada (₦10k + ₦5k) with naive read-modify-write | Final balance **₦45,000 instead of ₦35,000**: a ₦5,000 *lost update* | **Concurrency anomaly** |
| D6 | Same, with `SELECT … FOR UPDATE` | B **waited 1.50 s** for A's row lock, then read ₦40,000 → correct ₦35,000 | **Pessimistic locking (2PL)** |
| D7 | Same, under `REPEATABLE READ` | B got **SQLSTATE 40001** "could not serialize access due to concurrent update", retried → ₦35,000 | **Snapshot isolation (MVCC)** |
| D8 | Same, with a `version` column | B's `UPDATE … WHERE version = 0` matched 0 rows → retried → ₦35,000 | **Optimistic concurrency control** |
| D9 | Auditor reads Ada twice while B withdraws ₦7,000 | READ COMMITTED: 50,000 then 43,000 (*non-repeatable read*). REPEATABLE READ: 50,000 both times | **Isolation levels** |
| D10 | Two cash-outs (₦60k + ₦70k) checked against a ₦100k daily limit | REPEATABLE READ: both commit → **₦130,000, limit broken** (*write skew*). SERIALIZABLE: B fails 40001 ("pivot") → ₦60,000 | **Serializable SSI** |
| D10b | Same rule inside `cash_out()` at READ COMMITTED | B blocked on the agent-wallet lock, then correctly **rejected: limit exceeded (used 30,000)** | **Locking a parent row** |
| D11 | Ada→Bayo and Bayo→Ada at the same time | Unordered locks: **40P01 deadlock detected**, one victim rolled back. Ordered locks (lowest `wallet_id` first): both commit | **Deadlock & prevention** |
| D12 | POS resends the same `txn_ref`; two officers reverse at once | 23505 unique violation → original result returned (customer debited once). Second reversal rejected (status already REVERSED) | **Idempotency** |

## Analysis

* **Why not just use SERIALIZABLE everywhere?** It is the safest level (D10), but it aborts transactions under contention and the application must retry every 40001 error. For the hot cash-out path I chose **READ COMMITTED + explicit row locks in a fixed order**. Locking the agent's wallet row makes concurrent cash-outs at the *same* agent run one at a time, which makes the daily-limit check safe (D10b). Cash-outs at *different* agents still run in parallel. SERIALIZABLE suits rare, complex jobs such as end-of-day settlement.
* **Pessimistic vs optimistic.** `FOR UPDATE` (D6) costs waiting time, which is fine for short wallet updates. The version check (D8) suits the mobile wallet app, where a user may look at a screen for minutes before confirming. Holding a database lock that long would block everyone else.
* **Deadlocks** cannot be completely ruled out in a busy system. They *can* be prevented for known patterns by always acquiring locks in the same global order. `cash_out()`, `reverse_txn()` and the ordered `wallet_transfer()` all lock wallets `ORDER BY wallet_id`. PostgreSQL detected the cycle in D11 after `deadlock_timeout` (1 s) and aborted one transaction (`evidence_server_log_deadlock.txt`).
* **Business rules belong in the transaction, not only in the app.** D5 shows that correct-looking application code (`read → subtract → write`) loses money once two requests overlap. The database's ACID guarantees only help if the *whole* business operation, including the check, runs inside one transaction with the right lock or isolation level.

## Link to course material
Study Session 1 (DBMS components: transaction manager, concurrency control, recovery) and Session 2 (ACID vs BASE). Everything here is the ACID side. Portfolio 5 shows what changes when the data is replicated across nodes.
