import 'package:flutter/material.dart';

import '../main.dart';
import '../models/account.dart';
import '../models/categories.dart';
import '../models/trip.dart';
import '../models/txn.dart';
import '../services/analytics.dart';
import '../services/classifier.dart';
import '../utils/format.dart';
import '../widgets/txn_edit_sheet.dart';

/// 流水记录管理：查看/筛选已导入流水，编辑分类/账户/旅程，删除，创建旅程
class TxnsPage extends StatefulWidget {
  final String? initialTripId;
  const TxnsPage({super.key, this.initialTripId});

  @override
  State<TxnsPage> createState() => _TxnsPageState();
}

/// 排序方式
enum TxnSort {
  timeDesc('时间 ↓', byTime: true, ascending: false),
  timeAsc('时间 ↑', byTime: true, ascending: true),
  amountDesc('金额 ↓', byTime: false, ascending: true),
  amountAsc('金额 ↑', byTime: false, ascending: false);

  const TxnSort(this.label, {required this.byTime, required this.ascending});
  final String label;
  final bool byTime; // 按时间分组排序；否则按金额平铺
  final bool ascending; // 金额/日期升序与否
}

class _TxnsPageState extends State<TxnsPage> {
  List<Txn> _txns = [];
  List<Account> _accounts = [];
  List<Trip> _trips = [];
  List<Map<String, Object?>> _rules = [];
  bool _loaded = false;

  /// 筛选：null=全部；'other'=其他兜底分类；String=旅程 id
  Object? _filter;
  TxnSort _sort = TxnSort.timeDesc;
  // 搜索 + 日期范围筛选
  final TextEditingController _searchCtrl = TextEditingController();
  String? _dateFrom; // yyyy-MM-dd（含）
  String? _dateTo; // yyyy-MM-dd（含）

  @override
  void initState() {
    super.initState();
    _filter = widget.initialTripId;
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = appState.db;
    final txns = await db.listTxns();
    final accounts = await db.listAccounts();
    final trips = await db.listTrips();
    final rules = await db.listUserRules();
    if (!mounted) return;
    setState(() {
      _txns = txns;
      _accounts = accounts;
      _trips = trips;
      _rules = rules;
      _loaded = true;
    });
  }

