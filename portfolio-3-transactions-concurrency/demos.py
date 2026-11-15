"""
Portfolio 3: Transactions and concurrency demonstrations for AgentLink Lagos.

Every scenario resets the demo fixtures, then drives one or two real PostgreSQL
sessions (A and B) and prints a time-stamped log of what each session did and
what the database answered.  Run:   python3 demos.py  > evidence_demos.txt

Scenarios
  D1  COMMIT              successful cash-out (atomic multi-row update)
  D2  ROLLBACK            business-rule failure and explicit rollback
  D3  SAVEPOINT           partial rollback inside a batch
  D4  CRASH / DISCONNECT  POS loses connection mid-transaction
  D5  LOST UPDATE         naive read-modify-write under READ COMMITTED
  D6  FIX 1: pessimistic  SELECT ... FOR UPDATE
  D7  FIX 2: isolation    REPEATABLE READ -> serialization failure + retry
  D8  FIX 3: optimistic   version column check
  D9  NON-REPEATABLE READ READ COMMITTED vs REPEATABLE READ
  D10 WRITE SKEW          daily cash-out limit: REPEATABLE READ vs SERIALIZABLE
  D11 DEADLOCK            unordered locks vs ordered locks
  D12 IDEMPOTENCY         POS retry with same txn_ref, double reversal race
"""
import os, threading, time
from pathlib import Path
import psycopg
from psycopg import errors

HERE = Path(__file__).parent
DSN = f"host={os.getenv('PGHOST','localhost')} port={os.getenv('PGPORT','5432')} " \
      f"user={os.getenv('PGUSER','postgres')} dbname=agentlink options='-c search_path=agentlink'"
T0 = time.perf_counter()
LOCK = threading.Lock()


def log(who, msg):
    with LOCK:
        print(f"  [t+{time.perf_counter() - T0:6.3f}s] {who:<9} {msg}", flush=True)


def header(code, title, idea):
    global T0
    print("\n" + "=" * 78)
    print(f"{code}  {title}")
    print(f"     {idea}")
    print("=" * 78)
    with psycopg.connect(DSN, autocommit=True) as c:
        c.execute((HERE / "fixtures.sql").read_text())
    T0 = time.perf_counter()


def conn(name, isolation=None):
    c = psycopg.connect(DSN, autocommit=False, application_name=name)
    if isolation:
        c.execute(f"SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL {isolation}")
        c.commit()
    return c


def one(c, sql, args=None):
    return c.execute(sql, args).fetchone()[0]


ADA = "(SELECT wallet_id FROM wallet WHERE customer_id = (SELECT customer_id FROM customer WHERE phone='08099990001'))"
BAYO = "(SELECT wallet_id FROM wallet WHERE customer_id = (SELECT customer_id FROM customer WHERE phone='08099990002'))"
AGENT = "(SELECT wallet_id FROM wallet WHERE agent_id = (SELECT agent_id FROM agent WHERE agent_code='AGL-DEMO01'))"
ADA_ID = "(SELECT customer_id FROM customer WHERE phone='08099990001')"
BAYO_ID = "(SELECT customer_id FROM customer WHERE phone='08099990002')"


def balances(label="DB"):
    with psycopg.connect(DSN, autocommit=True) as c:
        a, b, g = c.execute(f"SELECT (SELECT balance FROM wallet WHERE wallet_id={ADA}),"
                            f"(SELECT balance FROM wallet WHERE wallet_id={BAYO}),"
                            f"(SELECT balance FROM wallet WHERE wallet_id={AGENT})").fetchone()
    log(label, f"balances -> Ada N{a:,.2f} | Bayo N{b:,.2f} | Agent N{g:,.2f}")
    return a, b, g


def reconcile():
    with psycopg.connect(DSN, autocommit=True) as c:
        bad = one(c, f"""SELECT count(*) FROM wallet w WHERE wallet_id IN ({ADA},{BAYO},{AGENT})
              AND balance <> opening_balance + COALESCE((SELECT SUM(CASE direction WHEN 'C' THEN amount
                    ELSE -amount END) FROM ledger_entry le WHERE le.wallet_id = w.wallet_id),0)""")
    log("CHECK", f"wallets whose balance disagrees with the ledger: {bad}")
    return bad


