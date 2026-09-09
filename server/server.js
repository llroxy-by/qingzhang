// 轻账 云端服务器（零依赖：仅用 Node 内置 http + node:sqlite）
// 部署：把整个 server 目录拷到服务器，node server.js 即可（或用 NSSM 注册成 Windows 服务）
// 端口：默认 8080（环境变量 PORT 可改）
// 数据：data/qingzhang.db（SQLite 单文件）
// Web UI：web/ 目录下的静态文件（Flutter Web 构建产物），与 API 同端口托管
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');
const mailModule = require('./mail'); // 邮箱账单拉取（QQ IMAP）

const PORT = parseInt(process.env.PORT || '8080', 10);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const WEB_DIR = process.env.WEB_DIR || path.join(__dirname, 'web');

fs.mkdirSync(DATA_DIR, { recursive: true });

const db = new DatabaseSync(path.join(DATA_DIR, 'qingzhang.db'));
db.exec(`
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  nickname TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS tokens(
  token TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS accounts(
  id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
  name TEXT NOT NULL, emoji TEXT NOT NULL DEFAULT '💳',
  type TEXT NOT NULL DEFAULT 'bank', sort_order INTEGER NOT NULL DEFAULT 0,
  is_active INTEGER NOT NULL DEFAULT 1,
  channel_keywords TEXT NOT NULL DEFAULT '',
  opening_date TEXT, opening_cents INTEGER,
  updated_at INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS snapshots(
  id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
  date TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS snapshot_entries(
  id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
  snapshot_id TEXT NOT NULL, account_id TEXT NOT NULL,
  amount_cents INTEGER NOT NULL,
  updated_at INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS txns(
  id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
  date TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
  amount_cents INTEGER NOT NULL, channel TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT 'manual', category TEXT NOT NULL DEFAULT 'unknown',
  account_id TEXT, trip_id TEXT, created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS trips(
  id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
  name TEXT NOT NULL, start_date TEXT NOT NULL, end_date TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_accounts_uid ON accounts(user_id);
CREATE INDEX IF NOT EXISTS idx_snapshots_uid ON snapshots(user_id);
CREATE INDEX IF NOT EXISTS idx_entries_uid ON snapshot_entries(user_id);
CREATE INDEX IF NOT EXISTS idx_txns_uid ON txns(user_id);
CREATE INDEX IF NOT EXISTS idx_trips_uid ON trips(user_id);
CREATE INDEX IF NOT EXISTS idx_tokens_uid ON tokens(user_id);
`);

// 老库兼容：users 表补 password_hash 列（若缺）
try {
  const cols = db.prepare('PRAGMA table_info(users)').all();
  if (!cols.some((c) => c.name === 'password_hash')) {
    db.exec('ALTER TABLE users ADD COLUMN password_hash TEXT NOT NULL DEFAULT \'\'');
    console.log('[migrate] users.password_hash 列已补');
  }
} catch (e) {
  console.log('[migrate] 检查 users 列失败(忽略):', e.message);
}

// ---------------- 工具 ----------------

function now() {
  return Date.now();
}

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => {
      data += c;
      if (data.length > 50 * 1024 * 1024) {
        reject(new Error('body too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch (e) {
        reject(new Error('invalid json'));
      }
    });
    req.on('error', reject);
  });
}

// ---------------- 表驱动合并 ----------------

// 每个业务表：表名 → 额外列的 set（除 id/user_id/updated_at/deleted 外）
// 传入行对象 → 构造 UPDATE/INSERT
const TABLES = {
  accounts: {
    cols: ['name', 'emoji', 'type', 'sort_order', 'is_active', 'channel_keywords', 'opening_date', 'opening_cents'],
  },
  snapshots: {
    cols: ['date', 'created_at'],
  },
  snapshot_entries: {
    cols: ['snapshot_id', 'account_id', 'amount_cents'],
  },
  txns: {
    cols: ['date', 'description', 'amount_cents', 'channel', 'source', 'category', 'account_id', 'trip_id', 'created_at'],
  },
  trips: {
    cols: ['name', 'start_date', 'end_date', 'created_at'],
  },
};

function rowToMap(r) {
  // node:sqlite 返回的列名如何访问？DatabaseSync prepare/get/all 返回对象，键为列名
  return r;
}

function selectAll(table, userId) {
  const stmt = db.prepare(`SELECT * FROM ${table} WHERE user_id = ?`);
  return stmt.all(userId);
}

