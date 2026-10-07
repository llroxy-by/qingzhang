import 'package:flutter/material.dart';

import '../main.dart';
import '../models/account.dart';
import '../models/debt.dart';
import '../models/snapshot.dart';
import '../utils/format.dart';
import '../widgets/quick_txn_sheet.dart';
import 'debts_page.dart';
import 'snapshot_edit_page.dart';

class HomePage extends StatelessWidget {
  final int tick;
  const HomePage({super.key, required this.tick});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SnapshotEditPage()),
          );
        },
        icon: const Icon(Icons.edit_note),
        label: const Text('记一笔快照'),
      ),
      body: SafeArea(
        child: FutureBuilder(
          future: _load(),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('⚠️', style: TextStyle(fontSize: 40)),
                      const SizedBox(height: 10),
                      const Text('加载失败',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text('${snap.error}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12)),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () => appState.refresh(),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final (accounts, snapshots, debts) = snap.data!;
            if (snapshots.isEmpty) {
              return _EmptyState(accounts: accounts);
            }
            final latest = snapshots.first;
            final prev =
                snapshots.length > 1 ? snapshots[1] : null;
            return _Overview(
              accounts: accounts,
              latest: latest,
              prev: prev,
              debts: debts,
            );
          },
        ),
      ),
    );
  }

  Future<(List<Account>, List<Snapshot>, List<Debt>)> _load() async {
    final db = appState.db;
    final accounts = await db.listAccounts(onlyActive: true);
    final snapshots = await db.listSnapshots();
    final debts = await db.listDebts();
    return (accounts, snapshots, debts);
  }
}

class _EmptyState extends StatelessWidget {
  final List<Account> accounts;
  const _EmptyState({required this.accounts});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('🌱', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            Text(accounts.isEmpty ? '还没有资金构成' : '还没有快照记录',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (accounts.isEmpty) ...[
              Text('请到底部导航「设置」→ 资金构成 添加你的账户\n（如：招行卡、零钱通、基金…）\n添加后就能「记一笔快照」了',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, height: 1.6)),
            ] else
              Text(
                '点右下角「记一笔快照」，把 ${accounts.map((a) => a.name).join('、')}\n的余额填进去，之后就能看到趋势和花销分析了',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, height: 1.6),
              ),
          ],
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  final List<Account> accounts;
  final Snapshot latest;
  final Snapshot? prev;
  final List<Debt> debts;

  const _Overview({
    required this.accounts,
    required this.latest,
    required this.prev,
    required this.debts,
  });

  @override
  Widget build(BuildContext context) {
    final diff = prev == null ? null : latest.totalCents - prev!.totalCents;
    final liquid = accounts
        .where((a) => a.isLiquid)
        .fold<int>(0, (s, a) => s + (latest.amountOf(a.id!) ?? 0));
    final dead = accounts
        .where((a) => !a.isLiquid)
        .fold<int>(0, (s, a) => s + (latest.amountOf(a.id!) ?? 0));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Row(
          children: [
            const Text('轻账',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const Spacer(),
            Chip(
              avatar: const Icon(Icons.history, size: 16),
              label: Text('最近记录：${friendlyDate(latest.date)}'),
              visualDensity: VisualDensity.compact,
              side: BorderSide.none,
              backgroundColor: Colors.white,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _TotalCard(
          total: latest.totalCents,
          diff: diff,
          latestDate: latest.date,
          liquid: liquid,
          dead: dead,
        ),
        const SizedBox(height: 12),
        _DebtCard(debts: debts),
        const SizedBox(height: 12),
        // 随手记一笔（不导银行流水时补刷卡/大额消费）
        OutlinedButton.icon(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.white,
            shape: const RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => const QuickTxnSheet(),
          ),
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('随手记一笔（刷卡/大额支出，免导流水）'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF00897B),
            side: const BorderSide(color: Color(0xFF00897B), width: 1.2),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('资金构成',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: Colors.grey.shade800)),
            const Spacer(),
            Text(fmtDate(latest.date),
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 8),
        ..._accountGroup(context, '活钱', accounts.where((a) => a.isLiquid).toList(), latest, prev),
        if (accounts.any((a) => !a.isLiquid)) ...[
          const SizedBox(height: 8),
          ..._accountGroup(context, '死钱', accounts.where((a) => !a.isLiquid).toList(), latest, prev),
        ],
        if (prev != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.grey.shade500, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '相比 ${fmtDate(prev!.date)} 的总资产 ${fmtCents(prev!.totalCents)}，'
                      '${diff! >= 0 ? '增加了' : '减少了'} ${fmtCents(diff.abs())}。'
                      '想弄清钱花哪了，去「分析」页或导入账单流水。',
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 13, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 一组账户（活钱/死钱）：组标题 + 小计 + 账户卡片
  List<Widget> _accountGroup(BuildContext context, String label,
      List<Account> group, Snapshot latest, Snapshot? prev) {
    if (group.isEmpty) return const [];
    final subtotal =
        group.fold<int>(0, (s, a) => s + (latest.amountOf(a.id!) ?? 0));
    final teal = const Color(0xFF00897B);
    final purple = const Color(0xFF7B1FA2);
    final color = label == '活钱' ? teal : purple;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Icon(label == '活钱' ? Icons.water_drop_outlined : Icons.lock_outline,
                size: 15, color: color),
            const SizedBox(width: 6),
            Text('$label 小计',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: color)),
            const Spacer(),
            Text('¥ ${fmtCents(subtotal)}',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
      ...group.map((a) => _AccountTile(
            account: a,
            amount: latest.amountOf(a.id!),
            prevAmount: prev?.amountOf(a.id!),
          )),
    ];
  }
}

class _TotalCard extends StatelessWidget {
  final int total;
  final int? diff;
  final String latestDate;
  final int liquid; // 活钱合计（分）
  final int dead; // 死钱合计（分）
  const _TotalCard(
      {required this.total,
      required this.diff,
      required this.latestDate,
      required this.liquid,
      required this.dead});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF00897B), Color(0xFF26A69A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('总资产（¥）',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            fmtCents(total),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5),
          ),
          const SizedBox(height: 10),
          if (diff != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: diff! >= 0
                    ? const Color(0x33FFFFFF)
                    : const Color(0x55FFCC80),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    diff! >= 0 ? Icons.trending_up : Icons.trending_down,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '相比上次 ${diff! >= 0 ? '+' : '-'}${fmtCents(diff!.abs())}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Container(height: 1, color: const Color(0x33FFFFFF)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _LiquidStat(
                    label: '活钱 · 随时能花', amount: liquid),
              ),
              Container(
                  width: 1, height: 32, color: const Color(0x33FFFFFF)),
              Expanded(
                child: _LiquidStat(
                    label: '死钱 · 短期取不出', amount: dead),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LiquidStat extends StatelessWidget {
  final String label;
  final int amount;
  const _LiquidStat({required this.label, required this.amount});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 4),
        Text('¥ ${fmtCents(amount)}',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
      ],
    );
  }
}