# --------------------------------------------------------------------------- D1
def d1():
    header("D1", "COMMIT - successful cash-out", "Debit customer, credit agent, credit fee wallet, "
           "insert txn + 3 ledger rows: all or nothing.")
    balances("before")
    a = conn("A")
    txn = one(a, f"SELECT cash_out('XD1000000001', '2AGD0001', {ADA_ID}, 10000)")
    log("A", f"cash_out(N10,000) for Ada returned txn_id={txn}; fee = N{one(a, 'SELECT fee FROM pos_transaction WHERE txn_id=%s', (txn,))}")
    rows = a.execute("SELECT direction, wallet_id, amount FROM ledger_entry WHERE txn_id=%s ORDER BY entry_id",
                     (txn,)).fetchall()
    for r in rows:
        log("A", f"  ledger {r[0]} wallet {r[1]} N{r[2]:,.2f}")
    a.commit(); log("A", "COMMIT (deferred double-entry trigger passed)")
    balances("after"); reconcile(); a.close()


# --------------------------------------------------------------------------- D2
def d2():
    header("D2", "ROLLBACK - failed business rule and explicit rollback",
           "An exception anywhere in the transaction undoes every change made before it.")
    balances("before")
    a = conn("A")
    try:
        one(a, f"SELECT cash_out('XD2000000001', '2AGD0001', {BAYO_ID}, 25000)")
    except errors.RaiseException as e:
        log("A", f"ERROR: {e.diag.message_primary}")
        a.rollback(); log("A", "ROLLBACK")
    log("A", "BEGIN; cash_out(N5,000) for Ada ... customer cancels at the POS")
    one(a, f"SELECT cash_out('XD2000000002', '2AGD0001', {ADA_ID}, 5000)")
    log("A", f"inside txn Ada's balance is N{one(a, f'SELECT balance FROM wallet WHERE wallet_id={ADA}'):,.2f}")
    a.rollback(); log("A", "ROLLBACK (explicit)")
    with psycopg.connect(DSN, autocommit=True) as c:
        n = one(c, "SELECT count(*) FROM pos_transaction WHERE txn_ref LIKE 'XD2%'")
    log("CHECK", f"transactions with ref XD2*: {n} (nothing persisted)")
    balances("after"); a.close()


# --------------------------------------------------------------------------- D3
def d3():
    header("D3", "SAVEPOINT - partial rollback in a batch",
           "Ada pays 3 bills in one transaction; the 2nd overdraws, only it is undone.")
    balances("before")
    a = conn("A")
    for i, amt in enumerate([15000, 60000, 8000], 1):
        a.execute("SAVEPOINT bill")
        try:
            a.execute(f"""UPDATE wallet SET balance = balance - %s WHERE wallet_id = {ADA}""", (amt,))
            a.execute("RELEASE SAVEPOINT bill")
            log("A", f"bill {i}: N{amt:,} debited")
        except errors.CheckViolation as e:
            a.execute("ROLLBACK TO SAVEPOINT bill")
            log("A", f"bill {i}: N{amt:,} rejected ({e.diag.constraint_name}) -> ROLLBACK TO SAVEPOINT")
    a.rollback()   # demo only: these bill debits had no ledger rows, so do not keep them
    log("A", "(demo rolled back - bill payments here were not posted to the ledger)")
    log("A", "result inside txn was: 50,000 - 15,000 - 8,000 = 27,000; bill 2 skipped")
    a.close()


# --------------------------------------------------------------------------- D4
def d4():
    header("D4", "ATOMICITY on crash - POS terminal loses its connection mid-transaction",
           "The server rolls back an uncommitted transaction when its session dies.")
    balances("before")
    a = conn("A")
    one(a, f"SELECT cash_out('XD4000000001', '2AGD0001', {ADA_ID}, 20000)")
    pid = one(a, "SELECT pg_backend_pid()")
    log("A", f"cash_out(N20,000) done but NOT committed (backend pid {pid})")
    with psycopg.connect(DSN, autocommit=True) as admin:
        one(admin, "SELECT pg_terminate_backend(%s)", (pid,))
    log("ADMIN", f"pg_terminate_backend({pid})  -- simulates network drop / crash")
    try:
        a.commit()
    except psycopg.OperationalError as e:
        log("A", f"COMMIT failed: {str(e).splitlines()[0]}")
    balances("after"); reconcile()


