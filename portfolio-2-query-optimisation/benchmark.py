"""
Portfolio 2: before/after index benchmark for AgentLink Lagos.

For every query in queries.sql:
  1. drop the Portfolio-2 indexes  -> "before" plans + timings
  2. create indexes.sql            -> "after"  plans + timings
Each timing is the median of 5 EXPLAIN ANALYZE runs after one warm-up run
(warm cache), taken from PostgreSQL's own "Execution Time".

Usage:  python3 benchmark.py   (env: PGHOST, PGPORT, PGUSER; database agentlink)
"""
import csv, json, os, re, statistics, time
from pathlib import Path
import psycopg

HERE = Path(__file__).parent
PLANS = HERE / "plans"
DSN = f"host={os.getenv('PGHOST','localhost')} port={os.getenv('PGPORT','5432')} " \
      f"user={os.getenv('PGUSER','postgres')} dbname=agentlink"
RUNS = 5
P2_INDEXES = ["idx_txn_customer_time", "idx_txn_agent_time", "idx_txn_failed_time",
              "idx_ledger_wallet_time", "idx_ledger_txn", "idx_txn_created_brin",
              "idx_txn_cashout_cust_time"]


def load_queries():
    text = (HERE / "queries.sql").read_text()
    parts = re.split(r"^-- @(Q\d+) \| (.*)$", text, flags=re.M)
    return [(parts[i], parts[i + 1].strip(), parts[i + 2].strip().rstrip(";"))
            for i in range(1, len(parts), 3)]


def plan_text(cur, sql):
    cur.execute("EXPLAIN (ANALYZE, BUFFERS, COSTS, FORMAT TEXT) " + sql)
    return "\n".join(r[0] for r in cur.fetchall())


def exec_ms(cur, sql):
    cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + sql)
    return cur.fetchone()[0][0]["Execution Time"]


def top_node(cur, sql):
    cur.execute("EXPLAIN (FORMAT JSON) " + sql)
    plan = cur.fetchone()[0][0]["Plan"]
    # collect scan node types to summarise access paths
    scans = []
    def walk(n):
        if "Scan" in n["Node Type"]:
            scans.append(f'{n["Node Type"]}' + (f' ({n.get("Index Name")})' if n.get("Index Name") else
                                               f' ({n.get("Relation Name")})' if n.get("Relation Name") else ""))
        for c in n.get("Plans", []):
            walk(c)
    walk(plan)
    return "; ".join(dict.fromkeys(scans))


def write_cost(cur, label):
    """Insert 50,000 transactions inside a transaction, time it, then roll back."""
    cur.execute("BEGIN")
    t0 = time.perf_counter()
    cur.execute("""
        INSERT INTO pos_transaction (txn_ref, terminal_id, agent_id, customer_id, type_code,
                                     amount, fee, status, created_at, completed_at)
        SELECT 'B' || lpad(g::text, 12, '0'), '2AGL0001', 1, 1 + g % 80000, 'CASH_OUT',
               5000, 200, 'SUCCESS', TIMESTAMPTZ '2026-11-01' + g * INTERVAL '1 second',
               TIMESTAMPTZ '2026-11-01' + g * INTERVAL '1 second'
        FROM generate_series(1, 50000) g""")
    ms = (time.perf_counter() - t0) * 1000
    cur.execute("ROLLBACK")
    return ms


def run_phase(conn, phase, queries):
    out = {}
    (PLANS / phase).mkdir(parents=True, exist_ok=True)
    with conn.cursor() as cur:
        cur.execute("SET search_path TO agentlink")
        for qid, title, sql in queries:
            exec_ms(cur, sql)                                  # warm-up
            times = [exec_ms(cur, sql) for _ in range(RUNS)]
            txt = plan_text(cur, sql)
            (PLANS / phase / f"{qid}.txt").write_text(f"-- {qid}: {title}\n-- phase: {phase}\n\n{sql};\n\n{txt}\n")
            out[qid] = (statistics.median(times), top_node(cur, sql))
            print(f"  {phase:6} {qid}  {out[qid][0]:10.2f} ms   {out[qid][1]}")
        out["_write"] = write_cost(cur, phase)
        print(f"  {phase:6} insert 50k rows: {out['_write']:.0f} ms")
    return out


def main():
    queries = load_queries()
    with psycopg.connect(DSN, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO agentlink")
            for ix in P2_INDEXES:
                cur.execute(f"DROP INDEX IF EXISTS {ix}")
            cur.execute("VACUUM ANALYZE pos_transaction")
            cur.execute("VACUUM ANALYZE ledger_entry")
        print("BEFORE (only PK/UNIQUE indexes)")
        before = run_phase(conn, "before", queries)

        with conn.cursor() as cur:
            t0 = time.perf_counter()
            cur.execute((HERE / "indexes.sql").read_text())
            build_s = time.perf_counter() - t0
            cur.execute("VACUUM ANALYZE pos_transaction")
            cur.execute("VACUUM ANALYZE ledger_entry")
            cur.execute("""SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)),
                                  pg_relation_size(indexrelid)
                           FROM pg_stat_user_indexes WHERE schemaname='agentlink'
                             AND indexrelname = ANY(%s) ORDER BY 3 DESC""", (P2_INDEXES,))
            sizes = cur.fetchall()
        print(f"Indexes built in {build_s:.1f}s")
        print("AFTER")
        after = run_phase(conn, "after", queries)

    with open(HERE / "results.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["query", "title", "before_ms", "after_ms", "speedup_x", "before_access", "after_access"])
        for qid, title, _ in queries:
            b, a = before[qid][0], after[qid][0]
            w.writerow([qid, title, f"{b:.2f}", f"{a:.2f}", f"{b / a:.1f}", before[qid][1], after[qid][1]])
    with open(HERE / "index_sizes_and_write_cost.txt", "w") as f:
        f.write("Index sizes after build\n")
        for name, pretty, _ in sizes:
            f.write(f"  {name:28} {pretty}\n")
        f.write(f"\nTotal index build time: {build_s:.1f} s\n")
        f.write(f"\nInsert 50,000 POS transactions (rolled back):\n"
                f"  before P2 indexes: {before['_write']:.0f} ms\n"
                f"  after  P2 indexes: {after['_write']:.0f} ms\n"
                f"  overhead: {after['_write'] / before['_write']:.2f}x\n")
    print((HERE / "index_sizes_and_write_cost.txt").read_text())


if __name__ == "__main__":
    main()