// 被改名表 → 引用它的（表, 列）：换 id 后同步重写这些引用
const REFERRERS = {
  accounts: [
    ['snapshot_entries', 'account_id'],
    ['txns', 'account_id'],
  ],
  snapshots: [['snapshot_entries', 'snapshot_id']],
  trips: [['txns', 'trip_id']],
};

function genId() {
  return crypto.randomUUID().replace(/-/g, '');
}

/**
 * 合并客户端推送的一批行（last-write-wins by updated_at）。
 * id 全局主键，若行 id 已被其他用户占用（如导入了别人的数据/旧数字 id），
 * 为该行分配新随机 id 保留数据，并记入 renames（由调用方统一重写引用列）。
 */
function mergeRows(table, userId, rows, renames) {
  const meta = TABLES[table];
  const idCols = meta.cols.join(', ');
  const ph = meta.cols.map(() => '?').join(', ');
  const selectStmt = db.prepare(`SELECT updated_at FROM ${table} WHERE id = ? AND user_id = ?`);
  const insertStmt = db.prepare(
    `INSERT INTO ${table} (id, user_id, ${idCols}, updated_at, deleted) VALUES (?, ?, ${ph}, ?, ?)`
  );
  const updateStmt = db.prepare(
    `UPDATE ${table} SET ${meta.cols.map((c) => `${c} = ?`).join(', ')}, updated_at = ?, deleted = ? WHERE id = ? AND user_id = ?`
  );
  let merged = 0;
  let renamed = 0;
  for (const r of rows) {
    if (!r || typeof r.id !== 'string' || typeof r.updated_at !== 'number') continue;
    const existing = selectStmt.get(r.id, userId);
    const vals = meta.cols.map((c) => r[c] ?? null);
    if (!existing || (r.updated_at ?? 0) >= existing.updated_at) {
      if (!existing) {
        try {
          insertStmt.run(r.id, userId, ...vals, r.updated_at ?? 0, r.deleted ? 1 : 0);
        } catch (e) {
          if (!/UNIQUE/.test(String(e && e.message || e))) throw e;
          // 该 id 被其他用户占用：换新 id 保留本行数据
          const newId = genId();
          const map = renames.get(table) ?? new Map();
          map.set(String(r.id), newId);
          renames.set(table, map);
          insertStmt.run(newId, userId, ...vals, r.updated_at ?? 0, r.deleted ? 1 : 0);
          renamed++;
        }
      } else {
        updateStmt.run(...vals, r.updated_at ?? 0, r.deleted ? 1 : 0, r.id, userId);
      }
      merged++;
    }
  }
  return { merged, renamed };
}

/** 应用 id 改名：把本用户所有引用旧 id 的列改为新 id（与本次 push 的其他行保持一致） */
function applyRenames(userId, renames) {
  let fixed = 0;
  for (const [renamedTable, map] of renames) {
    const referrers = REFERRERS[renamedTable] ?? [];
    for (const [refTable, refCol] of referrers) {
      const upd = db.prepare(
        `UPDATE ${refTable} SET ${refCol} = ?, updated_at = ? WHERE user_id = ? AND ${refCol} = ?`
      );
      for (const [oldId, newId] of map) {
        const r = upd.run(newId, now(), userId, oldId);
        fixed += r.changes;
      }
    }
  }
  return fixed;
}

// ---------------- 用户（昵称 + 密码） ----------------

/** scrypt 加盐哈希，存 "salt:hex" */
function hashPassword(password) {
  const salt = crypto.randomBytes(8).toString('hex');
  const hash = crypto.scryptSync(String(password), salt, 32).toString('hex');
  return `${salt}:${hash}`;
}

function verifyPassword(password, stored) {
  if (!stored || typeof stored !== 'string') return false;
  const parts = stored.split(':');
  if (parts.length !== 2) return false;
  const hash = crypto.scryptSync(String(password), parts[0], 32);
  const expect = Buffer.from(parts[1], 'hex');
  return hash.length === expect.length && crypto.timingSafeEqual(hash, expect);
}

function createToken(userId) {
  const token = crypto.randomBytes(24).toString('hex');
  db.prepare('INSERT INTO tokens (token, user_id, created_at) VALUES (?, ?, ?)')
    .run(token, userId, now());
  return token;
}

/** 从请求头取 token；返回 {userId} 或 null */
function authFrom(req) {
  const h = req.headers['authorization'] || '';
  let token = '';
  if (h.startsWith('Bearer ')) token = h.slice(7).trim();
  if (!token) {
    const url = new URL(req.url, 'http://x');
    token = (url.searchParams.get('token') || '').trim();
  }
  if (!token) return null;
  const row = db.prepare('SELECT user_id FROM tokens WHERE token = ?').get(token);
  return row ? { userId: Number(row.user_id) } : null;
}

