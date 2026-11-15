"""
Portfolio 4: Redis key-value model for AgentLink Lagos (the "hot path" store).

K1 Idempotency keys          SET NX EX      - drop duplicate POS retries in < 1 ms
K2 Atomic daily-limit check  Lua script     - 20 concurrent cash-outs vs a N100,000 limit
K3 Agent leaderboard         sorted set     - October volume ranking (from PostgreSQL)
K4 Terminal presence         keys with TTL  - "online" flag that expires without heartbeats
K5 Cache-aside               GET/SETEX      - agent profile cached in front of PostgreSQL
K6 PIN brute-force limiter   INCR + EXPIRE
K7 Event stream              XADD / XREADGROUP - txn notifications to SMS + fraud consumers

Run: python3 redis_demo.py > evidence_redis.txt
"""
import os, time, threading, json
import redis, psycopg

r = redis.Redis(host=os.getenv("REDIS_HOST", "localhost"), port=6379, decode_responses=True)
PG = f"host={os.getenv('PGHOST','localhost')} user={os.getenv('PGUSER','postgres')} dbname=agentlink " \
     "options='-c search_path=agentlink'"


def hr(t):
    print("\n" + "=" * 70 + f"\n{t}\n" + "=" * 70)


r.flushdb()
print("Redis", r.info("server")["redis_version"])

# ------------------------------------------------------------------ K1
hr("K1. Idempotency key: SET idem:<txn_ref> NX EX 86400")
for attempt in (1, 2, 3):
    ok = r.set("idem:R261104000000777", json.dumps({"status": "PROCESSING"}), nx=True, ex=86400)
    print(f"  attempt {attempt}: SET NX -> {ok}  ->  " + ("process the cash-out" if ok else
          "duplicate retry, return stored result, do NOT debit again"))
print("  TTL idem:R261104000000777 =", r.ttl("idem:R261104000000777"), "seconds")

# ------------------------------------------------------------------ K2
hr("K2. Atomic check-and-increment of an agent's daily cash-out total (Lua)")
LIMIT_LUA = r.register_script("""
local used = tonumber(redis.call('GET', KEYS[1]) or '0')
local amt  = tonumber(ARGV[1])
local lim  = tonumber(ARGV[2])
if used + amt > lim then return {0, tostring(used)} end
local new = redis.call('INCRBYFLOAT', KEYS[1], amt)
redis.call('EXPIREAT', KEYS[1], ARGV[3])
return {1, new}
""")
today = time.strftime("%Y-%m-%d")
key = f"limit:AGL-000057:{today}"
midnight = int(time.mktime(time.strptime(today, "%Y-%m-%d"))) + 86400   # next midnight
results = []
def attempt(i):
    ok, val = LIMIT_LUA(keys=[key], args=[10000, 100000, midnight])
    results.append(ok)
threads = [threading.Thread(target=attempt, args=(i,)) for i in range(20)]
for t in threads: t.start()
for t in threads: t.join()
print(f"  20 concurrent cash-outs of N10,000 against a N100,000 limit")
print(f"  approved: {sum(results)}  rejected: {len(results) - sum(results)}  final total: N{float(r.get(key)):,.0f}")
print(f"  key expires at midnight: TTL {r.ttl(key)} s")
print("  (Redis runs each Lua script atomically on its single command thread, so there is no write skew")
print("   without locks. Compare Portfolio 3 D10, where PostgreSQL needed SERIALIZABLE or a row lock.)")

# ------------------------------------------------------------------ K3
hr("K3. Leaderboard: sorted set of October agent volume (loaded from PostgreSQL)")
with psycopg.connect(PG) as pg:
    rows = pg.execute("""SELECT a.agent_code, sum(t.amount) FROM pos_transaction t JOIN agent a USING (agent_id)
                         WHERE t.status='SUCCESS' AND t.created_at >= '2026-10-01' AND t.created_at < '2026-11-01'
                         GROUP BY a.agent_code""").fetchall()
pipe = r.pipeline()
for code, vol in rows:
    pipe.zadd("lb:volume:2026-10", {code: float(vol)})
