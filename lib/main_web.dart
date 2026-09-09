// 轻账 Web 只读端入口（flutter build web --target=lib/main_web.dart）
// 功能：切换查看每个用户的数据（总资产/构成/趋势/消费分析/旅程/流水）
// 数据直接读服务器 API（同源），无本地存储、无写入
// Web 只读端（web-only 入口，dart:html 是预期用法）
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'models/account.dart';
import 'models/categories.dart';
import 'models/snapshot.dart';
import 'models/trip.dart';
import 'models/txn.dart';
import 'services/analytics.dart';
import 'utils/format.dart';

void main() {
  runApp(const QingzhangWeb());
}

class QingzhangWeb extends StatelessWidget {
  const QingzhangWeb({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '轻账 · Web',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF00897B)),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
      ),
      home: const WebHome(),
    );
  }
}

// 是否本地调试（flutter run -d chrome --dart-define=WEB_API_LOCAL=true 时连本机 18080）
const bool kIsWebLocal =
    bool.fromEnvironment('WEB_API_LOCAL', defaultValue: false);

String _apiBase() {
  if (kIsWebLocal) return 'http://127.0.0.1:18080';
  // 部署后与 Web 页面同源（服务器托管 web + api）
  final base = Uri.base;
  return '${base.scheme}://${base.authority}';
}

class WebHome extends StatefulWidget {
  const WebHome({super.key});

  @override
  State<WebHome> createState() => _WebHomeState();
}

class _User {
  final int id;
  final String nickname;
  _User(this.id, this.nickname);
}

