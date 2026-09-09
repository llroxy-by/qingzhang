import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../models/account.dart';
import '../models/snapshot.dart';
import '../utils/format.dart';

/// 记一笔快照：录入当天各账户余额。
/// 预填"参考值"（最近一次快照的余额），用户只需改有变化的数字。
class SnapshotEditPage extends StatefulWidget {
  const SnapshotEditPage({super.key});

  @override
  State<SnapshotEditPage> createState() => _SnapshotEditPageState();
}

class _SnapshotEditPageState extends State<SnapshotEditPage> {
  DateTime _date = DateTime.now();
  List<Account> _accounts = [];
  final Map<String, TextEditingController> _controllers = {};
  Snapshot? _reference; // 预填参考快照（有则取其余额）
  Map<String, int> _flowHints = {}; // 账户id → 参考日之后到本次日期的流水净额
  bool _loaded = false;
  bool _saving = false;

  String get _dateStr =>
      '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 智能预填：
  /// 预填值 = 参考值（上次快照余额，或账户期初余额）+
  ///         参考日期之后到本次日期之间的该账户流水净额
  Future<void> _load() async {
    final db = appState.db;
    final accounts = await db.listAccounts(onlyActive: true);
    // 参考值：今天已有快照优先，否则最近一次
    final ref = await db.snapshotOn(_dateStr) ?? await db.latestSnapshot();

    final controllers = <String, TextEditingController>{};
    final hints = <String, int>{};
    for (final a in accounts) {
      // 确定 基础值 与 流水窗口起点
      int base;
      String? windowStart;
      if (ref != null) {
        base = ref.amountOf(a.id!) ?? 0;
        windowStart = ref.date;
      } else if (a.openingDate != null && a.openingCents != null) {
        base = a.openingCents!;
        windowStart = a.openingDate!;
      } else {
        base = 0;
      }
      var net = 0;
      if (windowStart != null && windowStart.compareTo(_dateStr) < 0) {
        net = await db.txnNetByAccount(a.id!, windowStart, _dateStr);
      }
      hints[a.id!] = net;
      final prefill = base + net;
      controllers[a.id!] = TextEditingController(
          text: prefill == 0 ? '' : centsToInput(prefill));
    }
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _reference = ref;
      _flowHints = hints;
      _controllers
        ..clear()
        ..addAll(controllers);
      _loaded = true;
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _totalCents {
    var sum = 0;
    for (final a in _accounts) {
      sum += parseYuanToCents(_controllers[a.id!]?.text ?? '') ?? 0;
    }
    return sum;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: '选择快照日期',
    );
    if (picked != null && picked != _date) {
      setState(() => _date = picked);
      await _load(); // 重新取该日期的参考值
    }
  }

  Future<void> _save() async {
    if (_accounts.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请先到 设置 → 资金构成 添加账户')));
      return;
    }
    final entries = <SnapshotEntry>[];
    for (final a in _accounts) {
      final v = parseYuanToCents(_controllers[a.id!]?.text ?? '');
      entries.add(SnapshotEntry(
          snapshotId: '', accountId: a.id!, amountCents: v ?? 0));
    }
    setState(() => _saving = true);
    await appState.db.saveSnapshot(
        Snapshot(date: _dateStr, entries: entries));
    appState.refresh();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_accounts.isEmpty) {
      // 还没有任何账户：先去设置添加资金构成
      return Scaffold(
        appBar: AppBar(title: const Text('记一笔快照')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('💳', style: TextStyle(fontSize: 48)),
                const SizedBox(height: 12),
                const Text('还没有资金构成',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('请先到底部「设置」→ 资金构成 添加你的账户\n（如：招行卡、零钱通…）',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.grey.shade600, height: 1.6)),
              ],
            ),
          ),
        ),
      );
    }
    final refIsSameDay =
        _reference != null && _reference!.date == _dateStr;

    return Scaffold(
      appBar: AppBar(
        title: Text(refIsSameDay ? '编辑快照' : '记一笔快照'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: Column(
        children: [
          // 日期选择 + 参考提示
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                ActionChip(
                  avatar: const Icon(Icons.calendar_today, size: 16),
                  label: Text(fmtDate(_dateStr)),
                  onPressed: _pickDate,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _reference == null
                        ? '首次记录，请填所有账户余额'
                        : refIsSameDay
                            ? '编辑今天的快照'
                            : '参考 ${fmtDate(_reference!.date)} 的余额，只改有变化的即可',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: _accounts.length,
              itemBuilder: (context, i) {
                final a = _accounts[i];
                final net = _flowHints[a.id!] ?? 0;
                final prev = _reference?.amountOf(a.id!);
                String refText;
                if (prev != null) {
                  refText = '上次 ¥ ${fmtCents(prev)}';
                  if (net != 0) {
                    refText += ' · 流水 ${net > 0 ? '+' : ''}${fmtCents(net)} 推算';
                  }
                } else if (a.openingCents != null && a.openingDate != null) {
                  refText =
                      '期初(${fmtDate(a.openingDate!)}) ¥ ${fmtCents(a.openingCents!)}';
                  if (net != 0) {
                    refText += ' · 流水 ${net > 0 ? '+' : ''}${fmtCents(net)} 推算';
                  }
                } else {
                  refText = '暂无参考，请填写余额';
                }
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Text(a.emoji, style: const TextStyle(fontSize: 22)),
                    title: Text(a.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      refText,
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12),
                    ),
                    trailing: SizedBox(
                      width: 130,
                      child: TextField(
                        controller: _controllers[a.id!],
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]')),
                        ],
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(
                          prefixText: '¥ ',
                          border: InputBorder.none,
                          hintText: '0',
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
          ),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('合计', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  Text('¥ ${fmtCents(_totalCents)}',
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w800)),
                ],
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 14)),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_saving ? '保存中…' : '保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