/** 注册：新昵称建账号；老账号（无密码）绑密码。已设密码的同名返回 null(code 409)。 */
function registerUser(nickname, password) {
  const t = String(nickname).trim();
  const found = db.prepare('SELECT * FROM users WHERE nickname = ?').get(t);
  if (found) {
    if (found.password_hash) return { conflict: true };
    db.prepare('UPDATE users SET password_hash = ? WHERE id = ?')
      .run(hashPassword(password), found.id);
    const uid = Number(found.id);
    return { user: { id: uid, nickname: t }, token: createToken(uid) };
  }
  const ins = db.prepare(
    'INSERT INTO users (nickname, password_hash, created_at) VALUES (?, ?, ?)'
  );
  const info = ins.run(t, hashPassword(password), now());
  const uid = Number(info.lastInsertRowid);
  return { user: { id: uid, nickname: t }, token: createToken(uid) };
}

function loginUser(nickname, password) {
  const row = db
    .prepare('SELECT * FROM users WHERE nickname = ?')
    .get(String(nickname).trim());
  if (!row || !verifyPassword(password, row.password_hash)) return null;
  return {
    user: { id: Number(row.id), nickname: row.nickname },
    token: createToken(Number(row.id)),
  };
}

function listUsers() {
  const stmt = db.prepare('SELECT id, nickname, created_at FROM users ORDER BY id');
  return stmt.all();
}

/**
 * 清空某用户全部业务数据（App"清空全部数据"联动）。
 * 物理删除含 tombstone 的所有行；保留 users 记录（昵称账号还在）。
 */
function resetUserData(userId) {
  let cleared = 0;
  for (const table of Object.keys(TABLES)) {
    const info = db.prepare(`DELETE FROM ${table} WHERE user_id = ?`).run(userId);
    cleared += Number(info.changes || 0);
  }
  return cleared;
}

function userExists(userId) {
  const stmt = db.prepare('SELECT id FROM users WHERE id = ?');
  return !!stmt.get(userId);
}

// ---------------- 静态文件 ----------------

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.wasm': 'application/wasm',
  '.map': 'application/json',
};

