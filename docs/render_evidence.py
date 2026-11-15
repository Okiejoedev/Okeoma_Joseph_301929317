"""
Renders excerpts of the captured evidence files (real program output) as
terminal-style PNG screenshots in docs/screenshots/. Nothing is retyped:
each image is cut from the evidence file between two marker lines.

Usage: python3 docs/render_evidence.py   (needs: pip install playwright)
"""
import html
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "screenshots"
OUT.mkdir(parents=True, exist_ok=True)

# (output name, title bar command, evidence file, start marker, end marker or None, max lines)
SHOTS = [
    ("p1_constraint_tests", "psql -d agentlink -f 04_constraint_tests.sql",
     "portfolio-1-database-design/evidence_constraint_tests.txt", "[2]", "[9]", 22),
    ("p1_integrity_checks", "psql -d agentlink -f 05_integrity_checks.sql",
     "portfolio-1-database-design/evidence_integrity_checks.txt", "--- Double-entry", "--- Agents per LGA", 20),
    ("p2_q1_before", "EXPLAIN (ANALYZE, BUFFERS) Q1 - before indexing",
     "portfolio-2-query-optimisation/plans/before/Q1.txt", "Limit", "Planning:", 22),
    ("p2_q1_after", "EXPLAIN (ANALYZE, BUFFERS) Q1 - after idx_txn_customer_time",
     "portfolio-2-query-optimisation/plans/after/Q1.txt", "Limit", None, 16),
    ("p2_not_in_bug", "psql -f rewrites.sql  (R2: NOT IN vs NOT EXISTS)",
     "portfolio-2-query-optimisation/evidence_rewrites.txt", "--- R2a", "--- R2c", 14),
    ("p3_lost_update_and_fix", "python3 demos.py  (D5 lost update, D7 REPEATABLE READ fix)",
     "portfolio-3-transactions-concurrency/evidence_demos.txt", "D5  LOST UPDATE", "D6  FIX 1", 14),
    ("p3_repeatable_read_fix", "python3 demos.py  (D7)",
     "portfolio-3-transactions-concurrency/evidence_demos.txt", "D7  FIX 2", "D8  FIX 3", 16),
    ("p3_write_skew", "python3 demos.py  (D10 write skew on the daily limit)",
     "portfolio-3-transactions-concurrency/evidence_demos.txt", "D10  WRITE SKEW", "D11  DEADLOCK", 30),
    ("p3_deadlock", "python3 demos.py  (D11 deadlock)",
     "portfolio-3-transactions-concurrency/evidence_demos.txt", "D11  DEADLOCK", "D12  IDEMPOTENCY", 18),
    ("p4_mongo_explain", "mongosh agentlink mongo_queries.js  (M4 explain before/after index)",
     "portfolio-4-nosql/evidence_mongo.txt", "M4. Index", "M5. Aggregation", 22),
    ("p4_redis_limit", "python3 redis_demo.py  (K1, K2)",
     "portfolio-4-nosql/evidence_redis.txt", "K1. Idempotency", "K3. Leaderboard", 20),
    ("p5_pg_sync_failover", "bash 01_pg_replication.sh  (R7-R9)",
     "portfolio-5-distributed-cloud/evidence_pg_replication.txt", "R7. Standby", "R10.", 40),
    ("p5_mongo_failover", "python3 03_mongo_replicaset.py  (S4-S6)",
     "portfolio-5-distributed-cloud/evidence_mongo_replicaset.txt", "S4. FAILOVER", "Shutdown", 26),
    ("p5_sharding_routing", "python3 04_mongo_sharding.py  (Z4-Z5)",
     "portfolio-5-distributed-cloud/evidence_mongo_sharding.txt", "Z4. Where", "Z6. Cluster", 22),
]

CSS = """
body{margin:0;background:#fff;font-family:'DejaVu Sans Mono',monospace}
.win{display:inline-block;margin:8px;border-radius:8px;overflow:hidden;
     box-shadow:0 2px 8px rgba(0,0,0,.25);background:#1e1f22;min-width:900px}
.bar{background:#2d2f33;color:#c9ccd1;font:12px 'DejaVu Sans',sans-serif;padding:7px 12px}
.bar b{color:#8fd18f;font-weight:normal}
.dots span{display:inline-block;width:10px;height:10px;border-radius:5px;margin-right:6px}
pre{margin:0;padding:12px 16px;color:#e6e6e6;font-size:12.5px;line-height:1.35;white-space:pre}
.err{color:#ff8a80}.ok{color:#9be59b}.hl{color:#ffd479}
"""


def colour(line):
    e = html.escape(line)
    low = line.lower()
    if "no committed row was lost" in low or "no acknowledged write lost" in low:
        return f'<span class="ok">{e}</span>'
    if "might not" in low:
        return e
    if "error" in low or "failed" in low or " lost" in low or "wrong" in low or "broken" in low or "rejected" in low or "deadlock detected" in low:
        return f'<span class="err">{e}</span>'
    if "not yet" in low or "might not" in low:
        return e
    if "no committed row was lost" in low or "no acknowledged write lost" in low:
        return f'<span class="ok">{e}</span>'
    if "correct" in low or "committed" in low or "commit ok" in low or "respected" in low or "ixscan" in low:
        return f'<span class="ok">{e}</span>'
    if line.startswith("=") or line.startswith("---") or line[:3].strip().startswith(("D", "R", "M", "K", "S", "Z")) and ". " in line[:6]:
        return f'<span class="hl">{e}</span>'
    return e


def excerpt(text, start, end, max_lines):
    lines = text.splitlines()
    i = next(n for n, l in enumerate(lines) if start in l)
    j = next((n for n, l in enumerate(lines[i + 1:], i + 1) if end and end in l), len(lines))
    chunk = [l[:150] for l in lines[i:j]]
    while chunk and not chunk[-1].strip("= "):
        chunk.pop()
    if len(chunk) > max_lines:
        chunk = chunk[:max_lines] + ["   ... (truncated - full output in the evidence file)"]
    return chunk


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(device_scale_factor=2, viewport={"width": 1300, "height": 900})
    for name, cmd, src, start, end, mx in SHOTS:
        lines = excerpt((ROOT / src).read_text(), start, end, mx)
        body = "\n".join(colour(l) for l in lines)
        pg.set_content(f"<style>{CSS}</style><div class='win'><div class='bar'><span class='dots'>"
                       f"<span style='background:#ff5f57'></span><span style='background:#febc2e'></span>"
                       f"<span style='background:#28c840'></span></span> <b>$</b> {html.escape(cmd)}"
                       f"&nbsp;&nbsp;·&nbsp;&nbsp;{html.escape(src)}</div><pre>{body}</pre></div>")
        pg.locator(".win").screenshot(path=str(OUT / f"{name}.png"))
        print("wrote", name)
    b.close()
