import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../models/account.dart';
import '../models/categories.dart';
import '../models/snapshot.dart';
import '../models/trip.dart';
import '../models/txn.dart';
import '../services/analytics.dart';
import '../utils/format.dart';
import '../widgets/txn_edit_sheet.dart';

import 'txns_page.dart';
/// 分析页：趋势 / 构成 / 最近一期变化 / 流水消费分析（分类 + 单笔大头 + 旅程）
class AnalysisPage extends StatelessWidget {
  final int tick;
  const AnalysisPage({super.key, required this.tick});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder(
          future: _load(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final (accounts, snapshotsAsc, txns, trips) = snap.data!;
            if (snapshotsAsc.length < 2 && txns.isEmpty) {
              return const _AnalysisEmpty();
            }
            final tripById = {for (final t in trips) t.id: t};
            final startDate = snapshotsAsc.length >= 2
                ? snapshotsAsc[snapshotsAsc.length - 2].date
                : null;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                const Text('分析',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                if (snapshotsAsc.length >= 2) ...[
                  _TrendCard(snapshots: snapshotsAsc),
                  const SizedBox(height: 16),
                  _CompositionCard(
                      accounts: accounts, latest: snapshotsAsc.last),
                  const SizedBox(height: 16),
                  _PeriodCard(
                    accounts: accounts,
                    prev: snapshotsAsc[snapshotsAsc.length - 2],
                    latest: snapshotsAsc.last,
                  ),
                ] else
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '还没有快照数据。先在「总览」记一笔快照，累计两次后这里就能显示趋势。',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  ),
                if (txns.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _TxnAnalysisCard(txns: txns, start: startDate),
                  const SizedBox(height: 16),
                  _TopExpensesCard(
                      txns: txns,
                      start: startDate,
                      tripById: tripById,
                      onEdit: (t) => _editTxnFlow(
                          context, t, accounts, trips)),
                ],
                if (trips.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _TripsCard(trips: trips, txns: txns),
                ] else if (txns.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _TripsEmptyCard(),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Future<(List<Account>, List<Snapshot>, List<Txn>, List<Trip>)> _load() async {
    final db = appState.db;
    final accounts = await db.listAccounts();
    final snapshots = await db.listSnapshots();
    snapshots.sort((a, b) => a.date.compareTo(b.date));
    final txns = await db.listTxns();
    final trips = await db.listTrips();
    return (accounts, snapshots, txns, trips);
  }

  /// 从榜单点击一笔 → 弹编辑层（改名/改分类/换账户/归旅程/删除）
  Future<void> _editTxnFlow(BuildContext context, Txn txn,
      List<Account> accounts, List<Trip> trips) async {
    final result = await showTxnEditSheet(
      context,
      txn: txn,
      accounts: accounts.where((a) => a.isActive).toList(),
      trips: trips,
    );
    if (result == null || !context.mounted) return;
    if (result.deleted) {
      await appState.db.deleteTxn(txn.id!);
      appState.refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已删除这笔流水')));
      }
      return;
    }
    if (result.remember && (result.keyword?.isNotEmpty ?? false)) {
      await appState.db.addUserRule(result.keyword!, result.category);
    }
    await appState.db.updateTxn(txn.copyWith(
      description: result.description,
      category: result.category,
      accountId: result.accountId,
      tripId: result.tripId,
    ));
    appState.refresh();
    if (context.mounted) {
      final def = categoryOf(result.category);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已更新为「${def.emoji} ${def.label}」'
              '${result.remember ? '，并记住了规则' : ''}')));
    }
  }
}