function serveStatic(req, res, urlPath) {
  let p = urlPath === '/' ? '/index.html' : urlPath;
  // 防目录穿越
  const filePath = path.normalize(path.join(WEB_DIR, p));
  if (!filePath.startsWith(path.normalize(WEB_DIR))) {
    res.writeHead(403);
    res.end('forbidden');
    return;
  }
  fs.readFile(filePath, (err, buf) => {
    if (err) {
      // SPA 回退到 index.html
      fs.readFile(path.join(WEB_DIR, 'index.html'), (err2, buf2) => {
        if (err2) {
          res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
          res.end('轻账 Web 尚未部署：请先 flutter build web 并把产物放到 server/web/');
          return;
        }
        res.writeHead(200, { 'Content-Type': MIME['.html'] });
        res.end(buf2);
      });
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(buf);
  });
}

// ---------------- 路由 ----------------

const server = http.createServer(async (req, res) => {
  // 访问日志（排查网络问题用）
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url} from ${req.socket.remoteAddress}`);
  res.on('finish', () => {
    console.log(`[${new Date().toISOString()}] -> ${res.statusCode}`);
  });
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      });
      res.end();
      return;
    }

    // API：/api/* 除 login/register/静态资源外都要登录 token
    const isApi = pathname.startsWith('/api/');
    const isPublicApi =
      pathname === '/api/user/login' || pathname === '/api/user/register';

    if (pathname === '/api/user/login' && req.method === 'POST') {
      const body = await readBody(req);
      if (!body.nickname || !body.password) {
        return json(res, 400, { error: 'nickname 和 password 必填' });
      }
      const r = loginUser(body.nickname, body.password);
      if (!r) return json(res, 401, { error: '昵称或密码不对' });
      return json(res, 200, r);
    }

    if (pathname === '/api/user/register' && req.method === 'POST') {
      const body = await readBody(req);
      if (!body.nickname || !body.password) {
        return json(res, 400, { error: 'nickname 和 password 必填' });
      }
      if (String(body.password).length < 4) {
        return json(res, 400, { error: '密码至少 4 位' });
      }
      const r = registerUser(body.nickname, body.password);
      if (r.conflict) {
        return json(res, 409, { error: '该昵称已被注册，请直接登录' });
      }
      return json(res, 200, r);
    }

    if (isApi && !isPublicApi) {
      // 只读 GET 免鉴权：Web 端免登录查看（users 列表 + 任意用户数据只读）
      // 写操作（同步/清空/邮件）仍需登录 token
      const readOnlyGet =
        req.method === 'GET' &&
        (pathname === '/api/users' ||
          /^\/api\/data\/\d+$/.test(pathname));
      if (!readOnlyGet) {
        const auth = authFrom(req);
        if (!auth) {
          return json(res, 401, { error: '请先登录（缺少或无效的登录凭证）' });
        }
        req.authUser = auth.userId;
      }
    }

    if (pathname === '/api/users' && req.method === 'GET') {
      return json(res, 200, { users: listUsers() });
    }

    const dataMatch = pathname.match(/^\/api\/data\/(\d+)$/);
    if (dataMatch) {
      const userId = parseInt(dataMatch[1], 10);
      if (!userExists(userId)) return json(res, 404, { error: 'user not found' });

      if (req.method === 'GET') {
        return json(res, 200, dumpAll(userId));
      }

      if (req.method === 'POST') {
        const body = await readBody(req);
        const totals = {};
        const renames = new Map();
        db.exec('BEGIN');
        try {
          for (const table of Object.keys(TABLES)) {
            const rows = Array.isArray(body[table]) ? body[table] : [];
            totals[table] = mergeRows(table, userId, rows, renames);
          }
          const fixed = applyRenames(userId, renames);
          db.exec('COMMIT');
          // merged 兼容旧格式：每表 {merged, renamed}
          const out = {};
          for (const [k, v] of Object.entries(totals)) {
            out[k] = v.merged + (v.renamed ?? 0);
          }
          if (fixed > 0) out.idFixed = fixed;
          return json(res, 200, { merged: out, data: dumpAll(userId) });
        } catch (e) {
          try { db.exec('ROLLBACK'); } catch (_) {}
          console.error('[sync error]', e && e.message || e);
          return json(res, 500, { error: String(e && e.message || e) });
        }
      }
      return json(res, 405, { error: 'method not allowed' });
    }

    // 清空某用户全部业务数据（只能清自己的）
    const resetMatch = pathname.match(/^\/api\/reset\/(\d+)$/);
    if (resetMatch && req.method === 'POST') {
      const userId = parseInt(resetMatch[1], 10);
      if (userId !== req.authUser) {
        return json(res, 403, { error: '只能清空自己的账号数据' });
      }
      if (!userExists(userId)) return json(res, 404, { error: 'user not found' });
      const cleared = resetUserData(userId);
      return json(res, 200, { cleared });
    }

    // ---------- 邮箱账单（QQ IMAP） ----------
    if (pathname === '/api/mail/config' && req.method === 'POST') {
      const body = await readBody(req);
      if (!body.email || !body.authCode) {
        return json(res, 400, { error: 'email 和 authCode 必填' });
      }
      mailModule.saveConfig({ email: body.email, authCode: body.authCode });
      return json(res, 200, { ok: true, email: body.email });
    }
    if (pathname === '/api/mail/config' && req.method === 'GET') {
      const cfg = mailModule.loadConfig();
      return json(res, 200, {
        configured: !!cfg,
        email: cfg ? cfg.email : '',
      });
    }
    if (pathname === '/api/mail/list' && req.method === 'GET') {
      try {
        const r = await mailModule.listMails();
        return json(res, 200, r);
      } catch (e) {
        return json(res, 500, { error: mailModule.mailErrorText(e) });
      }
    }
    const attMatch = pathname.match(/^\/api\/mail\/attachment\/(\d+)\/([^/]+)$/);
    if (attMatch && req.method === 'GET') {
      try {
        const buf = await mailModule.downloadAttachment(
          Number(attMatch[1]),
          decodeURIComponent(attMatch[2])
        );
        res.writeHead(200, {
          'Content-Type': 'application/octet-stream',
          'Content-Length': buf.length,
        });
        res.end(buf);
        return;
      } catch (e) {
        return json(res, 500, { error: mailModule.mailErrorText(e) });
      }
    }

    // 其余交给静态文件（Web UI）
    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveStatic(req, res, pathname);
    }

    json(res, 404, { error: 'not found' });
  } catch (e) {
    json(res, 500, { error: String(e && e.message ? e.message : e) });
  }
});

function dumpAll(userId) {
  const out = {};
  for (const table of Object.keys(TABLES)) {
    out[table] = selectAll(table, userId);
  }
  return out;
}

server.listen(PORT, () => {
  console.log(`轻账服务器已启动: http://0.0.0.0:${PORT}`);
  console.log(`数据目录: ${DATA_DIR}`);
  console.log(`Web 目录: ${WEB_DIR}`);
});
