import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../models/categories.dart';
import '../models/txn.dart';
import '../services/classifier.dart';
import '../utils/format.dart';

/// 随手记一笔：不导银行流水时，把刷卡/大额消费随手记下来，
/// 参与分类统计与"单笔消费大头"。字段精简：类型/金额/描述/分类/日期。
class QuickTxnSheet extends StatefulWidget {
  const QuickTxnSheet({super.key});

  @override
  State<QuickTxnSheet> createState() => _QuickTxnSheetState();
}

class _QuickTxnSheetState extends State<QuickTxnSheet> {
  // controller 必须放在 State（键盘收起/视图重建不会丢输入）
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();
  bool _expense = true; // true=支出 false=收入
  DateTime _date = DateTime.now();
  String? _category; // null = 按描述自动识别
  bool _saving = false;

  static const _expenseCats = [
    'food', 'transport', 'shopping', 'housing',
    'entertainment', 'medical', 'gift', 'other_expense',
  ];
  static const _incomeCats = [
    'income_salary', 'income_bonus', 'income_transfer', 'income_other',
  ];

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  List<String> get _cats => _expense ? _expenseCats : _incomeCats;

  Future<void> _save() async {
    if (_saving) return;
    final amountStr = _amountCtrl.text.trim().replaceAll(',', '');
    final amount = double.tryParse(amountStr);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入有效金额')));
      return;
    }
    final desc = _descCtrl.text.trim();
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('写一句是什么消费/收入')));
      return;
    }
    final cents = (amount * 100).round() * (_expense ? -1 : 1);
    var category = _category ??= Classifier.classify(desc, cents);
    setState(() => _saving = true);
    await appState.db.insertTxns([
      Txn(
        date: _dateStr(_date),
        description: desc,
        amountCents: cents,
        source: 'manual',
        category: category,
      ),
    ]);
    appState.refresh();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已记一笔${_expense ? '支出' : '收入'}：'
            '${_expense ? '-' : '+'}¥ ${fmtCents(cents.abs())}（${categoryOf(category).label}）')));
  }

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 键盘顶起
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('✏️ 随手记一笔',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final p = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                        helpText: '日期',
                      );
                      if (p != null) setState(() => _date = p);
                    },
                    child: Text('📅 ${_dateStr(_date)}'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 支出/收入切换
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('支出')),
                  ButtonSegment(value: false, label: Text('收入')),
                ],
                selected: {_expense},
                onSelectionChanged: (s) =>
                    setState(() => _expense = s.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStateProperty.all(
                      const TextStyle(fontSize: 13)),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_expense ? '- ¥' : '+ ¥',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: _expense
                              ? const Color(0xFFE05B4B)
                              : const Color(0xFF2E9E5B))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _amountCtrl,
                      autofocus: true,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]')),
                      ],
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w700),
                      decoration: const InputDecoration(
                        hintText: '0.00',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _descCtrl,
                onChanged: (_) {
                  // 描述变化后若之前是"自动识别"，保持自动；若手动选过分类则不打扰
                },
                decoration: const InputDecoration(
                  labelText: '写一句：如 超市买菜、给妈妈转账',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Text('分类（不选则按描述自动识别）',
                  style: TextStyle(
                      color: Colors.grey.shade600, fontSize: 11)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('✨ 自动', style: TextStyle(fontSize: 12)),
                    selected: _category == null,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _category = null),
                  ),
                  for (final c in _cats)
                    ChoiceChip(
                      avatar: Text(categoryOf(c).emoji,
                          style: const TextStyle(fontSize: 12)),
                      label: Text(categoryOf(c).label,
                          style: const TextStyle(fontSize: 12)),
                      selected: _category == c,
                      visualDensity: VisualDensity.compact,
                      onSelected: (sel) =>
                          setState(() => _category = sel ? c : null),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check),
                  label: Text(_saving ? '保存中…' : '记下来'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