class _AnalysisEmpty extends StatelessWidget {
  const _AnalysisEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('📊', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            const Text('还没有足够数据',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '记 2 次以上快照，或导入账单流水后，\n这里会展示趋势图和花销大头分析',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 趋势折线图 ----------------

class _TrendCard extends StatelessWidget {
  final List<Snapshot> snapshots;
  const _TrendCard({required this.snapshots});

  @override
  Widget build(BuildContext context) {
    final pts = snapshots.indexed.toList();
    final maxV = snapshots.map((s) => s.totalCents).reduce((a, b) => a > b ? a : b) / 100;
    final minV = snapshots.map((s) => s.totalCents).reduce((a, b) => a < b ? a : b) / 100;
    final pad = ((maxV - minV) * 0.15).clamp(50.0, 5000.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('总资产趋势',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 4),
            Text('${fmtDate(snapshots.first.date)} ~ ${fmtDate(snapshots.last.date)} · ${snapshots.length} 次记录',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: LineChart(
                LineChartData(
                  minY: (minV - pad).clamp(0, double.infinity),
                  maxY: maxV + pad,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (v) =>
                        FlLine(color: const Color(0xFFEEEEEE), strokeWidth: 1),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 56,
                        getTitlesWidget: (v, meta) => Text(
                          '¥${(v / 10000).toStringAsFixed(1)}w',
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 10),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 1,
                        getTitlesWidget: (v, meta) {
                          final i = v.toInt();
                          if (i < 0 || i >= snapshots.length) {
                            return const SizedBox.shrink();
                          }
                          final d = snapshots[i].date.split('-');
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text('${d[1]}.${d[2]}',
                                style: TextStyle(
                                    color: Colors.grey.shade500,
                                    fontSize: 10)),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (spots) => spots
                          .map((s) => LineTooltipItem(
                                '¥ ${fmtCents((s.y * 100).round())}',
                                const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600)),
                              )
                          .toList(),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: pts
                          .map((e) =>
                              FlSpot(e.$1.toDouble(), e.$2.totalCents / 100))
                          .toList(),
                      isCurved: true,
                      curveSmoothness: 0.25,
                      color: const Color(0xFF00897B),
                      barWidth: 3,
                      dotData: FlDotData(
                        getDotPainter: (spot, percent, bar, index) =>
                            FlDotCirclePainter(
                          radius: 3.5,
                          color: const Color(0xFF00897B),
                          strokeWidth: 2,
                          strokeColor: Colors.white,
                        ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: const Color(0x2200897B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 资金构成饼图 ----------------

class _CompositionCard extends StatelessWidget {
  final List<Account> accounts;
  final Snapshot latest;
  const _CompositionCard({required this.accounts, required this.latest});

  @override
  Widget build(BuildContext context) {
    final slices = <(Account, int)>[];
    for (final a in accounts) {
      final amt = latest.amountOf(a.id!) ?? 0;
      if (amt > 0 && a.isActive) slices.add((a, amt));
    }
    if (slices.isEmpty) return const SizedBox.shrink();
    final total = slices.fold<int>(0, (s, e) => s + e.$2);

    const colors = [
      Color(0xFF00897B), Color(0xFFF9A825), Color(0xFF1565C0),
      Color(0xFF7B1FA2), Color(0xFFE05B4B), Color(0xFF43A047),
      Color(0xFF5D4037), Color(0xFF78909C),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('资金构成（${fmtDate(latest.date)}）',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 150,
                  height: 150,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 34,
                      sections: slices.indexed
                          .map((e) => PieChartSectionData(
                                value: e.$2.$2 / 100,
                                color: colors[e.$1 % colors.length],
                                radius: 26,
                                showTitle: false,
                              ))
                          .toList(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [
                      for (final (i, (a, amt)) in slices.indexed)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                    color: colors[i % colors.length],
                                    borderRadius: BorderRadius.circular(3)),
                              ),
                              const SizedBox(width: 6),
                              Text('${a.emoji} ${a.name}',
                                  style: const TextStyle(fontSize: 13)),
                              const Spacer(),
                              Text(
                                '${(amt / total * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 最近一期变化 ----------------

class _PeriodCard extends StatelessWidget {
  final List<Account> accounts;
  final Snapshot prev;
  final Snapshot latest;
  const _PeriodCard(
      {required this.accounts, required this.prev, required this.latest});

  @override
  Widget build(BuildContext context) {
    final diff = latest.totalCents - prev.totalCents;
    final days = _dayDiff(prev.date, latest.date);
    // 存钱类账户（零钱/理财/投资）的净增加 = 存下来的钱
    var saved = 0;
    final changes = <(Account, int)>[];
    for (final a in accounts.where((a) => a.isActive)) {
      final p = prev.amountOf(a.id!) ?? 0;
      final c = latest.amountOf(a.id!) ?? 0;
      if (c != p) changes.add((a, c - p));
      if (a.type.isSaving) saved += (c - p);
    }
    saved = saved > 0 ? saved : 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('最近一期变化',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade800)),
                const Spacer(),
                Text('${fmtDate(prev.date)} → ${fmtDate(latest.date)}',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            if (days > 0)
              Text('共 $days 天',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  diff >= 0
                      ? '总资产 +${fmtCents(diff)}'
                      : '总资产 ${fmtCents(diff)}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: diff >= 0
                        ? const Color(0xFF2E9E5B)
                        : const Color(0xFFE05B4B),
                  ),
                ),
                if (saved > 0) ...[
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00897B).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('存下 ¥ ${fmtCents(saved)}',
                        style: const TextStyle(
                            color: Color(0xFF00897B),
                            fontWeight: FontWeight.w700,
                            fontSize: 13)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            for (final (a, c) in changes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Text('${a.emoji} ${a.name}',
                        style: const TextStyle(fontSize: 13)),
                    const Spacer(),
                    Text(
                      c > 0 ? '+${fmtCents(c)}' : fmtCents(c),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c > 0
                            ? const Color(0xFF2E9E5B)
                            : const Color(0xFFE05B4B),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '总资产变化中：${saved > 0 ? '有 ¥ ${fmtCents(saved)} 进入了零钱理财/投资账户（这是存下来的），' : ''}'
              '其余差额主要来自日常花销与收入。导入账单流水可精确到每一类花多少。',
              style: TextStyle(
                  color: Colors.grey.shade600, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  int _dayDiff(String a, String b) {
    final d1 = DateTime.parse(a);
    final d2 = DateTime.parse(b);
    return d2.difference(d1).inDays;
  }
}

// ---------------- 流水消费分析 ----------------

class _TxnAnalysisCard extends StatelessWidget {
  final List<Txn> txns;
  final String? start; // 最近快照日期；区间内的流水才算
  const _TxnAnalysisCard({required this.txns, required this.start});

  @override
  Widget build(BuildContext context) {
    // 只统计最近一次快照之后导入的流水？不行——快照后用户导入的是"整月/整段时间"。
    // 简单策略：按全部导入流水统计总览 + Top。start 为空则全部。
    final inRange = start == null
        ? txns
        : txns.where((t) => t.date.compareTo(start!) >= 0).toList();
    final list = inRange.isEmpty ? txns : inRange; // 若区间内没有，退回全部

    var expenseTotal = 0;
    var expenseCount = 0;
    var incomeTotal = 0;
    var savedTotal = 0;
    var savedOut = 0;
    final byCat = <String, int>{};

    for (final t in list) {
      final def = categoryOf(t.category);
      if (def.isExpense) {
        expenseTotal += t.amountCents;
        expenseCount++;
        byCat[t.category] = (byCat[t.category] ?? 0) + t.amountCents;
      } else if (def.isIncome) {
        incomeTotal += t.amountCents;
      } else if (def.isTransfer) {
        // saving 类的负向 = 转入理财/投资（存钱）；transfer 忽略互转
        if (t.category == 'saving') {
          if (t.amountCents < 0) {
            savedTotal += t.amountCents.abs();
          } else {
            savedOut += t.amountCents;
          }
        }
      }
    }

    // 排序 Top 分类
    final sorted = byCat.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final absTotal = expenseTotal.abs();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('流水消费分析',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade800)),
                const Spacer(),
                Text('${list.length} 笔',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              inRange.isEmpty && start != null
                  ? '最近快照之后没有流水，以下统计全部已导入记录'
                  : '统计区间：${start == null ? '全部' : '$start 之后'} 的已导入流水',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _statBox('支出', '¥ ${fmtCents(expenseTotal.abs())}',
                    '$expenseCount 笔', const Color(0xFFE05B4B)),
                const SizedBox(width: 10),
                _statBox('收入', '¥ ${fmtCents(incomeTotal)}', '',
                    const Color(0xFF2E9E5B)),
                const SizedBox(width: 10),
                _statBox('存钱', '¥ ${fmtCents(savedTotal)}',
                    savedOut > 0 ? '取出 ${fmtCents(savedOut)}' : '',
                    const Color(0xFF00897B)),
              ],
            ),
            if (absTotal > 0) ...[
              const SizedBox(height: 18),
              Text('花钱大头',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade700)),
              const SizedBox(height: 10),
              // byCat 已升序（负值最前 = 支出最大在前），直接取前几个
              for (final e in sorted.take(6)) ...[
                if (e.value < 0) ...[
                  _CategoryBar(
                    def: categoryOf(e.key),
                    amount: e.value,
                    ratio: e.value.abs() / absTotal,
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ],
            const SizedBox(height: 8),
            Text(
              '提示：转账（如还款、信用卡、账户互转）不计入支出；'
              '「存钱」= 转入零钱通/理财通/基金等投资理财账户的金额。',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statBox(String label, String value, String sub, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w800),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (sub.isNotEmpty)
              Text(sub,
                  style: TextStyle(
                      color: Colors.grey.shade500, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  final CategoryDef def;
  final int amount;
  final double ratio;
  const _CategoryBar(
      {required this.def, required this.amount, required this.ratio});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
            width: 90,
            child: Text('${def.emoji} ${def.label}',
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: const Color(0xFFF0F0F0),
              valueColor:
                  const AlwaysStoppedAnimation(Color(0xFF00897B)),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 82,
          child: Text('¥ ${fmtCents(amount.abs())}',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

// ---------------- 单笔消费 TOP（大头 = 单笔金额） ----------------

class _TopExpensesCard extends StatelessWidget {
  final List<Txn> txns;
  final String? start;
  final Map<String?, Trip> tripById;
  final ValueChanged<Txn> onEdit;
  const _TopExpensesCard(
      {required this.txns,
      required this.start,
      required this.tripById,
      required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final list = _scoped();
    final top = topExpenses(list, n: 10);
    if (top.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('💸 单笔消费大头 TOP${top.length}',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 4),
            Text(_note(list.length),
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
            const SizedBox(height: 12),
            for (final (i, t) in top.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: InkWell(
                  onTap: () => onEdit(t),
                  borderRadius: BorderRadius.circular(8),
                  child: Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: i < 3
                              ? const Color(0xFFE05B4B).withValues(alpha: 0.12)
                              : const Color(0xFFF6F7F9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: i < 3
                                    ? const Color(0xFFE05B4B)
                                    : Colors.grey.shade600)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600),
                            ),
                            Text(
                              [
                                t.date,
                                categoryOf(t.category).label,
                                if (t.tripId != null)
                                  '🧳 ${tripById[t.tripId]?.name ?? '旅程'}',
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('¥ ${fmtCents(t.amountCents.abs())}',
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFE05B4B))),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Text('点击任意一笔可直接改名、改分类、换账户或归入旅程。',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  List<Txn> _scoped() {
    if (start == null) return txns;
    final inRange =
        txns.where((t) => t.date.compareTo(start!) >= 0).toList();
    return inRange.isEmpty ? txns : inRange;
  }

  String _note(int count) =>
      start == null ? '范围：全部已导入流水（$count 笔）' : '范围：最近快照($start)之后（$count 笔）';
}

// ---------------- 旅程（旅游）消费 ----------------

class _TripsCard extends StatelessWidget {
  final List<Trip> trips;
  final List<Txn> txns;
  const _TripsCard({required this.trips, required this.txns});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🧳 旅程消费',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 4),
            Text('把某段时间的消费归入一次旅程，看它一共花了多少',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
            const SizedBox(height: 6),
            for (final trip in trips)
              _tripRow(context, trip),
          ],
        ),
      ),
    );
  }

  Widget _tripRow(BuildContext context, Trip trip) {
    // 区间内自动包含 + 手动归入的
    final tripTxns =
        expenseOnly(txns.where(trip.includes).toList());
    final total = tripTxns.fold<int>(0, (s, t) => s + t.amountCents);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(trip.name,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      subtitle: Text(
        '${fmtDate(trip.startDate)} ~ ${fmtDate(trip.endDate)} · ${tripTxns.length} 笔'
        '${tripTxns.isEmpty ? '（还没有归入的消费）' : ''}',
        style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
      ),
      trailing: Text(
        total == 0 ? '—' : '¥ ${fmtCents(total.abs())}',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: total == 0 ? Colors.grey.shade400 : const Color(0xFFE05B4B),
        ),
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TxnsPage(initialTripId: trip.id))),
    );
  }
}

class _TripsEmptyCard extends StatelessWidget {
  const _TripsEmptyCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Text('🧳', style: TextStyle(fontSize: 22)),
        title: const Text('创建旅程（旅游）',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: const Text(
            '旅游时把机票/酒店/门票等消费归入一次旅程，统一看花了多少',
            style: TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const TxnsPage())),
      ),
    );
  }
}