class _WebHomeState extends State<WebHome> {
  List<_User>? _users;
  String? _error;
  _User? _current;
  Map<String, dynamic>? _data;
  String? _loadErr;
  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  Future<Map<String, dynamic>> _api(String path, {String method = 'GET', Object? body}) async {
    final headers = {'Content-Type': 'application/json'};
    http.Response resp;
    if (method == 'POST') {
      resp = await http
          .post(Uri.parse('${_apiBase()}$path'), headers: headers, body: jsonEncode(body ?? {}))
          .timeout(const Duration(seconds: 30));
    } else {
      resp = await http
          .get(Uri.parse('${_apiBase()}$path'), headers: headers)
          .timeout(const Duration(seconds: 30));
    }
    final decoded = resp.bodyBytes.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(utf8.decode(resp.bodyBytes)) as Map).cast<String, dynamic>();
    if (resp.statusCode != 200) {
      throw Exception((decoded['error'] ?? 'HTTP ${resp.statusCode}').toString());
    }
    return decoded;
  }

  Future<void> _fetchUsers() async {
    setState(() {
      _users = null;
      _error = null;
    });
    try {
      final r = await _api('/api/users');
      final users = (r['users'] as List)
          .map((u) {
            final m = u as Map;
            return _User(int.parse(m['id'].toString()), m['nickname'].toString());
          })
          .toList();
      setState(() => _users = users);
      if (users.isEmpty) {
        setState(() => _error = '还没有任何用户（手机 App 设置昵称并同步后会出现）');
      } else if (_current == null) {
        // 自动进入第一个用户（免登录直接看报表；下拉可切换）
        _selectUser(users.first);
      }
    } catch (e) {
      setState(() => _error = '无法连接服务器：$e\n\n服务器地址：${_apiBase()}');
    }
  }

  Future<void> _selectUser(_User u) async {
    setState(() {
      _current = u;
      _data = null;
      _loadErr = null;
    });
    try {
      final r = await _api('/api/data/${u.id}');
      setState(() => _data = r);
    } catch (e) {
      setState(() => _loadErr = '加载数据失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_current == null || _data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('轻账 · Web 只读')),
        body: _buildSelect(),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('${_current!.nickname} 的账本'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: DropdownButton<_User>(
              value: _current,
              underline: const SizedBox.shrink(),
              items: [
                for (final u in _users ?? const <_User>[])
                  DropdownMenuItem(
                      value: u, child: Text(u.nickname)),
              ],
              onChanged: (u) {
                if (u != null) _selectUser(u);
              },
            ),
          ),
        ],
      ),
      body: _loadErr != null
          ? Center(child: Text(_loadErr!))
          : ReportView(data: _data!, userId: _current!.id),
    );
  }

  Widget _buildSelect() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: _users == null && _error == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('👥', style: TextStyle(fontSize: 52)),
                  const SizedBox(height: 12),
                  Text(_error ?? '选择要查看的用户：',
                      style: TextStyle(
                          color: Colors.grey.shade700, height: 1.6),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  if (_users != null && _users!.isNotEmpty)
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final u in _users!)
                            Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: const Color(0xFF00897B)
                                      .withValues(alpha: 0.12),
                                  child: Text(
                                    u.nickname.characters.first,
                                    style: const TextStyle(
                                        color: Color(0xFF00897B),
                                        fontWeight: FontWeight.w800),
                                  ),
                                ),
                                title: Text(u.nickname,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _selectUser(u),
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _fetchUsers,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新'),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------- 报表视图 ----------------

class ReportView extends StatelessWidget {
  final Map<String, dynamic> data;
  final int userId;
  const ReportView({super.key, required this.data, required this.userId});

  @override
  Widget build(BuildContext context) {
    // 解析服务器行 → 模型
    final accountRows =
        (data['accounts'] as List? ?? const []).cast<Map<String, dynamic>>();
    final accounts = [
      for (final r in accountRows)
        if ((r['deleted'] ?? 0) == 0) Account.fromMap(r),
    ];
    final accountById = {for (final a in accounts) a.id: a};

    final snapRows =
        (data['snapshots'] as List? ?? const []).cast<Map<String, dynamic>>();
    final entryRows = (data['snapshot_entries'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final snapshots = _assembleSnapshots(snapRows, entryRows)
      ..sort((a, b) => a.date.compareTo(b.date));

    final txnRows =
        (data['txns'] as List? ?? const []).cast<Map<String, dynamic>>();
    final txns = [
      for (final r in txnRows)
        if ((r['deleted'] ?? 0) == 0) Txn.fromMap(r),
    ];

    final tripRows =
        (data['trips'] as List? ?? const []).cast<Map<String, dynamic>>();
    final trips = [
      for (final r in tripRows)
        if ((r['deleted'] ?? 0) == 0) Trip.fromMap(r),
    ];
    final tripById = {for (final t in trips) t.id: t};

    final latest =
        snapshots.isEmpty ? null : snapshots.last;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        if (latest != null) ...[
          _totalCard(latest, snapshots.length >= 2 ? snapshots[snapshots.length - 2] : null),
          const SizedBox(height: 12),
          _compoCard(accounts, latest),
        ] else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text('该用户还没有快照数据',
                  style: TextStyle(color: Colors.grey.shade600)),
            ),
          ),
        if (snapshots.length >= 2) ...[
          const SizedBox(height: 12),
          _trendCard(snapshots),
        ],
        if (txns.isNotEmpty) ...[
          const SizedBox(height: 12),
          _txnStatsCard(txns, tripById),
        ] else ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('📊 流水分析（暂无可分析数据）',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey.shade800)),
                  const SizedBox(height: 8),
                  Text(
                    '云端还没有这个用户的流水。\n'
                    '让数据出现的两种方式：\n'
                    '① 手机「轻账」导入账单后，到 设置→立即同步（流水会传到云端）\n'
                    '② 本页右上角切换用户后重新加载',
                    style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12.5,
                        height: 1.7),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (trips.isNotEmpty) ...[
          const SizedBox(height: 12),
          _tripCard(trips, txns),
        ],
        if (txns.isNotEmpty) ...[
          const SizedBox(height: 12),
          _txnListCard(txns, accountById, tripById),
        ],
      ],
    );
  }

  List<Snapshot> _assembleSnapshots(
      List<Map<String, dynamic>> snapRows,
      List<Map<String, dynamic>> entryRows) {
    final byId = <String, List<Map<String, dynamic>>>{};
    for (final e in entryRows) {
      if ((e['deleted'] ?? 0) == 1) continue;
      byId.putIfAbsent(e['snapshot_id'].toString(), () => []).add(e);
    }
    return [
      for (final r in snapRows)
        if ((r['deleted'] ?? 0) == 0)
          Snapshot.fromMap(r).withEntries([
            for (final e in byId[r['id'].toString()] ?? const [])
              SnapshotEntry.fromMap(e),
          ]),
    ];
  }

  Widget _totalCard(Snapshot latest, Snapshot? prev) {
    final diff = prev == null ? null : latest.totalCents - prev.totalCents;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF00897B), Color(0xFF26A69A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('总资产 · ${fmtDate(latest.date)}',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 4),
          Text('¥ ${fmtCents(latest.totalCents)}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w800)),
          if (diff != null)
            Text(
              '相比上次快照 ${diff >= 0 ? '+' : '-'}¥ ${fmtCents(diff.abs())}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
        ],
      ),
    );
  }

  Widget _compoCard(List<Account> accounts, Snapshot latest) {
    final rows = [
      for (final a in accounts)
        if (a.isActive) (a, latest.amountOf(a.id!) ?? 0),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('资金构成',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 8),
            for (final (a, amt) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Text('${a.emoji} ${a.name}',
                      style: const TextStyle(fontSize: 13.5)),
                  const Spacer(),
                  Text('¥ ${fmtCents(amt)}',
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700)),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _trendCard(List<Snapshot> snapshots) {
    final maxV = snapshots
        .map((s) => s.totalCents / 100)
        .reduce((a, b) => a > b ? a : b);
    final minV = snapshots
        .map((s) => s.totalCents / 100)
        .reduce((a, b) => a < b ? a : b);
    final pad = ((maxV - minV) * 0.15).clamp(50.0, 5000.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('总资产趋势',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 12),
            SizedBox(
              height: 150,
              child: LineChart(LineChartData(
                minY: (minV - pad).clamp(0, double.infinity),
                maxY: maxV + pad,
                gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (v) => FlLine(
                        color: const Color(0xFFEEEEEE), strokeWidth: 1)),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 50,
                      getTitlesWidget: (v, meta) => Text(
                        '¥${(v / 10000).toStringAsFixed(1)}w',
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 9),
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
                                  color: Colors.grey.shade500, fontSize: 9)),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: snapshots.indexed
                        .map((e) => FlSpot(
                            e.$1.toDouble(), e.$2.totalCents / 100))
                        .toList(),
                    isCurved: true,
                    color: const Color(0xFF00897B),
                    barWidth: 3,
                    dotData: FlDotData(show: true),
                    belowBarData: BarAreaData(
                        show: true, color: const Color(0x2200897B)),
                  ),
                ],
              )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _txnStatsCard(List<Txn> txns, Map<String?, Trip> tripById) {
    final expense = expenseOnly(txns);
    final expenseTotal = sumCents(expense);
    final incomeTotal = sumCents(
        txns.where((t) => categoryOf(t.category).isIncome));
    final byCat = expenseByCategory(txns);
    final sorted = byCat.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final absTotal = expenseTotal.abs();
    final topSingles = topExpenses(txns, n: 10);

    Widget stat(String label, String value, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(children: [
              Text(label,
                  style: TextStyle(
                      color: Colors.grey.shade600, fontSize: 11)),
              Text(value,
                  style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('流水消费分析（${txns.length} 笔）',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 10),
            Row(children: [
              stat('总支出', '¥ ${fmtCents(expenseTotal.abs())}',
                  const Color(0xFFE05B4B)),
              const SizedBox(width: 8),
              stat('总收入', '¥ ${fmtCents(incomeTotal)}',
                  const Color(0xFF2E9E5B)),
            ]),
            if (absTotal > 0) ...[
              const SizedBox(height: 14),
              Text('分类分布',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade700)),
              const SizedBox(height: 8),
              for (final e in sorted.reversed.take(6))
                if (e.value < 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      SizedBox(
                          width: 80,
                          child: Text(
                              '${categoryOf(e.key).emoji} ${categoryOf(e.key).label}',
                              style: const TextStyle(fontSize: 12.5))),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: (e.value.abs() / absTotal).clamp(0.0, 1.0),
                            minHeight: 8,
                            backgroundColor: const Color(0xFFF0F0F0),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('¥ ${fmtCents(e.value.abs())}',
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700)),
                    ]),
                  ),
              const SizedBox(height: 14),
              Text('💸 单笔消费 TOP10',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade700)),
              const SizedBox(height: 6),
              for (final (i, t) in topSingles.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(
                        width: 20,
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: i < 3
                                    ? const Color(0xFFE05B4B)
                                    : Colors.grey.shade500))),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600)),
                            Text(
                              [
                                t.date,
                                categoryOf(t.category).label,
                                if (t.tripId != null)
                                  '🧳 ${tripById[t.tripId]?.name ?? ''}',
                              ].join(' · '),
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 10),
                            ),
                          ]),
                    ),
                    Text('¥ ${fmtCents(t.amountCents.abs())}',
                        style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFE05B4B))),
                  ]),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tripCard(List<Trip> trips, List<Txn> txns) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🧳 旅程消费',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 4),
            for (final trip in trips)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Builder(builder: (context) {
                  final t = expenseOnly(
                      txns.where((x) => x.tripId == trip.id).toList());
                  final total = sumCents(t);
                  return Row(children: [
                    Text(trip.name,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text(
                        '${fmtDate(trip.startDate)}~${fmtDate(trip.endDate)} · ${t.length}笔',
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 11)),
                    const Spacer(),
                    Text(total == 0 ? '—' : '¥ ${fmtCents(total.abs())}',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: total == 0
                                ? Colors.grey.shade400
                                : const Color(0xFFE05B4B))),
                  ]);
                }),
              ),
          ],
        ),
      ),
    );
  }

  Widget _txnListCard(List<Txn> txns, Map<String?, Account> accountById,
      Map<String?, Trip> tripById) {
    final sorted = List.of(txns)
      ..sort((a, b) => b.date.compareTo(a.date));
    final recent = sorted.take(200).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('流水明细（最近 ${recent.length} 笔）',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800)),
            const SizedBox(height: 6),
            for (final t in recent)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Text(categoryOf(t.category).emoji,
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          Text(
                            [
                              t.date,
                              categoryOf(t.category).label,
                              if (t.tripId != null)
                                '🧳${tripById[t.tripId]?.name ?? ''}',
                              if (t.accountId != null)
                                accountById[t.accountId]?.name ?? '',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 10),
                          ),
                        ]),
                  ),
                  Text(
                    '${t.amountCents < 0 ? '-' : '+'}¥ ${fmtCents(t.amountCents.abs())}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: t.amountCents < 0
                          ? const Color(0xFFE05B4B)
                          : const Color(0xFF2E9E5B),
                    ),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
