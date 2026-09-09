// 邮箱账单拉取模块（QQ 邮箱 IMAP）：配置存储 / 搜索招商银行邮件 / 附件下载
// 依赖：imapflow（E:\maserver\qingzhang\node_modules）
'use strict';
const fs = require('fs');
const path = require('path');
const { ImapFlow } = require('imapflow');

const DATA_DIR = path.join(__dirname, 'data');
const CONFIG_FILE = path.join(DATA_DIR, 'mail_config.json');

// 主题关键词（命中即视为银行账单邮件）
const IMAP_HOST = process.env.MAIL_IMAP_HOST || 'imap.qq.com';
const IMAP_PORT = Number(process.env.MAIL_IMAP_PORT || 993);

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  } catch (_) {
    return null;
  }
}

function saveConfig({ email, authCode }) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.writeFileSync(
    CONFIG_FILE,
    JSON.stringify({ email: String(email || '').trim(), authCode: String(authCode || '').trim() }, null, 2),
    'utf8'
  );
}

async function withClient(fn) {
  const cfg = loadConfig();
  if (!cfg || !cfg.email || !cfg.authCode) {
    const e = new Error('尚未配置邮箱（请先在 App 里填写 QQ 邮箱和授权码）');
    e.code = 'NO_CONFIG';
    throw e;
  }
  const client = new ImapFlow({
    host: IMAP_HOST,
    port: IMAP_PORT,
    secure: true,
    auth: { user: cfg.email, pass: cfg.authCode },
    logger: false,
    fetchTimeout: 60000,
  });
  await client.connect();
  try {
    return await fn(client, cfg);
  } finally {
    try {
      await client.logout();
    } catch (_) {
      /* ignore */
    }
  }
}

/** 收集附件节点（zip/pdf）——imapflow 的 structure 字段是扁平的：
 *  node.disposition = 'attachment'（字符串），文件名在
 *  node.dispositionParameters.filename 或 node.parameters.name（老式） */
function collectAttachments(node, out = []) {
  if (!node) return out;
  const filename =
    (node.dispositionParameters && node.dispositionParameters.filename) ||
    (node.parameters &&
      (node.parameters.filename || node.parameters.name));
  if (filename) {
    const lower = String(filename).toLowerCase();
    if (lower.endsWith('.zip') || lower.endsWith('.pdf')) {
      out.push({ part: node.part, filename: String(filename), size: node.size || 0 });
    }
  }
  if (node.childNodes) {
    for (const c of node.childNodes) collectAttachments(c, out);
  }
  return out;
}

/** 拉取近期带 zip/pdf 附件的邮件（招行/工行/支付宝等账单都可能是附件形式） */
async function listMails(days = 90, max = 100) {
  return withClient(async (client) => {
    const lock = await client.getMailboxLock('INBOX');
    try {
      const since = new Date(Date.now() - days * 86400000);
      const uids = await client.search({ since }, { uid: true });
      const mails = [];
      const recent = uids.slice(-max);
      for (const uid of recent) {
        const one = await client.fetchOne(
          uid,
          { envelope: true, bodyStructure: true }, // 注意：字段名是 bodyStructure
          { uid: true }
        );
        if (!one || !one.envelope) continue;
        const attachments = collectAttachments(one.bodyStructure);
        if (attachments.length === 0) continue;
        const subject = one.envelope.subject || '';
        const from = (one.envelope.from || [])
          .map((a) => (a.name || a.address || '').toString())
          .filter(Boolean)
          .join(',');
        mails.push({
          uid,
          date: one.envelope.date ? new Date(one.envelope.date).toISOString() : null,
          subject,
          from,
          attachments,
        });
      }
      return { mails };
    } finally {
      lock.release();
    }
  });
}

/** 在结构树里找指定 part 节点（取 encoding 判断是否需 base64 解码） */
function findPartNode(node, part) {
  if (!node) return null;
  if (node.part === part) return node;
  if (node.childNodes) {
    for (const c of node.childNodes) {
      const r = findPartNode(c, part);
      if (r) return r;
    }
  }
  return null;
}

/** 下载某封邮件的某个附件（返回 Buffer + filename） */
async function downloadAttachment(uid, part) {
  return withClient(async (client) => {
    const lock = await client.getMailboxLock('INBOX');
    try {
      // 先拿结构确定该 part 的传输编码（IMAP BODY 常是 base64，需还原）
      const meta = await client.fetchOne(
        uid,
        { bodyStructure: true },
        { uid: true }
      );
      const node = findPartNode(meta && meta.bodyStructure, part);
      const one = await client.fetchOne(
        uid,
        { bodyParts: [part] },
        { uid: true }
      );
      if (!one || !one.bodyParts) {
        const e = new Error('附件不存在或邮件已删除');
        e.code = 'NOT_FOUND';
        throw e;
      }
      let buf = Buffer.from(one.bodyParts.get(part) || []);
      if (buf.length === 0) {
        const e = new Error('附件读取失败');
        e.code = 'NOT_FOUND';
        throw e;
      }
      // base64/quoted-printable 传输编码还原
      const enc = node && node.encoding ? String(node.encoding).toLowerCase() : '';
      if (enc === 'base64') {
        buf = Buffer.from(buf.toString('utf8').replace(/\s+/g, ''), 'base64');
      } else if (enc === 'quoted-printable') {
        buf = Buffer.from(
          buf
            .toString('latin1')
            .replace(/=([0-9A-F]{2})/gi, (_, h) =>
              String.fromCharCode(parseInt(h, 16))
            ),
          'latin1'
        );
      }
      return buf;
    } finally {
      lock.release();
    }
  });
}

function mailErrorText(err) {
  if (err.code === 'NO_CONFIG') return err.message;
  if (err.code === 'NOT_FOUND') return err.message;
  const m = String((err && err.message) || err);
  if (/auth|login|credentials|command failed|authentication/i.test(m)) {
    return 'QQ 邮箱登录失败：请检查邮箱地址和授权码（不是 QQ 密码；授权码在 QQ 邮箱设置→账户→开启 IMAP 后生成）';
  }
  if (/certificate|tls|ssl/i.test(m)) {
    return '无法安全连接 QQ 邮箱服务器（网络问题）';
  }
  return '邮箱连接失败：' + m;
}

module.exports = {
  loadConfig,
  saveConfig,
  listMails,
  downloadAttachment,
  mailErrorText,
  IMAP_HOST,
  IMAP_PORT,
};