  List<Txn> get _filtered {
    List<Txn> base;
    if (_filter == null) {
      base = _txns;
    } else if (_filter == 'other') {
      // "其他"兜底分类（分类器没认出的都归到这）
      const others = {'unknown', 'other_expense', 'other_income'};
      base = _txns.where((t) => others.contains(t.category)).toList();
    } else {
      final tripId = _filter as String;
      Trip? trip;
      for (final t in _trips) {
        if (t.id == tripId) {
          trip = t;
          break;
        }
      }
      if (trip == null) return const [];
      // 旅程流水 = 手动归入 + 日期在旅程区间内（自动包含）
      base = _txns.where(trip.includes).toList();
    }
    // 关键词搜索（描述/商户名）
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      base = base
          .where((t) =>
              t.description.toLowerCase().contains(q) ||
              (t.channel.isNotEmpty && t.channel.toLowerCase().contains(q)) ||
              categoryOf(t.category).label.contains(q))
          .toList();
    }
    // 日期范围
    if (_dateFrom != null && _dateFrom!.isNotEmpty) {
      base = base.where((t) => t.date.compareTo(_dateFrom!) >= 0).toList();
    }
    if (_dateTo != null && _dateTo!.isNotEmpty) {
      base = base.where((t) => t.date.compareTo(_dateTo!) <= 0).toList();
    }
    return base;
  }

  /// 打开日期范围选择（快捷范围 + 自定义）
  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final today = _d(now);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                dense: true,
                leading: const Icon(Icons.clear_all),
                title: const Text('全部日期'),
                onTap: () => Navigator.pop(ctx, 'all')),
            ListTile(
                dense: true,
                leading: const Icon(Icons.date_range),
                title: const Text('近 7 天'),
                onTap: () => Navigator.pop(ctx, '7')),
            ListTile(
                dense: true,
                leading: const Icon(Icons.date_range),
                title: const Text('近 30 天'),
                onTap: () => Navigator.pop(ctx, '30')),
            ListTile(
                dense: true,
                leading: const Icon(Icons.date_range),
                title: const Text('近 90 天'),
                onTap: () => Navigator.pop(ctx, '90')),
            ListTile(
                dense: true,
                leading: const Icon(Icons.today),
                title: const Text('今年'),
                onTap: () => Navigator.pop(ctx, 'year')),
            ListTile(
                dense: true,
                leading: const Icon(Icons.edit_calendar_outlined),
                title: const Text('自定义区间…'),
                onTap: () => Navigator.pop(ctx, 'custom')),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'all') {
      setState(() {
        _dateFrom = null;
        _dateTo = null;
      });
      return;
    }
    if (choice == 'year') {
      setState(() {
        _dateFrom = '${now.year}-01-01';
        _dateTo = today;
      });
      return;
    }
    if (choice == 'custom') {
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(now.year, now.month, now.day + 365),
        initialDateRange: (_dateFrom != null && _dateTo != null)
            ? DateTimeRange(
                start: DateTime.parse(_dateFrom!),
                end: DateTime.parse(_dateTo!))
            : null,
        helpText: '选择要查看的日期范围',
      );
      if (range == null) return;
      setState(() {
        _dateFrom = _d(range.start);
        _dateTo = _d(range.end);
      });
      return;
    }
    final days = int.parse(choice);
    final start = now.subtract(Duration(days: days - 1));
    setState(() {
      _dateFrom = _d(start);
      _dateTo = today;
    });
  }

  String? get _dateLabel {
    if (_dateFrom == null || _dateTo == null) return null;
    final a = _dateFrom!.substring(5).replaceAll('-', '/');
    final b = _dateTo!.substring(5).replaceAll('-', '/');
    return _dateFrom == _dateTo ? a : '$a ~ $b';
  }

  // ---------- 旅程 ----------

  Future<void> _createTrip() async {
    final nameCtrl = TextEditingController();
    DateTime start = DateTime.now().subtract(const Duration(days: 7));
    DateTime end = DateTime.now();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('创建旅程（如旅游）'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: '名称（如：十一云南游）'),
              ),
              const SizedBox(height: 4),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined, size: 20),
                title: const Text('开始日期', style: TextStyle(fontSize: 13)),
                trailing: Text(fmtDate(_d(start)),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                onTap: () async {
                  final p = await showDatePicker(
                    context: ctx,
                    initialDate: start,
                    firstDate: DateTime(2020),
                    lastDate: end,
                    helpText: '旅程开始日期',
                  );
                  if (p != null) setDlg(() => start = p);
                },
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_available_outlined,
                    size: 20),
                title: const Text('结束日期', style: TextStyle(fontSize: 13)),
                trailing: Text(fmtDate(_d(end)),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                onTap: () async {
                  final p = await showDatePicker(
                    context: ctx,
                    initialDate: end,
                    firstDate: start,
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                    helpText: '旅程结束日期',
                  );
                  if (p != null) setDlg(() => end = p);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;

    final trip = Trip(
      name: nameCtrl.text.trim(),
      startDate: _d(start),
      endDate: _d(end),
    );
    final tripId = await appState.db.insertTrip(trip);
    // 列出区间内消费让用户勾选归属
    final candidates = _txns
        .where((t) =>
            t.amountCents < 0 &&
            t.date.compareTo(_d(start)) >= 0 &&
            t.date.compareTo(_d(end)) <= 0)
        .toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      appState.refresh();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('旅程「${trip.name}」已创建（区间内没有消费流水，可之后单条编辑归入）')));
      return;
    }
    final picked = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => _TripPickPage(trip: trip, candidates: candidates),
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      await appState.db.setTxnTripBulk(picked.toList(), tripId);
    }
    appState.refresh();
    await _load();
    if (!mounted) return;
    if (picked == null || picked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('旅程「${trip.name}」已创建，未勾选交易（可之后单条编辑归入）')));
    }
  }

  String _d(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// 当前筛选的旅程对象（chips 选中旅程时）
  Trip? get _currentTrip {
    if (_filter is! String || _filter == 'other') return null;
    for (final t in _trips) {
      if (t.id == _filter) return t;
    }
    return null;
  }

  /// 把区间外的相关流水（机票、返程后 AA 等）手动加入当前旅程
  Future<void> _addExtraTripTxns() async {
    final trip = _currentTrip;
    if (trip == null) return;
    final inTrip = _txns.where(trip.includes).map((t) => t.id).toSet();
    final candidates = _txns
        .where((t) => t.amountCents < 0 && !inTrip.contains(t.id))
        .toList();
    if (candidates.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没有可添加的支出流水（区间外的都在旅程里了）')));
      return;
    }
    final picked = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => _TripPickPage(
            trip: trip,
            candidates: candidates,
            defaultSelectAll: false), // 区间外流水：默认不勾选，避免误加入
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      await appState.db.setTxnTripBulk(picked.toList(), trip.id!);
      appState.refresh();
      if (mounted) await _load();
    }
  }

  Future<void> _deleteTrip(Trip trip) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除旅程「${trip.name}」？'),
        content: const Text('其下流水不会被删除，只是解除旅程关联。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE05B4B)),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await appState.db.deleteTrip(trip.id!);
      appState.refresh();
      if (mounted) await _load();
    }
  }

  /// 管理旅程：列出并可删除
  Future<void> _manageTrips() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('管理旅程'),
        content: SizedBox(
          width: double.maxFinite,
          child: _trips.isEmpty
              ? const Text('还没有旅程',
                  style: TextStyle(color: Colors.grey))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in _trips)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Text('🧳', style: TextStyle(fontSize: 18)),
                        title: Text(t.name,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '${fmtDate(t.startDate)} ~ ${fmtDate(t.endDate)}',
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 11)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Color(0xFFE05B4B)),
                          onPressed: () async {
                            Navigator.pop(ctx); // 关闭弹窗再删，避免 dialog 中刷新
                            await _deleteTrip(t);
                          },
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 按当前规则（内置+自定义）重新分类流水
  Future<void> _reclassify() async {
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('重新分类流水'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              '用最新规则重新判断流水分类。\n转账/提现/存取类会被识别为"中性"（不计入消费大头）。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 0),
            child: const Text('只重新分类"其他支出 / 其他收入"类（推荐）'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 1),
            child: const Text('全部重新分类（会覆盖手动修改）',
                style: TextStyle(color: Color(0xFFE05B4B))),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 1) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('全部重新分类？'),
          content: const Text('会用规则覆盖你之前手动改过的分类，确定吗？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE05B4B)),
                child: const Text('全部重新分类')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final rules = await appState.db.listUserRules();
    final changes = <String, String>{};
    for (final t in _txns) {
      if (choice == 0 && !{'unknown','other_expense','other_income'}.contains(t.category)) continue;
      final newCat = Classifier.classify(t.description, t.amountCents,
          userRules: rules);
      if (newCat != t.category) {
        changes[t.id!] = newCat;
      }
    }
    if (changes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('没有需要重新分类的流水')));
      }
      return;
    }
    await appState.db.batchSetTxnCategory(changes);
    appState.refresh();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已重新分类 ${changes.length} 条（中性存取不计入消费）')));
    }
  }

  // ---------- 单条编辑 ----------

  Future<void> _editTxn(Txn txn) async {
    final result = await showTxnEditSheet(
      context,
      txn: txn,
      accounts: _accounts.where((a) => a.isActive).toList(),
      trips: _trips,
      userRules: _rules,
    );
    if (result == null) return;
    if (result.deleted) {
      await appState.db.deleteTxn(txn.id!);
      appState.refresh();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已删除这笔流水')));
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
    await _load();
    if (mounted) {
      final def = categoryOf(result.category);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已更新为「${def.emoji} ${def.label}」'
              '${result.remember ? '，并记住了规则' : ''}')));
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final list = _filtered;
    final tripById = {for (final t in _trips) t.id: t};

    return Scaffold(
      appBar: AppBar(
        title: Text('流水记录（${list.length}）'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '旅程管理',
            onSelected: (v) {
              if (v == 'create') _createTrip();
              if (v == 'manage') _manageTrips();
              if (v == 'reclassify') _reclassify();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'create',
                  child: Row(children: [
                    Icon(Icons.add_business_outlined, size: 20),
                    SizedBox(width: 8),
                    Text('创建旅程'),
                  ])),
              if (_trips.isNotEmpty)
                const PopupMenuItem(
                    value: 'manage',
                    child: Row(children: [
                      Icon(Icons.edit_calendar_outlined, size: 20),
                      SizedBox(width: 8),
                      Text('管理旅程'),
                    ])),
              const PopupMenuItem(
                  value: 'reclassify',
                  child: Row(children: [
                    Icon(Icons.auto_fix_high_outlined,
                        size: 20, color: Color(0xFF00897B)),
                    SizedBox(width: 8),
                    Text('重新分类流水'),
                  ])),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 旅程 chips
          if (_trips.isNotEmpty || _filter == 'other')
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: const Text('🗂 其他类'),
                    selected: _filter == 'other',
                    onSelected: (_) => setState(() => _filter = 'other'),
                    visualDensity: VisualDensity.compact,
                  ),
                  for (final t in _trips) ...[
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text('🧳 ${t.name}'),
                      selected: _filter == t.id,
                      onSelected: (_) =>
                          setState(() => _filter = _filter == t.id ? null : t.id),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                  if (_filter is String && _filter != 'other') ...[
                    const SizedBox(width: 6),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: const Text('区间外流水'),
                      visualDensity: VisualDensity.compact,
                      onPressed: _addExtraTripTxns,
                    ),
                  ],
                ],
              ),
            ),
          const Divider(height: 1),
          // 搜索 + 日期筛选
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: '🔍 搜索描述/商户…',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear,
                                  size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() {});
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickDateRange,
                  icon: const Icon(Icons.calendar_month,
                      size: 16),
                  label: Text(_dateLabel ?? '日期'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          // 排序行
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
            child: Row(
              children: [
                Text('${list.length} 笔',
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 12)),
                const Spacer(),
                PopupMenuButton<TxnSort>(
                  initialValue: _sort,
                  tooltip: '排序方式',
                  onSelected: (s) => setState(() => _sort = s),
                  itemBuilder: (_) => [
                    for (final s in TxnSort.values)
                      PopupMenuItem(
                        value: s,
                        child: Row(
                          children: [
                            Icon(
                              s == _sort
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              size: 18,
                              color: s == _sort
                                  ? const Color(0xFF00897B)
                                  : Colors.grey.shade400,
                            ),
                            const SizedBox(width: 10),
                            Text(s.label,
                                style: const TextStyle(fontSize: 14)),
                          ],
                        ),
                      ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00897B).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.swap_vert,
                            size: 16, color: Color(0xFF00897B)),
                        const SizedBox(width: 4),
                        Text('排序：${_sort.label}',
                            style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF00897B),
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text('没有匹配的流水',
                        style: TextStyle(color: Colors.grey.shade500)))
                : _sort.byTime
                    ? _buildGrouped(list, tripById)
                    : _buildFlat(list, tripById),
          ),
        ],
      ),
    );
  }

  /// 时间排序：按日期分组展示（组头显示日期与当日小计，组内大额在前）
  Widget _buildGrouped(List<Txn> list, Map<String?, Trip> tripById) {
    final accountById = {for (final a in _accounts) a.id: a};
    // 按日期分组
    final grouped = <String, List<Txn>>{};
    for (final t in list) {
      grouped.putIfAbsent(t.date, () => []).add(t);
    }
    final dates = grouped.keys.toList();
    dates.sort((a, b) =>
        _sort.ascending ? a.compareTo(b) : b.compareTo(a));

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: dates.length,
      itemBuilder: (context, di) {
        final date = dates[di];
        final dayTxns = grouped[date]!..sort(
            (a, b) => b.amountCents.compareTo(a.amountCents));
        final dayTotal = sumCents(dayTxns);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  Text(fmtDate(date),
                      style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(
                    dayTotal < 0
                        ? '支 ¥ ${fmtCents(dayTotal.abs())}'
                        : '收 ¥ ${fmtCents(dayTotal)}',
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ),
            ),
            for (final t in dayTxns)
              _TxnRow(
                txn: t,
                tripName: t.tripId != null ? tripById[t.tripId]?.name : null,
                account: accountById[t.accountId],
                onTap: () => _editTxn(t),
              ),
          ],
        );
      },
    );
  }

  /// 金额排序：全部平铺，不分组；每行显示日期
  Widget _buildFlat(List<Txn> list, Map<String?, Trip> tripById) {
    final accountById = {for (final a in _accounts) a.id: a};
    final sorted = List.of(list);
    sorted.sort((a, b) => _sort.ascending
        ? a.amountCents.compareTo(b.amountCents)
        : b.amountCents.compareTo(a.amountCents));
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final t = sorted[i];
        return _TxnRow(
          txn: t,
          showDate: true,
          tripName: t.tripId != null ? tripById[t.tripId]?.name : null,
          account: accountById[t.accountId],
          onTap: () => _editTxn(t),
        );
      },
    );
  }
}

