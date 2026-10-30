// テスト用の D1 もどき(index.js が使う SQL だけを、文の先頭で見分けて動かす)
export function fakeDB({ users = {}, testNow } = {}) {
  const db = {
    users: Object.fromEntries(Object.entries(users).map(([id, points]) => [id, { id, points }])),
    adRewards: [],
    ledger: [],
    attempts: new Map(),
    events: [],
    sql: [],
  };
  const exec = (sql, args) => {
    db.sql.push(sql);
    const s = sql.replace(/\s+/g, " ").trim();
    if (s.startsWith("CREATE TABLE")) return { first: null, changes: 0 };
    if (s.startsWith("SELECT id FROM users WHERE id = ?")) return { first: db.users[args[0]] ? { id: args[0] } : null };
    if (s.startsWith("SELECT points FROM users WHERE id = ?")) return { first: db.users[args[0]] ? { points: db.users[args[0]].points } : null };
    if (s.startsWith("SELECT COUNT(*) AS n FROM ad_rewards WHERE user_id = ? AND day = ?"))
      return { first: { n: db.adRewards.filter((r) => r.user_id === args[0] && r.day === args[1]).length } };
    if (s.startsWith("INSERT OR IGNORE INTO ad_rewards")) {
      if (db.adRewards.some((r) => r.transaction_id === args[0])) return { changes: 0 };
      db.adRewards.push({ transaction_id: args[0], user_id: args[1], amount: args[2], day: args[3], source: args[4] });
      return { changes: 1 };
    }
    if (s.startsWith("UPDATE users SET points = points + ? WHERE id = ?")) {
      if (db.users[args[1]]) db.users[args[1]].points += args[0];
      return { changes: db.users[args[1]] ? 1 : 0 };
    }
    if (s.startsWith("INSERT INTO ledger")) { db.ledger.push({ user_id: args[0], delta: args[1], reason: args[2] }); return { changes: 1 }; }
    if (s.startsWith("INSERT INTO ad_claim_attempts")) {
      const key = args[0] + "|" + args[1];
      const count = (db.attempts.get(key) || 0) + 1;
      db.attempts.set(key, count);
      return { first: { count }, changes: 1 };
    }
    if (s.startsWith("INSERT INTO events")) {
      db.events.push({ install_id: args[0], name: args[1], params: JSON.parse(args[2]) });
      return { changes: 1 };
    }
    if (s.startsWith("DELETE FROM")) return { changes: 0 };
    throw new Error("fakeDB: 未対応の SQL: " + s);
  };
  const statement = (sql, args) => ({
    bind: (...a) => statement(sql, a),
    first: async () => exec(sql, args).first ?? null,
    run: async () => ({ meta: { changes: exec(sql, args).changes ?? 0 } }),
    all: async () => ({ results: [] }),
    _sql: sql, _args: args,
  });
  db.prepare = (sql) => statement(sql, []);
  db.batch = async (stmts) => stmts.map((st) => ({ meta: { changes: exec(st._sql, st._args).changes ?? 0 } }));
  return db;
}