# --------------------------------------------------------------------------- D5-D8
def naive_withdraw(c, who, amount, gate_read, gate_write, mode="naive"):
    """read balance -> app computes new value -> write it back"""
    sel = f"SELECT balance, version FROM wallet WHERE wallet_id = {ADA}"
    if mode == "for_update":
        sel += " FOR UPDATE"
    t = time.perf_counter()
    bal, ver = c.execute(sel).fetchone()
    waited = time.perf_counter() - t
    log(who, f"read balance N{bal:,.2f} (version {ver})" + (f"  [waited {waited:.2f}s for row lock]" if waited > 0.2 else ""))
    gate_read.set()
    gate_write.wait()
    new = bal - amount
    if mode == "optimistic":
        n = c.execute(f"UPDATE wallet SET balance=%s, version=version+1 WHERE wallet_id={ADA} AND version=%s",
                      (new, ver)).rowcount
        if n == 0:
            c.rollback(); log(who, "UPDATE ... WHERE version = old matched 0 rows -> conflict, ROLLBACK and retry")
            return False
    else:
        c.execute(f"UPDATE wallet SET balance=%s, version=version+1 WHERE wallet_id={ADA}", (new,))
    log(who, f"write balance = N{bal:,.2f} - N{amount:,} = N{new:,.2f}")
    c.commit(); log(who, "COMMIT")
    return True


def scenario_lost_update(code, title, idea, mode, isolation=None):
    header(code, title, idea)
    balances("before")
    a, b = conn("A", isolation), conn("B", isolation)
    a_read, b_read, a_go, b_go = (threading.Event() for _ in range(4))
    result = {}

    def worker(c, who, amt, my_read, my_go):
        for attempt in (1, 2):
            try:
                ok = naive_withdraw(c, who, amt, my_read, my_go, mode)
                if ok:
                    return
            except errors.SerializationFailure as e:
                c.rollback()
                log(who, f"ERROR {e.sqlstate}: {e.diag.message_primary} -> ROLLBACK")
            if attempt == 1:
                log(who, "retrying transaction from the start")
                my_go.set()
    # A reads, B reads, A writes+commits, B writes+commits
    ta = threading.Thread(target=worker, args=(a, "A", 10000, a_read, a_go))
    tb = threading.Thread(target=worker, args=(b, "B", 5000, b_read, b_go))
    ta.start(); a_read.wait()
    tb.start()
    b_read.wait(timeout=1.5)            # with FOR UPDATE, B blocks here instead
    a_go.set(); ta.join()
    b_go.set(); tb.join()
    a.close(); b.close()
    _, _, _ = balances("after")
    with psycopg.connect(DSN, autocommit=True) as c:
        final = one(c, f"SELECT balance FROM wallet WHERE wallet_id={ADA}")
    verdict = "CORRECT" if final == 35000 else "WRONG - an update was LOST"
    log("CHECK", f"expected 50,000 - 10,000 - 5,000 = N35,000; got N{final:,.2f} -> {verdict}")


def d5():
    scenario_lost_update("D5", "LOST UPDATE - naive read-modify-write (READ COMMITTED)",
                         "Two tellers withdraw from Ada at the same moment: A=N10,000, B=N5,000.",
                         "naive")


def d6():
    scenario_lost_update("D6", "FIX 1 - pessimistic locking with SELECT ... FOR UPDATE",
                         "B's read blocks until A commits, then B sees A's result.", "for_update")


def d7():
    scenario_lost_update("D7", "FIX 2 - REPEATABLE READ detects the conflict",
                         "B's UPDATE fails with SQLSTATE 40001; the application retries.",
                         "naive", "REPEATABLE READ")


def d8():
    scenario_lost_update("D8", "FIX 3 - optimistic locking with a version column",
                         "UPDATE ... WHERE version = <version read>; 0 rows means someone else won.",
                         "optimistic")


