# Portfolio 4: NoSQL and Advanced Data Models

Same case study, different data models. The **PostgreSQL ledger stays the system of record** (Portfolio 1–3). MongoDB and Redis take the workloads that the relational model handles awkwardly or too slowly. This design is called *polyglot persistence*.

```
 POS terminal ──► API ──► Redis (idempotency, daily-limit counter, presence, cache, event stream)
                   │
                   ├──► PostgreSQL  (ACID ledger, wallets, reversals)  ← source of truth
                   │
                   └──► MongoDB    (receipt documents, agent profiles, terminal telemetry time-series)
```

## Files

| File | Purpose |
|---|---|
| `load_mongo.py` | Builds 4 MongoDB collections from PostgreSQL (3,001 agents, 204,046 October receipts, 33,600 heartbeats) |
| `mongo_queries.js` → `evidence_mongo.txt` | M1–M10: embedding, polymorphism, `$jsonSchema`, explain before/after index, aggregation, `$lookup`, time-series, TTL |
| `redis_demo.py` → `evidence_redis.txt` | K1–K7: idempotency, atomic Lua limit check, leaderboard, TTL presence, cache-aside, rate limit, streams |

Run: `python3 load_mongo.py && mongosh --quiet agentlink mongo_queries.js > evidence_mongo.txt && python3 redis_demo.py > evidence_redis.txt` (tested on MongoDB 8.3.7, mongosh 2.14.1, Redis 7.0.15)

## 1. Document model (MongoDB)

**Design decisions**

| Decision | Reason |
|---|---|
| `agents` **embeds** terminals, LGA and super-agent | An agent has 1–2 terminals (*one-to-few*), and they are always read together. One `findOne` replaces a 4-table join (M1). |
| `transactions` keeps a **reference + copied snapshot** of the agent (`code, name, lga`) | Receipts and LGA reports need only these fields, so M5 groups by LGA with **no `$lookup`**. The full agent is still reachable when needed (M7 uses `$lookup`). The snapshot is historical, like `pos_transaction.agent_id` in P1. |
| **Polymorphic** receipts: `card`, `beneficiary`, `bill`, `topup` sub-documents | Each transaction type carries different fields (card STAN/auth code, NIP session ID, electricity token and kWh, network/MSISDN). In SQL this means many NULL columns or 4 extra subtype tables. Here, one collection holds every shape (M2) and can be queried on type-specific fields (M6). |
| `$jsonSchema` validator | "Schemaless" should not mean "no rules": the wrong `type` and the negative `amount` were **rejected** (M3). |
| `Decimal128` for money | Same reason as `NUMERIC` in SQL: exact Naira and kobo. |
| `_id` = `txn_ref` | The POS reference number is the natural key, so an insert retried by the POS fails as a duplicate. |

**Index evidence (M4, `explain("executionStats")`)**

| | Plan | Docs examined | Time |
|---|---|---:|---:|
| Before | `SORT ← COLLSCAN` | 204,046 | 187 ms |
| After `{customer.id:1, created_at:-1}` | `LIMIT ← FETCH ← IXSCAN` | 6 | 2 ms |

The same lesson as Portfolio 2: the compound index matches both the filter and the sort order.

**Time-series and TTL.** The `terminal_heartbeats` collection uses MongoDB's time-series storage: 33,600 measurements are stored in **200 buckets** (one per terminal), which makes "hourly average signal per terminal" (M8) cheap. A TTL index deletes OTP documents 120 s after creation with no cron job; the evidence file shows the count dropping from 1 to 0.

Storage: 204,046 receipts take 79.0 MB of BSON but **27.3 MB on disk** (WiredTiger compression).

## 2. Key-value model (Redis)

| Use | Redis feature | Result (`evidence_redis.txt`) |
|---|---|---|
| Drop duplicate POS retries before they reach the ledger | `SET key NX EX 86400` | 1st attempt `True`, retries `None` |
| Agent daily cash-out limit | Lua script (atomic read-check-increment) | 20 concurrent ₦10k requests vs ₦100k limit → **exactly 10 approved**, total ₦100,000 |
| Top agents | Sorted set | Top 5 of 3,000 agents in **0.53 ms**; live `ZINCRBY` updates the rank |
| Is a terminal online? | Key with TTL | Silent terminal disappeared after 2 s without any cleanup code |
| Agent profile | Cache-aside | MISS 8.9 ms (includes opening a PostgreSQL connection) → HIT **0.09–0.12 ms** |
| Wrong-PIN protection | `INCR` + `EXPIRE` | Blocks on the 3rd wrong PIN for 15 min |
| Notify SMS and fraud services | Stream + consumer groups | Each group got all 3 events independently; ₦95,000 flagged for review |

Note on K2 vs Portfolio 3 D10: Redis runs a Lua script as one atomic step on a single thread, so the read-check-write race cannot happen. The trade-off is that Redis is not the durable ledger. If Redis restarts, the counter has to be rebuilt from PostgreSQL (query Q3 in Portfolio 2, now 0.03 ms).

## 3. Graph and column-family models (design only, not implemented)

* **Graph (e.g., Neo4j)** for fraud rings: `(:Customer)-[:USED_CARD]->(:Card)<-[:USED_CARD]-(:Customer)` and `(:Customer)-[:TRANSACTED_AT]->(:Terminal)`. A query such as "customers within 3 hops of a known fraudster through shared cards or terminals" is a short Cypher `MATCH` pattern. In SQL it needs recursive self-joins that grow quickly with depth (course Study Session 5, graph databases).
* **Wide-column (e.g., Cassandra)** would suit national-scale telemetry: partition key `(terminal_id, day)`, clustering key `ts`. It gives fast writes across many nodes with tunable consistency. At AgentLink's scale, MongoDB's time-series collection already covers this need.

## 4. Suitability: which store for which data?

| Data | Store | Why |
|---|---|---|
| Wallet balances, ledger, reversals | **PostgreSQL** | Needs multi-row ACID transactions, constraints, and serializable correctness (P3). Money must never be "eventually" right. |
| Receipts, agent profiles, telemetry | **MongoDB** | Flexible, varied shapes. Read as whole units. Scales out by sharding (P5). Brief staleness is acceptable. |
| Counters, sessions, idempotency, rankings | **Redis** | Sub-millisecond, in-memory, built-in expiry. The data is temporary or can be rebuilt. |

The main trade-off: every extra store adds an integration and consistency cost. MongoDB receipts are copies of committed PostgreSQL rows, so they can lag slightly behind (BASE-style eventual consistency). That is acceptable for receipts and reports but **not** for balances, which is why balances are never read from MongoDB.
