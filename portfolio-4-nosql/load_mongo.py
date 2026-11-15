"""
Portfolio 4: build the AgentLink MongoDB document model from the PostgreSQL data.

Collections
  agents              - agent + embedded terminals, super-agent and LGA snapshot
  transactions        - one self-contained receipt per POS transaction (October 2026),
                        with type-specific sub-documents (polymorphic schema)
  terminal_heartbeats - TIME-SERIES collection of POS telemetry (battery, signal, GPS)
  otp_sessions        - short-lived OTPs, auto-deleted by a TTL index

Usage: python3 load_mongo.py      (env: PGHOST, MONGO_URI)
"""
import os, random, hashlib
from datetime import datetime, timedelta, timezone
import psycopg
from pymongo import MongoClient, ASCENDING, DESCENDING
from bson.decimal128 import Decimal128

PG = f"host={os.getenv('PGHOST','localhost')} user={os.getenv('PGUSER','postgres')} dbname=agentlink"
MONGO = os.getenv("MONGO_URI", "mongodb://localhost:27017")
rnd = random.Random(8103)
D = lambda x: Decimal128(str(x))          # exact decimal for money (never float)

BILLERS = [("Ikeja Electric", "electricity"), ("Eko Electricity", "electricity"),
           ("DStv", "cable_tv"), ("GOtv", "cable_tv"), ("StarTimes", "cable_tv")]
NETWORKS = ["MTN", "Airtel", "Glo", "9mobile"]
BANKS = ["Access Bank", "GTBank", "First Bank", "UBA", "Zenith Bank", "Opay", "Moniepoint MFB", "Kuda MFB"]
SCHEMES = ["Verve", "Mastercard", "Visa"]


def details(type_code, txn_id, amount):
    """Type-specific fields: in SQL these would be sparse NULL columns or 4 subtype tables."""
    h = int(hashlib.md5(str(txn_id).encode()).hexdigest(), 16)
    if type_code == "CASH_OUT":
        return {"card": {"scheme": SCHEMES[h % 3], "pan_masked": f"5061******{h % 10000:04d}",
                         "stan": f"{h % 1000000:06d}", "auth_code": f"{h % 999999:06d}"}}
    if type_code == "TRANSFER":
        return {"beneficiary": {"bank": BANKS[h % len(BANKS)], "account_masked": f"******{h % 10000:04d}",
                                "nip_session_id": f"{h % 10**30:030d}"}}
    if type_code == "BILL_PAY":
        name, cat = BILLERS[h % len(BILLERS)]
        b = {"biller": name, "category": cat}
        if cat == "electricity":
            b |= {"meter_no": f"{h % 10**11:011d}", "token": "-".join(f"{(h >> i) % 10000:04d}" for i in range(0, 20, 4)),
                  "units_kwh": round(float(amount) / 209.5, 1)}
        else:
            b |= {"smartcard_no": f"{h % 10**10:010d}", "bouquet": ["Compact", "Basic", "Jolli", "Nova"][h % 4]}
        return {"bill": b}
    if type_code == "AIRTIME":
        return {"topup": {"network": NETWORKS[h % 4], "msisdn": f"080{h % 10**8:08d}",
                          "product": "data" if h % 3 == 0 else "airtime"}}
    if type_code == "CASH_IN":
        return {"deposit": {"destination": "wallet" if h % 4 else "bank_account"}}
    return {}


