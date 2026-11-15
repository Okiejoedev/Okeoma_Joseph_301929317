// =====================================================================
// Portfolio 4: MongoDB queries for AgentLink Lagos
// Run:  mongosh --quiet agentlink mongo_queries.js > evidence_mongo.txt
// =====================================================================
const hr = (t) => print("\n" + "=".repeat(70) + "\n" + t + "\n" + "=".repeat(70));
const show = (x) => printjson(x);

hr("M1. One read returns an agent with its terminals, LGA and super agent (no JOIN)");
show(db.agents.findOne({ _id: "AGL-000057" }, { business_name: 1, lga: 1, super_agent: 1, terminals: 1, tier: 1 }));

hr("M2. Polymorphic documents: one collection, a different shape per transaction type");
["CASH_OUT", "TRANSFER", "BILL_PAY", "AIRTIME"].forEach(t =>
  show(db.transactions.findOne({ type: t, status: "SUCCESS" },
       { _id: 1, type: 1, amount: 1, fee: 1, card: 1, beneficiary: 1, bill: 1, topup: 1 })));

hr("M3. Schema validation ($jsonSchema): invalid receipt is rejected");
try {
  db.transactions.insertOne({ _id: "R261031BAD", type: "LOAN", amount: NumberDecimal("-5"),
                              fee: NumberDecimal("0"), status: "SUCCESS", created_at: new Date(),
                              agent: { code: "AGL-000001", lga: "IKJ" }, terminal_id: "2AGL0001" });
} catch (e) {
  print("REJECTED: " + e.errmsg);
  const d = e.errInfo && e.errInfo.details && e.errInfo.details.schemaRulesNotSatisfied;
  if (d) d.forEach(r => (r.propertiesNotSatisfied || []).forEach(p =>
           print("   - property '" + p.propertyName + "': " + JSON.stringify(p.details[0].reason || p.details[0].operatorName))));
}

hr("M4. Index tuning: customer mini-statement, BEFORE index (COLLSCAN)");
db.transactions.dropIndexes();
let q = { "customer.id": 1234 };
let ex = db.transactions.find(q).sort({ created_at: -1 }).limit(20).explain("executionStats");
const chain = (p) => p ? [p.stage].concat(chain(p.inputStage)) : [];
const summary = (ex) => ({
  plan: chain(ex.queryPlanner.winningPlan.queryPlan || ex.queryPlanner.winningPlan).join(" <- "),
  nReturned: ex.executionStats.nReturned,
  totalKeysExamined: ex.executionStats.totalKeysExamined,
  totalDocsExamined: ex.executionStats.totalDocsExamined,
  executionTimeMillis: ex.executionStats.executionTimeMillis });
show(summary(ex));

hr("M4b. AFTER compound index {customer.id: 1, created_at: -1} (IXSCAN, no in-memory SORT)");
db.transactions.createIndex({ "customer.id": 1, created_at: -1 }, { name: "cust_time" });
ex = db.transactions.find(q).sort({ created_at: -1 }).limit(20).explain("executionStats");
show(summary(ex));

hr("M5. Aggregation: October SUCCESS volume by LGA (agent LGA is embedded -> no $lookup)");
db.transactions.createIndex({ status: 1, "agent.lga": 1, amount: 1 }, { name: "status_lga_amount" });
show(db.transactions.aggregate([
  { $match: { status: "SUCCESS" } },
  { $group: { _id: "$agent.lga", txns: { $sum: 1 }, volume: { $sum: "$amount" } } },
  { $sort: { volume: -1 } }, { $limit: 5 }]).toArray());

hr("M6. Aggregation on type-specific fields: electricity units sold per biller");
show(db.transactions.aggregate([
  { $match: { type: "BILL_PAY", status: "SUCCESS", "bill.category": "electricity" } },
  { $group: { _id: "$bill.biller", payments: { $sum: 1 }, naira: { $sum: "$amount" },
              kwh: { $sum: "$bill.units_kwh" } } },
  { $sort: { naira: -1 } }]).toArray());

hr("M7. $lookup when we DO need the full parent: top 3 agents by October fees, with super agent");
show(db.transactions.aggregate([
  { $match: { status: "SUCCESS" } },
  { $group: { _id: "$agent.code", fees: { $sum: "$fee" }, txns: { $sum: 1 } } },
  { $sort: { fees: -1 } }, { $limit: 3 },
  { $lookup: { from: "agents", localField: "_id", foreignField: "_id", as: "a" } },
  { $project: { fees: 1, txns: 1, business: { $first: "$a.business_name" },
                super_agent: { $first: "$a.super_agent.name" } } }]).toArray());

hr("M8. Time-series collection: hourly average signal & min battery for terminal 2AGL0007");
show(db.terminal_heartbeats.aggregate([
  { $match: { "terminal.id": "2AGL0007" } },
  { $group: { _id: { $dateTrunc: { date: "$ts", unit: "hour" } },
              avg_signal_dbm: { $avg: "$signal_dbm" }, min_battery: { $min: "$battery_pct" } } },
  { $sort: { _id: 1 } }, { $limit: 4 }]).toArray());
const ts = db.runCommand({ collStats: "terminal_heartbeats" });
print("time-series buckets: " + (ts.timeseries ? ts.timeseries.bucketCount : "n/a") +
      " for " + db.terminal_heartbeats.countDocuments() + " measurements");

hr("M9. TTL index: OTP documents expire automatically");
db.otp_sessions.deleteMany({});
db.otp_sessions.insertOne({ phone: "08099990001", otp: "482913", created_at: new Date(Date.now() - 125000) });
print("OTP inserted with created_at 125s ago; TTL = 120s; docs now: " + db.otp_sessions.countDocuments());
print("indexes: " + JSON.stringify(db.otp_sessions.getIndexes().map(i => [i.name, i.expireAfterSeconds])));
print("(the TTL monitor runs every 60s; see evidence of deletion at the end of this file)");

hr("M10. Storage comparison");
const st = db.runCommand({ dbStats: 1 });
print("transactions docs: " + db.transactions.countDocuments() +
      " | avg doc size: " + db.transactions.stats().avgObjSize + " bytes" +
      " | data size: " + (db.transactions.stats().size / 1048576).toFixed(1) + " MB" +
      " | storage (compressed): " + (db.transactions.stats().storageSize / 1048576).toFixed(1) + " MB");
