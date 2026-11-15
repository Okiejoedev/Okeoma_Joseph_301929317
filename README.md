# Joseph Okeoma's Advanced Database Portfolio

### Case study: AgentLink Lagos

**MIT 8103 Advanced Database Systems · Miva Open University · First Semester CA 2026/2027**
**Student:** Joseph Okeoma · **Student ID:** `2026/A/MIT/0790`

## Selected case study

**AgentLink Lagos** is a *simulated* POS agent-banking network operating across the 20 LGAs of Lagos State. Neighbourhood agents use POS terminals to offer cash-out, cash-in, transfers, bill payments and airtime to customers, under licensed super agents who share the commission.

| | |
|---|---|
| **Users of the database** | Agents (POS app), customers (wallet app/USSD), super agents, operations & reconciliation staff, dispute officers, compliance/audit |
| **Major data** | LGAs, super agents, agents, terminals, customers (hashed BVN), wallets, transaction types, fee bands, POS transactions, double-entry ledger, commissions, disputes, receipts, terminal telemetry |
| **Key operations** | Cash-out / cash-in / transfer / bill pay / airtime, fee and commission calculation, daily cash-out limits, reversals, wallet reconciliation, dispute handling, management reporting |
| **Dataset** | Synthetic and reproducible: 3,000 agents, 80,000 customers, **1,209,721 transactions** (May–Oct 2026), **3,223,039 ledger rows** |

All names, phone numbers and businesses are fictitious. No real customer data is used.

## Repository structure

```
joseph-okeoma-advanced-database-portfolio/
├── portfolio-1-database-design/        ER diagram, schema, constraints, normalisation, data generator
├── portfolio-2-query-optimisation/     9 queries, EXPLAIN ANALYZE before/after, indexes, rewrites, chart
├── portfolio-3-transactions-concurrency/ PL/pgSQL transactions + 12 concurrency scenarios
├── portfolio-4-nosql/                  MongoDB document model + Redis key-value model
├── portfolio-5-distributed-cloud/      PG replication & failover, partitioning, Mongo replica set & sharding, cloud design
├── docs/                               evidence screenshots, AI-use declaration, references
├── scripts/start_servers.sh            start PostgreSQL, MongoDB and Redis (Ubuntu / WSL2)
├── rebuild.sh                          recreate the PostgreSQL database from scratch
├── docker-compose.yml                  optional: PostgreSQL 16 + MongoDB 8 + Redis 7 for portfolios 1-4
└── requirements.txt
```

Each portfolio folder has its own `README.md` explaining what was built, how it was tested, the results, and the analysis.

## Results at a glance

| Portfolio | Headline evidence |
|---|---|
| 1 Design | 12 tables in BCNF. 10/10 constraint-violation tests rejected. Deferred double-entry trigger. **0** unbalanced transactions, **0** wallet mismatches |
| 2 Optimisation | Lookup queries **115–256 ms → 0.03–9 ms** (28×–3,600×). NOT IN null bug found (0 vs 18,001 rows). Materialized view 330 → 3 ms. Index write cost measured (1.18×) |
| 3 Transactions | Lost update reproduced (₦45,000 instead of ₦35,000) and fixed 3 ways. Write skew broke a ₦100k limit under REPEATABLE READ and was stopped by SERIALIZABLE. Deadlock 40P01 and its prevention |
| 4 NoSQL | Polymorphic receipts with `$jsonSchema`. COLLSCAN 204,046 docs → IXSCAN 6 docs. Time-series + TTL. Redis atomic limit: exactly 10 of 20 concurrent requests approved |
| 5 Distributed | Sync vs async replication (CAP shown live). PG failover 0.14 s with no lost commit. Mongo election ~10 s with 95/95 writes OK. Zone sharding: targeted vs scatter-gather. Design aligned with CBN 2027 data-localisation rule |

## How to reproduce

**Tested with:** PostgreSQL 16.15, MongoDB 8.3.7 (mongosh 2.14.1), Redis 7.0.15, Python 3.13 (`pip install -r requirements.txt`), Ubuntu 24.04.

```bash
# Portfolios 1-4 (either native installs or: docker compose up -d)
./rebuild.sh                                                      # P1: schema + 1.2M-row dataset (~2.5 min)
psql -h localhost -U postgres -d agentlink -f portfolio-1-database-design/04_constraint_tests.sql
python3 portfolio-2-query-optimisation/benchmark.py               # P2
psql -h localhost -U postgres -d agentlink -f portfolio-3-transactions-concurrency/procedures.sql
python3 portfolio-3-transactions-concurrency/demos.py             # P3
python3 portfolio-4-nosql/load_mongo.py && mongosh agentlink portfolio-4-nosql/mongo_queries.js
python3 portfolio-4-nosql/redis_demo.py                            # P4
# Portfolio 5 starts its own extra server processes; see portfolio-5-distributed-cloud/README.md
```

The evidence in this repository was produced with native server binaries on Linux. `docker-compose.yml` is provided as a convenient way to get the same versions on another machine.

## AI use and references

See [`docs/AI_USE_DECLARATION.md`](docs/AI_USE_DECLARATION.md) and [`docs/REFERENCES.md`](docs/REFERENCES.md).
