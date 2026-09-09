// 诊断：生产库用户数与各用户 accounts id 形态
'use strict';
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('data/qingzhang.db');
const users = db.prepare('SELECT id, nickname FROM users').all();
console.log('用户:', JSON.stringify(users));
for (const u of users) {
  const acc = db.prepare('SELECT id FROM accounts WHERE user_id = ?').all();
  const numIds = acc.filter(a => /^\d+$/.test(a.id)).length;
  console.log(`user ${u.id}(${u.nickname}) accounts=${acc.length} 数字id=${numIds} 例:`, acc.slice(0, 3).map(a => a.id).join(','));
}
const dup = db.prepare('SELECT id, COUNT(*) c FROM accounts GROUP BY id HAVING c > 1').all();
console.log('accounts 表内重复 id:', dup.length);
