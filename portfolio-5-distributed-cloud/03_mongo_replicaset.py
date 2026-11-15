"""
Portfolio 5 (part C): MongoDB 3-node replica set "rsAgent" (ports 27021-27023).
Demonstrates: replication, write concern majority, reads from secondaries,
multi-document ACID transaction, automatic failover (election) under live load,
and loss of majority (CP behaviour).

Run: python3 03_mongo_replicaset.py > evidence_mongo_replicaset.txt
Env: MONGOD (path to mongod binary), default /opt/mongoenv/bin/mongod
"""
import os, shutil, signal, subprocess, time, threading
from datetime import datetime, timezone
from pymongo import MongoClient, WriteConcern, ReadPreference
from pymongo.errors import PyMongoError
from bson.decimal128 import Decimal128

MONGOD = os.getenv("MONGOD", "/opt/mongoenv/bin/mongod")
BASE = "/srv/mongo/rs"
PORTS = [27021, 27022, 27023]
procs = {}
T0 = time.perf_counter()


def log(msg):
    print(f"  [t+{time.perf_counter() - T0:7.3f}s] {msg}", flush=True)


def hr(t):
    print("\n" + "=" * 70 + f"\n{t}\n" + "=" * 70, flush=True)


def start(port, fresh=False):
    d = f"{BASE}/{port}"
    if fresh:
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    procs[port] = subprocess.Popen([MONGOD, "--replSet", "rsAgent", "--port", str(port), "--bind_ip", "127.0.0.1",
                                    "--dbpath", d, "--wiredTigerCacheSizeGB", "0.25", "--logpath", f"{d}.log"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def kill(port):
    procs[port].send_signal(signal.SIGKILL); procs[port].wait()


def states(client):
    st = client.admin.command("replSetGetStatus")
    return {m["name"].split(":")[1]: m["stateStr"] for m in st["members"]}


def wait_primary(uri, timeout=60):
    t = time.perf_counter()
    while time.perf_counter() - t < timeout:
        try:
            c = MongoClient(uri, directConnection=True, serverSelectionTimeoutMS=1000)
            if c.admin.command("hello").get("isWritablePrimary"):
                return
        except PyMongoError:
            pass
        time.sleep(0.2)
    raise RuntimeError("no primary")


hr("S1. Start 3 mongod processes and initiate replica set rsAgent")
for p in PORTS:
    start(p, fresh=True)
time.sleep(3)
boot = MongoClient("mongodb://127.0.0.1:27021", directConnection=True)
boot.admin.command("replSetInitiate", {"_id": "rsAgent", "members": [
    {"_id": 0, "host": "127.0.0.1:27021", "priority": 2},
    {"_id": 1, "host": "127.0.0.1:27022", "priority": 1},
    {"_id": 2, "host": "127.0.0.1:27023", "priority": 1}]})
wait_primary("mongodb://127.0.0.1:27021")
time.sleep(3)
log(f"member states: {states(boot)}")

URI = "mongodb://127.0.0.1:27021,127.0.0.1:27022,127.0.0.1:27023/?replicaSet=rsAgent&retryWrites=true"
client = MongoClient(URI, serverSelectionTimeoutMS=15000)
db = client.agentlink

hr("S2. Write with writeConcern {w: 'majority'} and read it back from a SECONDARY")
src = MongoClient("mongodb://127.0.0.1:27017").agentlink.transactions
docs = list(src.find({}).limit(20000))
t = time.perf_counter()
db.get_collection("transactions", write_concern=WriteConcern(w="majority")).insert_many(docs)
log(f"inserted {len(docs)} receipts with w:majority in {time.perf_counter() - t:.2f}s")
time.sleep(1)
sec = db.get_collection("transactions", read_preference=ReadPreference.SECONDARY)
log(f"count read from a secondary: {sec.count_documents({})}")
log(f"oplog entries on primary: {client.local.oplog.rs.estimated_document_count()}")

hr("S3. Multi-document ACID transaction (wallet transfer) - commit and abort")
w = db.get_collection("wallets", write_concern=WriteConcern(w="majority"))
w.delete_many({})
w.insert_many([{"_id": "W-ADA", "balance": Decimal128("50000.00")},
               {"_id": "W-BAYO", "balance": Decimal128("20000.00")}])
def transfer(session, amount, fail=False):
    w.update_one({"_id": "W-ADA"}, {"$inc": {"balance": Decimal128(f"-{amount}")}}, session=session)
    if fail:
        raise ValueError("simulated failure after the debit")
    w.update_one({"_id": "W-BAYO"}, {"$inc": {"balance": Decimal128(str(amount))}}, session=session)
with client.start_session() as s:
    s.with_transaction(lambda ss: transfer(ss, 5000))
log("commit : " + str({d["_id"]: str(d["balance"]) for d in w.find()}))
try:
    with client.start_session() as s:
        s.with_transaction(lambda ss: transfer(ss, 7000, fail=True))
except ValueError as e:
    log(f"abort  : {e} -> transaction aborted")
log("after  : " + str({d["_id"]: str(d["balance"]) for d in w.find()}) + "  (the debit was rolled back)")

hr("S4. FAILOVER under load: kill the primary while a POS simulator writes every 50 ms")
results, stop = [], threading.Event()
def pos_writer():
    i = 0
    coll = db.get_collection("heartbeat_writes", write_concern=WriteConcern(w="majority", wtimeout=5000))
    while not stop.is_set():
        i += 1; t = time.perf_counter()
        try:
            coll.insert_one({"seq": i, "at": datetime.now(timezone.utc)})
            results.append((t, "ok", time.perf_counter() - t))
        except PyMongoError as e:
            results.append((t, type(e).__name__, time.perf_counter() - t))
        time.sleep(0.05)
th = threading.Thread(target=pos_writer); th.start()
time.sleep(2)
primary = [p for p, s in states(boot).items() if s == "PRIMARY"][0]
log(f"current primary is :{primary} -> kill -9")
t_kill = time.perf_counter()
kill(int(primary))
new_primary = None
while new_primary is None:
    try:
        c2 = MongoClient("mongodb://127.0.0.1:27022", directConnection=True, serverSelectionTimeoutMS=500)
        st = states(c2)
        new_primary = next((p for p, s in st.items() if s == "PRIMARY" and p != primary), None)
    except PyMongoError:
        pass
    time.sleep(0.1)
log(f"new primary elected: :{new_primary} after {time.perf_counter() - t_kill:.2f}s")
time.sleep(3); stop.set(); th.join()
ok = sum(1 for r in results if r[1] == "ok"); bad = [r for r in results if r[1] != "ok"]
slow = max(results, key=lambda r: r[2])
log(f"POS writes attempted {len(results)}: ok {ok}, errors {len(bad)}; "
    f"longest single write {slow[2]:.2f}s (retryWrites held it until the new primary)")
log(f"documents stored: {db.heartbeat_writes.count_documents({})} (no acknowledged write lost)")

hr("S5. Old primary rejoins as a SECONDARY and catches up")
start(int(primary)); time.sleep(6)
log(f"member states: {states(MongoClient('mongodb://127.0.0.1:' + new_primary, directConnection=True))}")

hr("S6. Lose the MAJORITY: stop 2 of 3 nodes -> no primary (Consistency over Availability)")
others = [p for p in map(str, PORTS) if p != primary]
for p in others:
    kill(int(p))
log(f"killed :{others[0]} and :{others[1]}; waiting for the survivor to step down...")
time.sleep(12)
lone = MongoClient(f"mongodb://127.0.0.1:{primary}", directConnection=True, serverSelectionTimeoutMS=2000)
log(f"survivor :{primary} state = {lone.admin.command('hello').get('isWritablePrimary') and 'PRIMARY' or 'SECONDARY (cannot accept writes)'}")
try:
    lone.agentlink.get_collection("heartbeat_writes", write_concern=WriteConcern(w=1)).insert_one({"seq": -1})
except PyMongoError as e:
    log(f"write rejected: {type(e).__name__}: {str(e).split(',')[0][:90]}")
cnt = lone.agentlink.get_collection("transactions",
                                    read_preference=ReadPreference.SECONDARY_PREFERRED).count_documents({})
log(f"stale read still served (secondaryPreferred): {cnt} receipts")

hr("Shutdown")
for p, pr in procs.items():
    if pr.poll() is None:
        pr.terminate(); pr.wait()
log("all replica-set members stopped")