class _TxnRow extends StatelessWidget {
  final Txn txn;
  final String? tripName;
  final Account? account;
  final VoidCallback onTap;
  final bool showDate; // 平铺模式下行内显示日期
  const _TxnRow(
      {required this.txn,
      required this.tripName,
      required this.account,
      required this.onTap,
      this.showDate = false});

  @override
  Widget build(BuildContext context) {
    final def = categoryOf(txn.category);
    final expense = txn.amountCents < 0;
    final isUnknown = txn.category == 'unknown';
    final parts = [
      if (showDate) txn.date,
      def.label,
      if (tripName != null) '🧳$tripName',
      if (account != null) account!.name,
      if (txn.channel.trim().isNotEmpty) txn.channel.trim(),
    ];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: (isUnknown ? const Color(0xFFE05B4B)
                        : const Color(0xFF00897B))
                    .withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Text(def.emoji, style: const TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(txn.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: isUnknown
                              ? const Color(0xFFE05B4B)
                              : null)),
                  Text(parts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 11)),
                ],
              ),
            ),
            Text(
              '${expense ? '-' : '+'}¥ ${fmtCents(txn.amountCents.abs())}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: expense
                    ? const Color(0xFFE05B4B)
                    : const Color(0xFF2E9E5B),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 创建旅程后：勾选区间内消费归入该旅程（defaultSelectAll 默认全选）
class _TripPickPage extends StatefulWidget {
  final Trip trip;
  final List<Txn> candidates;
  final bool defaultSelectAll;
  const _TripPickPage({
    required this.trip,
    required this.candidates,
    this.defaultSelectAll = true,
  });

  @override
  State<_TripPickPage> createState() => _TripPickPageState();
}

class _TripPickPageState extends State<_TripPickPage> {
  late final Set<String> _picked = widget.defaultSelectAll
      ? {for (final t in widget.candidates) t.id!}
      : <String>{};
  // 候选流水搜索 + 日期范围
  final TextEditingController _qCtrl = TextEditingController();
  String? _from;
  String? _to;

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  List<Txn> get _shown {
    var list = widget.candidates;
    final q = _qCtrl.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((t) =>
              t.description.toLowerCase().contains(q) ||
              categoryOf(t.category).label.contains(q))
          .toList();
    }
    if (_from != null) {
      list = list.where((t) => t.date.compareTo(_from!) >= 0).toList();
    }
    if (_to != null) {
      list = list.where((t) => t.date.compareTo(_to!) <= 0).toList();
    }
    return list;
  }

  String _dstr(DateTime x) =>
      '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';

  Future<void> _pickRange() async {
    final now = DateTime.now();
    String? f;
    String? t;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                dense: true,
                title: const Text('全部日期'),
                onTap: () => Navigator.pop(ctx, 'all')),
            ListTile(
                dense: true,
                title: const Text('近 30 天'),
                onTap: () => Navigator.pop(ctx, '30')),
            ListTile(
                dense: true,
                title: const Text('近 90 天'),
                onTap: () => Navigator.pop(ctx, '90')),
            ListTile(
                dense: true,
                title: const Text('自定义区间…'),
                onTap: () => Navigator.pop(ctx, 'custom')),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice == 'custom') {
      if (!mounted) return; // context 跨 async 间隙前保护
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(now.year, now.month + 3),
      );
      if (range == null || !mounted) return;
      f = _dstr(range.start);
      t = _dstr(range.end);
    } else if (choice != 'all') {
      f = _dstr(now.subtract(Duration(days: int.parse(choice) - 1)));
      t = _dstr(now);
    }
    if (!mounted) return;
    setState(() {
      _from = f;
      _to = t;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final total = shown
        .where((t) => _picked.contains(t.id))
        .fold<int>(0, (s, t) => s + t.amountCents);
    final dateLabel = (_from == null || _to == null)
        ? null
        : (_from == _to
            ? _from!.substring(5)
            : '${_from!.substring(5)} ~ ${_to!.substring(5)}');
    return Scaffold(
      appBar: AppBar(
        title: Text('归入「${widget.trip.name}」'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Text(
                  '${fmtDate(widget.trip.startDate)} ~ ${fmtDate(widget.trip.endDate)} · '
                  '已选 ${_picked.length}/${widget.candidates.length} 笔',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const Spacer(),
                Text('合计 ¥ ${fmtCents(total.abs())}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _qCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: '🔍 搜索描述/商户…',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      suffixIcon: _qCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _qCtrl.clear();
                                setState(() {});
                              }),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickRange,
                  icon: const Icon(Icons.calendar_month, size: 15),
                  label: Text(dateLabel ?? '日期',
                      style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
          if (shown.length != widget.candidates.length)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('显示 ${shown.length}/${widget.candidates.length} 笔',
                    style: TextStyle(
                        color: Colors.grey.shade500, fontSize: 11)),
              ),
            ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text('没有符合条件的流水',
                        style: TextStyle(color: Colors.grey.shade500)))
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final t = shown[i];
                      final def = categoryOf(t.category);
                return CheckboxListTile(
                  value: _picked.contains(t.id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _picked.add(t.id!);
                    } else {
                      _picked.remove(t.id);
                    }
                  }),
                  dense: true,
                  secondary: Text(def.emoji, style: const TextStyle(fontSize: 18)),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(t.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5)),
                      ),
                      Text(
                        '-¥ ${fmtCents(t.amountCents.abs())}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5),
                      ),
                    ],
                  ),
                  subtitle: Text('${fmtDate(t.date)} · ${def.label}',
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 11)),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_picked),
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: Text('确定：把这 ${_picked.length} 笔计入旅程'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