/// 欠债摘要卡：未结清的我欠/别人欠我/净额；点击进入欠债管理
class _DebtCard extends StatelessWidget {
  final List<Debt> debts;
  const _DebtCard({required this.debts});

  @override
  Widget build(BuildContext context) {
    final unsettled = debts.where((d) => !d.settled).toList();
    var owe = 0;
    var lend = 0;
    for (final d in unsettled) {
      if (d.direction == DebtDirection.owe) {
        owe += d.amountCents;
      } else {
        lend += d.amountCents;
      }
    }
    final net = owe - lend;
    final hasDebt = owe > 0 || lend > 0;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DebtPage()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFE05B4B).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.swap_vert,
                    color: Color(0xFFE05B4B), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: hasDebt
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('我欠 ¥ ${fmtCents(owe)}',
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFE05B4B))),
                              const SizedBox(width: 12),
                              Text('别人欠我 ¥ ${fmtCents(lend)}',
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF2E9E5B))),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            net > 0
                                ? '净欠 ¥ ${fmtCents(net)} · 规划花销记得留出来'
                                : net < 0
                                    ? '净应收 ¥ ${fmtCents(-net)}，还有 ${unsettled.length} 笔没结'
                                    : '${unsettled.length} 笔未结清，两清状态',
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 12),
                          ),
                        ],
                      )
                    : Text('还没有欠债记录，点这里记一笔',
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 13)),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final Account account;
  final int? amount;
  final int? prevAmount;
  const _AccountTile(
      {required this.account, required this.amount, required this.prevAmount});

  @override
  Widget build(BuildContext context) {
    final amt = amount ?? 0;
    final change = (prevAmount == null || amount == null)
        ? null
        : amount! - prevAmount!;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: _typeColor(account.type).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(account.emoji, style: const TextStyle(fontSize: 20)),
        ),
        title: Text(account.name,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Text(
            '${account.isLiquid ? '活钱' : '死钱'} · ${account.type.label}',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('¥ ${fmtCents(amt)}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            if (change != null && change != 0)
              Text(
                change > 0 ? '+${fmtCents(change)}' : fmtCents(change),
                style: TextStyle(
                  fontSize: 12,
                  color: change > 0
                      ? const Color(0xFF2E9E5B)
                      : const Color(0xFFE05B4B),
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _typeColor(AccountType t) {
    switch (t) {
      case AccountType.bank:
        return const Color(0xFF1565C0);
      case AccountType.wealth:
        return const Color(0xFFF9A825);
      case AccountType.invest:
        return const Color(0xFF7B1FA2);
      case AccountType.other:
        return const Color(0xFF546E7A);
    }
  }
}