# --------------------------------------------------------------------------- D9
def d9():
    header("D9", "NON-REPEATABLE READ - READ COMMITTED vs REPEATABLE READ",
           "A (an auditor) reads Ada's balance twice while B commits a withdrawal in between.")
    for iso in ("READ COMMITTED", "REPEATABLE READ"):
        with psycopg.connect(DSN, autocommit=True) as c:
            c.execute((HERE / "fixtures.sql").read_text())
        a, b = conn("A", iso), conn("B")
        r1 = one(a, f"SELECT balance FROM wallet WHERE wallet_id={ADA}")
        log("A", f"[{iso}] first read  N{r1:,.2f}")
        b.execute(f"UPDATE wallet SET balance = balance - 7000 WHERE wallet_id={ADA}"); b.commit()
        log("B", "withdraws N7,000 and COMMITs")
        r2 = one(a, f"SELECT balance FROM wallet WHERE wallet_id={ADA}")
        log("A", f"[{iso}] second read N{r2:,.2f}  -> " +
            ("NON-REPEATABLE READ (value changed inside one transaction)" if r1 != r2
             else "same snapshot, repeatable"))
        a.commit(); a.close(); b.close()
    with psycopg.connect(DSN, autocommit=True) as c:
        c.execute((HERE / "fixtures.sql").read_text())


# --------------------------------------------------------------------------- D10
def d10():
    header("D10", "WRITE SKEW / PHANTOM - agent daily cash-out limit (N100,000)",
           "Each session checks 'used today + amount <= limit' then inserts. Neither sees the other's insert.")
    for iso in ("REPEATABLE READ", "SERIALIZABLE"):
        with psycopg.connect(DSN, autocommit=True) as c:
            c.execute((HERE / "fixtures.sql").read_text())
        print(f"  --- isolation level: {iso}")
        a, b = conn("A", iso), conn("B", iso)
        check = """SELECT COALESCE(SUM(amount),0) FROM pos_transaction
                   WHERE terminal_id='2AGD0001' AND type_code='CASH_OUT' AND status='SUCCESS'
                     AND created_at >= date_trunc('day', now())"""
        ins = """INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, customer_id, type_code, amount, status)
                 VALUES (%s, '2AGD0001', (SELECT agent_id FROM terminal WHERE terminal_id='2AGD0001'),
                         {cust}, 'CASH_OUT', %s, 'SUCCESS')"""
        ua = one(a, check); log("A", f"used today N{ua:,.2f}; wants N60,000 -> {ua + 60000:,.0f} <= 100,000 OK")
        ub = one(b, check); log("B", f"used today N{ub:,.2f}; wants N70,000 -> {ub + 70000:,.0f} <= 100,000 OK")
        a.execute(ins.format(cust=ADA_ID), (f"XD10{iso[:2]}A00001", 60000)); log("A", "INSERT cash-out N60,000")
        b.execute(ins.format(cust=BAYO_ID), (f"XD10{iso[:2]}B00001", 70000)); log("B", "INSERT cash-out N70,000")
        a.commit(); log("A", "COMMIT ok")
        try:
            b.commit(); log("B", "COMMIT ok")
        except errors.SerializationFailure as e:
            log("B", f"COMMIT failed {e.sqlstate}: {e.diag.message_primary}")
            log("B", f"  detail: {e.diag.message_detail}")
        with psycopg.connect(DSN, autocommit=True) as c:
            total = one(c, check)
        log("CHECK", f"agent's cash-outs today = N{total:,.2f} -> " +
            ("LIMIT BROKEN (write skew)" if total > 100000 else "limit respected"))
        a.close(); b.close()
    print("  Note: the production cash_out() function avoids this at READ COMMITTED by locking the\n"
          "  agent's wallet row FOR UPDATE before the check, which serialises cash-outs per agent.")
    # prove it
    with psycopg.connect(DSN, autocommit=True) as c:
        c.execute((HERE / "fixtures.sql").read_text())
    a, b = conn("A"), conn("B")
    one(a, f"SELECT cash_out('XD10LKA00001', '2AGD0001', {ADA_ID}, 30000)")
    log("A", "cash_out(N30,000) via function, not yet committed (holds agent wallet lock)")
    def tb():
        try:
            one(b, f"SELECT cash_out('XD10LKB00001', '2AGD0001', {BAYO_ID}, 75000)"); b.commit()
            log("B", "cash_out(N75,000) committed after waiting for A")
        except errors.RaiseException as e:
            b.rollback(); log("B", f"rejected: {e.diag.message_primary}")
    log("B", "cash_out(N75,000) at the same agent starts...")
    th = threading.Thread(target=tb); th.start(); time.sleep(1.0)
    log("B", "... is blocked waiting for the agent-wallet row lock")
    a.commit(); log("A", "COMMIT"); th.join(); a.close(); b.close()


