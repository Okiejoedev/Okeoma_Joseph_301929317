"""
Portfolio 5 (part D): MongoDB sharded cluster with ZONE sharding by Lagos region.

  config server RS  cfgRS        :27030
  shard 1 RS        shMainland   :27031   zone MAINLAND (16 LGAs)
  shard 2 RS        shIsland     :27032   zone ISLAND   (Eti-Osa, Lagos Island, Ibeju-Lekki, Epe)
  router            mongos       :27040

Shard key: { "agent.lga": 1, "_id": 1 }  - LGA first (locality), txn_ref second (cardinality)
Demonstrates: data distribution by zone, targeted vs scatter-gather queries, chunk metadata.
Run: python3 04_mongo_sharding.py > evidence_mongo_sharding.txt
"""
import os, shutil, subprocess, time
from pymongo import MongoClient
from bson.min_key import MinKey
from bson.max_key import MaxKey

BIN = os.path.dirname(os.getenv("MONGOD", "/opt/mongoenv/bin/mongod"))
BASE = "/srv/mongo/shard"
procs = []


def hr(t):
    print("\n" + "=" * 70 + f"\n{t}\n" + "=" * 70, flush=True)


def mongod(name, port, role):
    d = f"{BASE}/{name}"; shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    procs.append(subprocess.Popen([f"{BIN}/mongod", role, "--replSet", name, "--port", str(port),
                                   "--bind_ip", "127.0.0.1", "--dbpath", d, "--wiredTigerCacheSizeGB", "0.25",
                                   "--logpath", f"{d}.log"], stdout=subprocess.DEVNULL))


def init_rs(name, port, cfg=False):
    c = MongoClient(f"mongodb://127.0.0.1:{port}", directConnection=True)
    conf = {"_id": name, "members": [{"_id": 0, "host": f"127.0.0.1:{port}"}]}
    if cfg:
        conf["configsvr"] = True
    c.admin.command("replSetInitiate", conf)
    while not c.admin.command("hello").get("isWritablePrimary"):
        time.sleep(0.3)


hr("Z1. Start config server, two shard replica sets and the mongos router")
mongod("cfgRS", 27030, "--configsvr"); mongod("shMainland", 27031, "--shardsvr"); mongod("shIsland", 27032, "--shardsvr")
time.sleep(3)
init_rs("cfgRS", 27030, cfg=True); init_rs("shMainland", 27031); init_rs("shIsland", 27032)
procs.append(subprocess.Popen([f"{BIN}/mongos", "--configdb", "cfgRS/127.0.0.1:27030", "--port", "27040",
                               "--bind_ip", "127.0.0.1", "--logpath", f"{BASE}/mongos.log"], stdout=subprocess.DEVNULL))
time.sleep(4)
router = MongoClient("mongodb://127.0.0.1:27040")
adm = router.admin
adm.command("addShard", "shMainland/127.0.0.1:27031", name="shMainland")
adm.command("addShard", "shIsland/127.0.0.1:27032", name="shIsland")
print("shards:", [s["_id"] + " @ " + s["host"] for s in adm.command("listShards")["shards"]])

hr("Z2. Zones: Lagos Island LGAs -> shIsland, the rest -> shMainland")
adm.command("addShardToZone", "shMainland", zone="MAINLAND")
adm.command("addShardToZone", "shIsland", zone="ISLAND")
ns = "agentlink.transactions"
ranges = [  # LGA codes sorted: ... BAD | EPE ETI IBL | IFA ... KOS | LIS | LMA ... SUR
    ({"agent.lga": MinKey(), "_id": MinKey()}, {"agent.lga": "EPE", "_id": MinKey()}, "MAINLAND"),
    ({"agent.lga": "EPE", "_id": MinKey()},    {"agent.lga": "IFA", "_id": MinKey()}, "ISLAND"),
    ({"agent.lga": "IFA", "_id": MinKey()},    {"agent.lga": "LIS", "_id": MinKey()}, "MAINLAND"),
    ({"agent.lga": "LIS", "_id": MinKey()},    {"agent.lga": "LMA", "_id": MinKey()}, "ISLAND"),
    ({"agent.lga": "LMA", "_id": MinKey()},    {"agent.lga": MaxKey(), "_id": MaxKey()}, "MAINLAND")]
