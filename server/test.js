// 轻账服务器端到端冒烟测试（node test.js，先启动 server.js）
'use strict';
const BASE = process.env.BASE || 'http://127.0.0.1:18080';
let failed = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    console.log(`  ✗ ${name} ${extra ? JSON.stringify(extra) : ''}`);
  }
}
async function api(path, opts = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (opts.token) headers['Authorization'] = `Bearer ${opts.token}`;
  const r = await fetch(BASE + path, { ...opts, headers });
  return { status: r.status, body: await r.json() };
}
const j = (o) => JSON.stringify(o);

async function main() {
  console.log('== 1. 注册（昵称+密码） ==');
  const r1 = await api('/api/user/register', {
    method: 'POST',
    body: j({ nickname: '冒烟用户A', password: 'pass-a1' }),
  });
  check('注册返回 user+token', r1.status === 200 && r1.body.user && r1.body.token, r1.body);
  const uid = r1.body.user.id;
  const tokenA = r1.body.token;
  check('昵称正确', r1.body.user.nickname === '冒烟用户A');

  console.log('== 2. 重复注册同昵称 → 409 ==');
  const r2 = await api('/api/user/register', {
    method: 'POST',
    body: j({ nickname: '冒烟用户A', password: 'other-pass' }),
  });
  check('同昵称再注册被拒(409)', r2.status === 409, r2.body);

  console.log('== 3. 登录 ==');
  const rL = await api('/api/user/login', {
    method: 'POST',
    body: j({ nickname: '冒烟用户A', password: 'pass-a1' }),
  });
  check('正确密码登录成功', rL.status === 200 && rL.body.token && rL.body.user.id === uid);
  const rBad = await api('/api/user/login', {
    method: 'POST',
    body: j({ nickname: '冒烟用户A', password: 'wrong' }),
  });
  check('错误密码 401', rBad.status === 401, rBad.body);

  console.log('== 4. 写操作未带 token → 401 ==');
  const noAuth = await api(`/api/data/${uid}`, { method: 'POST', body: j({}) });
  check('无凭证写被拒', noAuth.status === 401, noAuth.body);
  // Web 免登录只读：GET data/users 不需要 token；写操作(POST)才要
  const readNo = await api(`/api/data/${uid}`, { method: 'GET' });
  check('GET 只读免登录(Web 用)', readNo.status === 200, readNo.body);

  console.log('== 5. 推送全量数据（带 token） ==');
  const push1 = await api(`/api/data/${uid}`, {
    method: 'POST',
    token: tokenA,
    body: j({
      accounts: [
        { id: 'acc-1', name: '招行卡', emoji: '💳', type: 'bank', sort_order: 1, is_active: 1, channel_keywords: '', opening_date: null, opening_cents: null, updated_at: 1000, deleted: 0 },
      ],
      snapshots: [{ id: 'snap-1', date: '2026-09-08', created_at: 100, updated_at: 1000, deleted: 0 }],
      snapshot_entries: [{ id: 'se-1', snapshot_id: 'snap-1', account_id: 'acc-1', amount_cents: 123456, updated_at: 1000, deleted: 0 }],
      txns: [{ id: 'txn-1', date: '2026-09-07', description: '美团外卖', amount_cents: -2500, channel: '零钱', source: 'alipay', category: 'food', account_id: 'acc-1', trip_id: null, created_at: 50, updated_at: 1000, deleted: 0 }],
      trips: [],
    }),
  });
  check('推送成功', push1.status === 200 && push1.body.merged.accounts === 1, push1.body);

  console.log('== 6. 拉取校验 ==');
  const g1 = await api(`/api/data/${uid}`, { token: tokenA });
  check('GET 含 account', g1.body.accounts.length === 1 && g1.body.accounts[0].name === '招行卡');
  check('GET 含 txn', g1.body.txns.length === 1 && g1.body.txns[0].amount_cents === -2500);
  check('GET 含 entry', g1.body.snapshot_entries.length === 1);

  console.log('== 7. 冲突合并 last-write-wins ==');
  await api(`/api/data/${uid}`, {
    method: 'POST', token: tokenA,
    body: j({
      accounts: [{ id: 'acc-1', name: '旧名字', emoji: '💳', type: 'bank', sort_order: 1, is_active: 1, channel_keywords: '', opening_date: null, opening_cents: null, updated_at: 500, deleted: 0 }],
      snapshots: [], snapshot_entries: [], txns: [], trips: [],
    }),
  });
  const g2 = await api(`/api/data/${uid}`, { token: tokenA });
  check('旧数据(500)不覆盖新数据(1000)', g2.body.accounts[0].name === '招行卡');
  await api(`/api/data/${uid}`, {
    method: 'POST', token: tokenA,
    body: j({
      accounts: [{ id: 'acc-1', name: '招行卡-改名', emoji: '💳', type: 'bank', sort_order: 1, is_active: 1, channel_keywords: '招商银行', opening_date: null, opening_cents: null, updated_at: 3000, deleted: 0 }],
      snapshots: [], snapshot_entries: [], txns: [], trips: [],
    }),
  });
  const g3 = await api(`/api/data/${uid}`, { token: tokenA });
  check('新数据(3000)覆盖旧数据', g3.body.accounts[0].name === '招行卡-改名');

  console.log('== 8. 用户隔离 + 用户列表 ==');
  const rB = await api('/api/user/register', {
    method: 'POST',
    body: j({ nickname: '冒烟用户B', password: 'pass-b1' }),
  });
  const tokenB = rB.body.token;
  const uidB = rB.body.user.id;
  const gB = await api(`/api/data/${uidB}`, { token: tokenB });
  check('用户B 看不到用户A 的数据', gB.body.accounts.length === 0);
  const lu = await api('/api/users', { token: tokenB });
  check('用户列表含两人', lu.body.users.length >= 2);
  const luNo = await api('/api/users');
  check('用户列表免登录只读(Web 用)', luNo.status === 200, luNo.body);

  console.log('== 9. 清空数据（reset 权限） ==');
  const before = await api(`/api/data/${uid}`, { token: tokenA });
  check('A 有数据可清', before.body.txns.length > 0);
  const forbidden = await api(`/api/reset/${uid}`, { method: 'POST', token: tokenB });
  check('B 不能清 A（403）', forbidden.status === 403, forbidden.body);
  const reset = await api(`/api/reset/${uid}`, { method: 'POST', token: tokenA });
  check('A 清自己成功', reset.status === 200);
  const after = await api(`/api/data/${uid}`, { token: tokenA });
  const empty = Object.values(after.body).every((rows) => rows.length === 0);
  check('A 数据已清空', empty);
  const users2 = await api('/api/users', { token: tokenA });
  check('A 账号保留（可重新登录）', users2.body.users.some((u) => u.id === uid));
  const relogin = await api('/api/user/login', {
    method: 'POST',
    body: j({ nickname: '冒烟用户A', password: 'pass-a1' }),
  });
  check('清空后仍可登录', relogin.status === 200 && relogin.body.token);

  console.log('== 10. 跨账号同 id 冲突（UNIQUE 自动换 id 保数据） ==');
  const rc = await api('/api/user/register', {
    method: 'POST',
    body: j({ nickname: '冒烟用户C', password: 'pass-c1' }),
  });
  const uidC = rc.body.user.id;
  const tokenC = rc.body.token;
  const ts = Date.now();
  // 用户 A 先占用 dup-acc-1 / dup-snap-1 这两个全局 id
  const occA = await api(`/api/data/${uid}`, {
    method: 'POST', token: tokenA,
    body: j({
      accounts: [{ id: 'dup-acc-1', name: 'A占用', emoji: '💰', type: 'bank', sort_order: 0, is_active: 1, channel_keywords: '', opening_date: null, opening_cents: null, updated_at: ts, deleted: 0 }],
      snapshots: [{ id: 'dup-snap-1', date: '2026-09-08', created_at: ts, updated_at: ts, deleted: 0 }],
      snapshot_entries: [], txns: [], trips: [],
    }),
  });
  check('A 先占用 id 成功', occA.status === 200, occA.body);
  const accC = {
    id: 'dup-acc-1', name: '撞id账户', emoji: '💰', type: 'bank',
    sort_order: 0, is_active: 1, channel_keywords: '',
    opening_date: null, opening_cents: null, updated_at: ts, deleted: 0,
  };
  const snapC = { id: 'dup-snap-1', date: '2026-09-09', created_at: ts, updated_at: ts, deleted: 0 };
  const entryC = {
    id: 'dup-entry-1', snapshot_id: 'dup-snap-1', account_id: 'dup-acc-1',
    amount_cents: 1000, updated_at: ts, deleted: 0,
  };
  const pushC = await api(`/api/data/${uidC}`, {
    method: 'POST', token: tokenC,
    body: j({ accounts: [accC], snapshots: [snapC], snapshot_entries: [entryC], txns: [], trips: [] }),
  });
  check('C 推入撞 id 数据不 500', pushC.status === 200, pushC.body);
  const dataC = await api(`/api/data/${uidC}`, { token: tokenC });
  const gotAcc = dataC.body.accounts.find((a) => a.name === '撞id账户');
  check('C 数据保留（换新 id）', !!gotAcc && gotAcc.id !== 'dup-acc-1', dataC.body.accounts);
  const gotEntry = dataC.body.snapshot_entries[0];
  const gotSnap = dataC.body.snapshots[0];
  check('引用已联动重写(account_id/snapshot_id)',
    gotEntry.account_id === gotAcc.id && gotEntry.snapshot_id === gotSnap.id,
    JSON.stringify({ gotEntry, gotAcc, gotSnap }));

  console.log(failed === 0 ? '\n全部通过 ✅' : `\n${failed} 项失败 ❌`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('测试异常:', e);
  process.exit(1);
});