# --------------------------------------------------------------------------- D11
def d11():
    header("D11", "DEADLOCK - transfers in opposite directions",
           "A: Ada -> Bayo, B: Bayo -> Ada. Unordered locking can deadlock; ordered locking cannot.")
    for ordered in (False, True):
        with psycopg.connect(DSN, autocommit=True) as c:
            c.execute((HERE / "fixtures.sql").read_text())
            ada, bayo = c.execute(f"SELECT {ADA}, {BAYO}").fetchone()
        print(f"  --- locking strategy: {'ORDERED (lowest wallet_id first)' if ordered else 'UNORDERED (source first)'}")
        a, b = conn("A"), conn("B")
        def run(c, who, ref, f, t):
            try:
                one(c, "SELECT wallet_transfer(%s::varchar,%s::bigint,%s::bigint,%s::numeric,%s::boolean,%s::numeric)", (ref, f, t, 1000, ordered, 0.5))
                c.commit(); log(who, "transfer COMMITTED")
            except errors.DeadlockDetected as e:
                c.rollback(); log(who, f"ERROR 40P01 deadlock detected -> this txn was chosen as victim, ROLLBACK")
        ta = threading.Thread(target=run, args=(a, "A", f"XD11{int(ordered)}A0001", ada, bayo))
        tb = threading.Thread(target=run, args=(b, "B", f"XD11{int(ordered)}B0001", bayo, ada))
        log("A", f"wallet_transfer(Ada {ada} -> Bayo {bayo}, N1,000)")
        log("B", f"wallet_transfer(Bayo {bayo} -> Ada {ada}, N1,000)")
        ta.start(); tb.start(); ta.join(); tb.join(); a.close(); b.close()
        balances("after")


# --------------------------------------------------------------------------- D12
def d12():
    header("D12", "IDEMPOTENCY - POS retry and double reversal",
           "Network timeouts make terminals resend; support staff may click 'reverse' twice.")
    a = conn("A")
    txn = one(a, f"SELECT cash_out('XD12000000001', '2AGD0001', {ADA_ID}, 10000)"); a.commit()
    log("POS", f"cash_out ref XD12000000001 committed as txn {txn}; response lost in the network")
    try:
        one(a, f"SELECT cash_out('XD12000000001', '2AGD0001', {ADA_ID}, 10000)"); a.commit()
    except errors.UniqueViolation as e:
        a.rollback()
        log("POS", f"retry with same ref -> {e.sqlstate} unique_violation ({e.diag.constraint_name})")
        orig = a.execute("SELECT txn_id, status FROM pos_transaction WHERE txn_ref='XD12000000001'").fetchone()
        a.commit()
        log("POS", f"app returns original result instead: txn {orig[0]} {orig[1]} - customer debited once")
    balances("after retry")
    b = conn("B")
    out = {}
    def rev(c, who):
        try:
            r = one(c, "SELECT reverse_txn(%s)", (txn,)); c.commit()
            log(who, f"reverse_txn -> reversal txn {r} COMMITTED")
        except (errors.RaiseException, errors.UniqueViolation) as e:
            c.rollback(); log(who, f"reverse_txn rejected: {e.diag.message_primary}")
    t1 = threading.Thread(target=rev, args=(a, "Officer1")); t2 = threading.Thread(target=rev, args=(b, "Officer2"))
    t1.start(); t2.start(); t1.join(); t2.join()
    balances("after reversal"); reconcile()
    a.close(); b.close()


if __name__ == "__main__":
    print("AgentLink Lagos - Portfolio 3 transaction & concurrency evidence")
    with psycopg.connect(DSN, autocommit=True) as c:
        print("PostgreSQL:", one(c, "SHOW server_version"), "| default isolation:",
              one(c, "SHOW default_transaction_isolation"), "| deadlock_timeout:", one(c, "SHOW deadlock_timeout"))
    for f in (d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11, d12):
        f()
    with psycopg.connect(DSN, autocommit=True) as c:
        c.execute((HERE / "fixtures.sql").read_text())
    print("\nAll scenarios finished; demo fixtures reset.")