for lo, hi, z in ranges:
    adm.command("updateZoneKeyRange", ns, min=lo, max=hi, zone=z)
    print(f"  {z:9} [{lo['agent.lga'] if isinstance(lo['agent.lga'], str) else 'MinKey'}, "
          f"{hi['agent.lga'] if isinstance(hi['agent.lga'], str) else 'MaxKey'})")

hr("Z3. Shard the collection on {agent.lga: 1, _id: 1} and load 204,046 October receipts")
adm.command("enableSharding", "agentlink")
adm.command("shardCollection", ns, key={"agent.lga": 1, "_id": 1})
src = MongoClient("mongodb://127.0.0.1:27017").agentlink.transactions
t = time.perf_counter(); batch = []; n = 0
for d in src.find({}):
    batch.append(d)
    if len(batch) == 5000:
        router.agentlink.transactions.insert_many(batch, ordered=False); n += len(batch); batch = []
if batch:
    router.agentlink.transactions.insert_many(batch, ordered=False); n += len(batch)
print(f"  inserted {n} documents through mongos in {time.perf_counter() - t:.1f}s")

hr("Z4. Where did the data go? (counted directly on each shard)")
island_lgas = ["EPE", "ETI", "IBL", "LIS"]
for name, port in (("shMainland", 27031), ("shIsland", 27032)):
    c = MongoClient(f"mongodb://127.0.0.1:{port}", directConnection=True).agentlink.transactions
    lgas = sorted(c.distinct("agent.lga"))
    print(f"  {name:11} {c.estimated_document_count():>7} docs | LGAs: {', '.join(lgas)}")
chunks = router.config.chunks.aggregate([{"$group": {"_id": "$shard", "chunks": {"$sum": 1}}}])
print("  chunks per shard:", {c["_id"]: c["chunks"] for c in chunks})

hr("Z5. Query routing: TARGETED vs SCATTER-GATHER (explain through mongos)")
def route(filt, label):
    ex = router.agentlink.command("explain", {"find": "transactions", "filter": filt}, verbosity="executionStats")
    wp = ex["queryPlanner"]["winningPlan"]
    shards = [s["shardName"] for s in wp.get("shards", [])]
    print(f"  {label}\n     stage={wp['stage']}  shards={shards}  nReturned={ex['executionStats']['nReturned']}  "
          f"time={ex['executionStats']['executionTimeMillis']}ms")
route({"agent.lga": "ETI", "status": "FAILED"}, "Failed txns in Eti-Osa (filter includes shard-key prefix):")
ref = src.find_one({"agent.lga": "IKJ"}, {"_id": 1})["_id"]
route({"agent.lga": "IKJ", "_id": ref}, f"One receipt with full shard key (IKJ + {ref}):")
route({"customer.id": 1234}, "Customer 1234's receipts (no shard key -> must ask every shard):")

hr("Z6. Cluster-wide aggregation is split across shards and merged by mongos")
ex = router.agentlink.command("explain", {"aggregate": "transactions", "pipeline": [
    {"$match": {"status": "SUCCESS"}}, {"$group": {"_id": "$agent.lga", "v": {"$sum": "$amount"}}}],
    "cursor": {}}, verbosity="queryPlanner")
print("  mergeType:", ex.get("mergeType"), "| shards involved:", list(ex.get("shards", {}).keys()))
print("  split pipeline -> shardsPart:", [list(s.keys())[0] for s in ex["splitPipeline"]["shardsPart"]],
      "mergerPart:", [list(s.keys())[0] for s in ex["splitPipeline"]["mergerPart"]])

hr("Shutdown")
for p in reversed(procs):
    p.terminate(); p.wait()
print("  cluster stopped")