def main():
    mc = MongoClient(MONGO)
    db = mc["agentlink"]
    for c in ("agents", "transactions", "terminal_heartbeats", "otp_sessions"):
        db.drop_collection(c)

    with psycopg.connect(PG, options="-c search_path=agentlink") as pg:
        # ---------------- agents (embedding: 1-to-few terminals) ----------------
        agents = {}
        for r in pg.execute("""SELECT a.agent_id, a.agent_code, a.business_name, a.owner_name, a.phone, a.tier,
                                      a.status, a.daily_cashout_limit, a.onboarded_on, l.lga_code, l.lga_name,
                                      s.super_agent_id, s.name, s.commission_share
                               FROM agent a JOIN lga l USING (lga_code) JOIN super_agent s USING (super_agent_id)"""):
            agents[r[0]] = {"_id": r[1], "agent_id": r[0], "business_name": r[2], "owner": r[3], "phone": r[4],
                            "tier": r[5], "status": r[6], "daily_cashout_limit": D(r[7]),
                            "onboarded_on": datetime(r[8].year, r[8].month, r[8].day, tzinfo=timezone.utc),
                            "lga": {"code": r[9], "name": r[10]},
                            "super_agent": {"id": r[11], "name": r[12], "share": D(r[13])},
                            "terminals": []}
        for tid, serial, model, aid, status, assigned in pg.execute(
                "SELECT terminal_id, serial_no, model, agent_id, status, assigned_on FROM terminal WHERE agent_id IS NOT NULL"):
            agents[aid]["terminals"].append({"terminal_id": tid, "serial_no": serial, "model": model, "status": status})
        db.agents.insert_many(list(agents.values()))

        # ---------------- transactions: October 2026 receipts ----------------
        db.create_collection("transactions", validator={"$jsonSchema": {
            "bsonType": "object",
            "required": ["_id", "type", "amount", "fee", "status", "created_at", "agent", "terminal_id"],
            "properties": {
                "_id":    {"bsonType": "string", "pattern": "^[RVX][0-9A-Z]{6,19}$", "description": "txn_ref"},
                "type":   {"enum": ["CASH_OUT", "CASH_IN", "TRANSFER", "BILL_PAY", "AIRTIME", "REVERSAL"]},
                "amount": {"bsonType": "decimal", "minimum": 0, "exclusiveMinimum": True},
                "fee":    {"bsonType": "decimal", "minimum": 0},
                "status": {"enum": ["PENDING", "SUCCESS", "FAILED", "REVERSED"]},
                "created_at": {"bsonType": "date"},
                "agent":  {"bsonType": "object", "required": ["code", "lga"]},
                "customer": {"bsonType": ["object", "null"]}}}},
            validationAction="error")
        batch, n = [], 0
        cur = pg.execute("""SELECT t.txn_id, t.txn_ref, t.type_code, t.amount, t.fee, t.status, t.created_at,
                                   t.terminal_id, t.agent_id, t.customer_id, c.first_name, c.phone, t.reversal_of
                            FROM pos_transaction t LEFT JOIN customer c USING (customer_id)
                            WHERE t.created_at >= '2026-10-01' AND t.created_at < '2026-11-01'""")
        for (tid, ref, typ, amt, fee, st, ts, term, aid, cid, cname, cphone, rev) in cur:
            a = agents[aid]
            doc = {"_id": ref, "txn_id": tid, "type": typ, "amount": D(amt), "fee": D(fee), "status": st,
                   "created_at": ts, "terminal_id": term,
                   # extended reference: copy the few agent fields that receipts and reports need
                   "agent": {"code": a["_id"], "name": a["business_name"], "lga": a["lga"]["code"]},
                   "customer": {"id": cid, "first_name": cname, "phone": cphone} if cid else None}
            doc |= details(typ, tid, amt)
            if rev:
                doc["reversal_of"] = rev
            batch.append(doc)
            if len(batch) == 10000:
                db.transactions.insert_many(batch); n += len(batch); batch = []
        if batch:
            db.transactions.insert_many(batch); n += len(batch)

    # ---------------- time-series telemetry (bucketed storage) ----------------
    db.create_collection("terminal_heartbeats",
                         timeseries={"timeField": "ts", "metaField": "terminal", "granularity": "minutes"})
    start = datetime(2026, 10, 31, 7, 0, tzinfo=timezone.utc)
    hb = []
    for aid in range(1, 201):                     # 200 terminals, one heartbeat every 5 minutes for 14 hours
        lat, lon = 6.45 + rnd.random() * 0.2, 3.25 + rnd.random() * 0.4
        battery = 100
        for k in range(0, 14 * 12):
            battery = max(5, battery - rnd.choice([0, 0, 1, 1, 2]))
            hb.append({"ts": start + timedelta(minutes=5 * k),
                       "terminal": {"id": f"2AGL{aid:04d}", "model": "PAX S90"},
                       "battery_pct": battery, "signal_dbm": -60 - rnd.randint(0, 45),
                       "network": rnd.choice(NETWORKS), "loc": {"type": "Point", "coordinates": [lon, lat]}})
    db.terminal_heartbeats.insert_many(hb)

    # ---------------- TTL collection ----------------
    db.otp_sessions.create_index("created_at", expireAfterSeconds=120)

    print(f"agents: {db.agents.count_documents({})}, transactions: {n}, "
          f"heartbeats: {db.terminal_heartbeats.count_documents({})}")


if __name__ == "__main__":
    main()
