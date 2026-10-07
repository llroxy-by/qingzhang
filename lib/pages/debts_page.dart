import 'package:flutter/material.dart';

import '../main.dart';
import '../models/debt.dart';
import '../utils/format.dart';

/// 欠债编辑结果（null = 取消）
class DebtEditResult {
  final Debt debt;
  final bool deleted;
  const DebtEditResult({required this.debt, this.deleted = false});
}

/// 弹出欠债编辑底部表（新增 / 编辑 / 删除共用）
Future<DebtEditResult?> showDebtEditSheet(BuildContext context, {Debt? debt}) {
  return showModalBottomSheet<DebtEditResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _DebtEditSheet(debt: debt),
  );
}

class _DebtEditSheet extends StatefulWidget {
  final Debt? debt;
  const _DebtEditSheet({this.debt});

  @override
  State<_DebtEditSheet> createState() => _DebtEditSheetState();
}

class _DebtEditSheetState extends State<_DebtEditSheet> {
  // 控制器放 State（键盘收起/重建不丢）
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late DebtDirection _direction;
  late DateTime _date;
  late bool _settled;

  @override
  void initState() {
    super.initState();
    final d = widget.debt;
    _name = TextEditingController(text: d?.name ?? '');
    _amount = TextEditingController(
        text: d != null ? centsToInput(d.amountCents) : '');
    _note = TextEditingController(text: d?.note ?? '');
    _direction = d?.direction ?? DebtDirection.owe;
    _date = (d?.date != null && d!.date.isNotEmpty)
        ? DateTime.parse(d.date)
        : DateTime.now();
    _settled = d?.settled ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
      helpText: '选择日期',
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _save() {
    final name = _name.text.trim();
    final amtText = _amount.text.trim();
    if (name.isEmpty) {
      _toast('填一下对方是谁（如：老王、花呗）');
      return;
    }
    if (amtText.isEmpty) {
      _toast('填一下金额');
      return;
    }
    final cents = parseYuanToCents(amtText);
    if (cents == null || cents <= 0) {
      _toast('金额要大于 0');
      return;
    }
    final debt = Debt(
      id: widget.debt?.id,
      name: name,
      direction: _direction,
      amountCents: cents,
      date: _fmtDate(_date),
      note: _note.text.trim(),
      settled: _settled,
      createdAt: widget.debt?.createdAt ?? 0,
      updatedAt: widget.debt?.updatedAt ?? 0,
    );
    Navigator.pop(context, DebtEditResult(debt: debt));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.debt != null;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(isEdit ? '编辑欠债' : '记一笔欠债',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            SegmentedButton<DebtDirection>(
              segments: [
                for (final d in DebtDirection.values)
                  ButtonSegment(
                    value: d,
                    label: Text(d.label),
                    icon: Icon(
                      d == DebtDirection.owe
                          ? Icons.arrow_upward
                          : Icons.arrow_downward,
                      size: 16,
                    ),
                  ),
              ],
              selected: {_direction},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  setState(() => _direction = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '对方（如：老王、花呗）'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration:
                        const InputDecoration(labelText: '金额', prefixText: '¥ '),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(_fmtDate(_date)),
                    style: OutlinedButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: '备注（可空）'),
            ),
            if (isEdit) ...[
              const SizedBox(height: 4),
              SwitchListTile(
                value: _settled,
                onChanged: (v) => setState(() => _settled = v),
                title: Text(_settled ? '已结清 ✓' : '未结清',
                    style: const TextStyle(fontSize: 13)),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (isEdit) ...[
                  TextButton.icon(
                    onPressed: () => Navigator.pop(
                        context,
                        DebtEditResult(
                            debt: widget.debt!, deleted: true)),
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: Color(0xFFE05B4B)),
                    label: const Text('删除',
                        style: TextStyle(color: Color(0xFFE05B4B))),
                  ),
                  const Spacer(),
                ],
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('保存')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 欠债管理页：汇总 + 列表（筛选、新增、编辑、结清、删除）
class DebtPage extends StatefulWidget {
  const DebtPage({super.key});

  @override
  State<DebtPage> createState() => _DebtPageState();
}

class _DebtPageState extends State<DebtPage> {
  // 0 全部 / 1 未结清 / 2 已结清
  int _filter = 1;
  late Future<List<Debt>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Debt>> _load() async {
    final db = appState.db;
    final all = await db.listDebts();
    return all;
  }

  void _reload() {
    setState(() => _future = _load());
  }

  Future<void> _add() async {
    final result = await showDebtEditSheet(context);
    if (result == null || !mounted) return;
    if (result.deleted) return;
    await appState.db.insertDebt(result.debt);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已记录欠债')));
    }
    _reload();
  }

  Future<void> _edit(Debt d) async {
    final result = await showDebtEditSheet(context, debt: d);
    if (result == null || !mounted) return;
    if (result.deleted) {
      await appState.db.deleteDebt(d.id!);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已删除')));
      }
      _reload();
      return;
    }
    await appState.db.updateDebt(result.debt);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('欠债')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('记一笔'),
      ),
      body: SafeArea(
        child: FutureBuilder<List<Debt>>(
          future: _future,
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
                      Text('${snap.error}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12)),
                      const SizedBox(height: 10),
                      TextButton(
                          onPressed: _reload, child: const Text('重试')),
                    ],
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snap.data!;
            final shown = switch (_filter) {
              1 => all.where((d) => !d.settled).toList(),
              2 => all.where((d) => d.settled).toList(),
              _ => all,
            };
            final unsettled = all.where((d) => !d.settled).toList();
            var owe = 0;
            var lend = 0;
            for (final d in unsettled) {
              if (d.direction == DebtDirection.owe) {
                owe += d.amountCents;
              } else {
                lend += d.amountCents;
              }
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                _SummaryCard(owe: owe, lend: lend),
                const SizedBox(height: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('全部')),
                    ButtonSegment(value: 1, label: Text('未结清')),
                    ButtonSegment(value: 2, label: Text('已结清')),
                  ],
                  selected: {_filter},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  onSelectionChanged: (s) =>
                      setState(() => _filter = s.first),
                ),
                const SizedBox(height: 12),
                if (all.isEmpty)
                  _EmptyHint(
                    onAdd: _add,
                    text: '还没有欠债记录\n欠了谁 / 谁欠了你，点右下角记一笔',
                  )
                else if (shown.isEmpty)
                  _EmptyHint(
                    onAdd: null,
                    text: _filter == 2 ? '还没有已结清的记录' : '没有未结清的欠债，松了口气 😌',
                  )
                else
                  for (final d in shown) _DebtTile(debt: d, onTap: () => _edit(d)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final int owe; // 我欠（未结清）
  final int lend; // 别人欠我（未结清）
  const _SummaryCard({required this.owe, required this.lend});

  @override
  Widget build(BuildContext context) {
    final net = owe - lend;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('未结清合计',
                style: TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Stat(
                    label: '我欠的',
                    amount: owe,
                    color: const Color(0xFFE05B4B),
                  ),
                ),
                Container(
                  width: 1,
                  height: 36,
                  color: Colors.grey.shade200,
                ),
                Expanded(
                  child: _Stat(
                    label: '别人欠我',
                    amount: lend,
                    color: const Color(0xFF2E9E5B),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('净',
                    style:
                        TextStyle(fontSize: 13, color: Colors.black54)),
                const SizedBox(width: 8),
                Text(
                  net > 0
                      ? '净欠 ¥ ${fmtCents(net)}'
                      : net < 0
                          ? '净应收 ¥ ${fmtCents(-net)}'
                          : '两清，谁也不欠谁',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: net > 0
                        ? const Color(0xFFE05B4B)
                        : net < 0
                            ? const Color(0xFF2E9E5B)
                            : Colors.grey.shade600,
                  ),
                ),
                if (net < 0) ...[
                  const SizedBox(width: 6),
                  Text('（账上的钱比欠账多）',
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int amount;
  final Color color;
  const _Stat(
      {required this.label, required this.amount, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        const SizedBox(height: 4),
        Text('¥ ${fmtCents(amount)}',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}

class _DebtTile extends StatelessWidget {
  final Debt debt;
  final VoidCallback onTap;
  const _DebtTile({required this.debt, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isOwe = debt.direction == DebtDirection.owe;
    final color = isOwe
        ? const Color(0xFFE05B4B)
        : const Color(0xFF2E9E5B);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Icon(
            isOwe ? Icons.arrow_upward : Icons.arrow_downward,
            color: color,
            size: 20,
          ),
        ),
        title: Row(
          children: [
            Text(debt.name,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(width: 8),
            if (debt.settled)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('已结清',
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 11)),
              ),
          ],
        ),
        subtitle: Text(
          '${debt.date}${debt.note.isNotEmpty ? ' · ${debt.note}' : ''}',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          '¥ ${fmtCents(debt.amountCents)}',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: debt.settled ? Colors.grey.shade400 : color,
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  final VoidCallback? onAdd;
  const _EmptyHint({required this.text, this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          const Text('🧾', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 12),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, height: 1.6)),
          if (onAdd != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onAdd, child: const Text('记一笔')),
          ],
        ],
      ),
    );
  }
}