pipe.execute()
t0 = time.perf_counter()
top = r.zrevrange("lb:volume:2026-10", 0, 4, withscores=True)
ms = (time.perf_counter() - t0) * 1000
for i, (code, score) in enumerate(top, 1):
    print(f"  #{i}  {code}  N{score:,.0f}")
print(f"  ZREVRANGE top 5 over {r.zcard('lb:volume:2026-10')} agents took {ms:.2f} ms")
r.zincrby("lb:volume:2026-10", 50000, "AGL-000057")
print(f"  live update: ZINCRBY AGL-000057 +50,000 -> rank #{r.zrevrank('lb:volume:2026-10', 'AGL-000057') + 1}")

# ------------------------------------------------------------------ K4
hr("K4. Terminal presence with TTL (heartbeat every 30 s, key lives 2 s in this demo)")
r.set("online:2AGL0057", "battery=81;signal=-71", ex=2)
r.set("online:2AGL0058", "battery=44;signal=-90", ex=2)
print("  online terminals:", sorted(r.scan_iter("online:*")))
time.sleep(1.2); r.expire("online:2AGL0057", 2)   # 2AGL0057 sends a heartbeat, 2AGL0058 goes silent
time.sleep(1.2)
print("  after 2.4 s     :", sorted(r.scan_iter("online:*")), "<- 2AGL0058 expired automatically")

# ------------------------------------------------------------------ K5
hr("K5. Cache-aside: agent profile in front of PostgreSQL")
def get_agent(code):
    t0 = time.perf_counter()
    cached = r.get(f"agent:{code}")
    if cached:
        return json.loads(cached), "HIT ", (time.perf_counter() - t0) * 1000
    with psycopg.connect(PG) as pg:
        row = pg.execute("""SELECT a.agent_code, a.business_name, a.status, a.daily_cashout_limit, l.lga_name
                            FROM agent a JOIN lga l USING (lga_code) WHERE agent_code=%s""", (code,)).fetchone()
    prof = {"code": row[0], "name": row[1], "status": row[2], "limit": str(row[3]), "lga": row[4]}
    r.set(f"agent:{code}", json.dumps(prof), ex=300)
    return prof, "MISS", (time.perf_counter() - t0) * 1000
for _ in range(3):
    p, kind, ms = get_agent("AGL-000057")
    print(f"  {kind} {ms:7.3f} ms  {p}")
print("  invalidate on change: DEL agent:AGL-000057 ->", r.delete("agent:AGL-000057"))

# ------------------------------------------------------------------ K6
hr("K6. Wrong-PIN limiter: 3 attempts per card per 15 minutes")
for i in range(1, 6):
    n = r.incr("pinfail:5061******4469")
    if n == 1:
        r.expire("pinfail:5061******4469", 900)
    print(f"  wrong PIN #{i}: counter={n} ->", "allow retry" if n < 3 else "BLOCK card for 15 min")

# ------------------------------------------------------------------ K7
hr("K7. Redis Stream: completed transactions fan out to independent consumer groups")
for g in ("sms", "fraud"):
    r.xgroup_create("stream:txn", g, id="0", mkstream=True)
for ref, amt in [("R261104000000101", 20000), ("R261104000000102", 95000), ("R261104000000103", 3000)]:
    r.xadd("stream:txn", {"ref": ref, "type": "CASH_OUT", "amount": amt, "agent": "AGL-000057"})
sms = r.xreadgroup("sms", "sms-worker-1", {"stream:txn": ">"}, count=10)
fraud = r.xreadgroup("fraud", "fraud-worker-1", {"stream:txn": ">"}, count=10)
print(f"  sms group received {len(sms[0][1])} events; fraud group received {len(fraud[0][1])} events")
for mid, f in fraud[0][1]:
    flag = "REVIEW (amount >= 90,000)" if int(f["amount"]) >= 90000 else "ok"
    print(f"  fraud-worker-1 {mid} {f['ref']} N{int(f['amount']):,} -> {flag}")
    r.xack("stream:txn", "fraud", mid)
print("  pending (unacknowledged) for sms group:", r.xpending("stream:txn", "sms")["pending"])

hr("Memory")
print("  used_memory_human:", r.info("memory")["used_memory_human"], "| keys:", r.dbsize())
