-- Video Mania のポイント台帳(Cloudflare D1)
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,            -- Apple でサインインの sub(利用者ごとに固定の ID)
  points INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  last_daily TEXT,                -- 毎日ボーナスを最後に受け取った日(日本時間 YYYY-MM-DD)
  apple_refresh_token TEXT        -- Apple のトークン(アカウント削除時に失効させる)。既存の DB には index.js が ALTER TABLE で足す
);

CREATE TABLE IF NOT EXISTS ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  delta INTEGER NOT NULL,         -- 増えたら +、使ったら -
  reason TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ledger_user ON ledger (user_id, id);

-- リワード広告でもらったポイント(transaction_id で二重付与を防ぐ。day は日本時間 YYYY-MM-DD)
CREATE TABLE IF NOT EXISTS ad_rewards (
  transaction_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  amount INTEGER NOT NULL,
  day TEXT NOT NULL,
  source TEXT NOT NULL,           -- ssv(AdMob のサーバー側検証)/ client(テスト期間のアプリからの申告)
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ad_rewards_user_day ON ad_rewards (user_id, day);

-- 使い方の統計(匿名。install_id は端末ごとのランダムな ID で、users とは結びつけない)
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  install_id TEXT NOT NULL,
  name TEXT NOT NULL,
  params TEXT NOT NULL,           -- JSON
  app_version TEXT,
  os_version TEXT,
  device TEXT,
  locale TEXT,
  client_time TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS events_created ON events (created_at);
CREATE INDEX IF NOT EXISTS events_name_created ON events (name, created_at);

-- 問い合わせ(/support のフォーム → POST /v1/contact。ip_hash は IP のハッシュで、1 日の件数の制限に使う)
CREATE TABLE IF NOT EXISTS contacts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,             -- question / bug / ai_report / ad_report / data_deletion
  message TEXT NOT NULL,
  email TEXT,                     -- 返信先(任意)
  created_at TEXT NOT NULL,
  ip_hash TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS contacts_ip_created ON contacts (ip_hash, created_at);
