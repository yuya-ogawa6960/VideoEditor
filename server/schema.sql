-- Video Mania のポイント台帳(Cloudflare D1)
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,            -- Apple でサインインの sub(利用者ごとに固定の ID)
  points INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  last_daily TEXT                 -- 毎日ボーナスを最後に受け取った日(日本時間 YYYY-MM-DD)
);

CREATE TABLE IF NOT EXISTS ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  delta INTEGER NOT NULL,         -- 増えたら +、使ったら -
  reason TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ledger_user ON ledger (user_id, id);
