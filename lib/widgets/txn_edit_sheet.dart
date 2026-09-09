import 'package:flutter/material.dart';

import '../models/account.dart';
import '../models/trip.dart';
import '../models/txn.dart';
import '../utils/format.dart';
import 'category_grid.dart';

/// 编辑结果：null = 取消；否则按字段应用
class TxnEditResult {
  final String description; // 编辑后的名称（未改时等于原值）
  final String category;
  final bool remember;
  final String? keyword; // remember 为 true 时保存的关键词
  final String? accountId; // null = 不指定
  final String? tripId; // null = 不归入旅程
  final bool deleted; // true = 删除该条

  const TxnEditResult({
    required this.description,
    required this.category,
    this.remember = false,
    this.keyword,
    this.accountId,
    this.tripId,
    this.deleted = false,
  });
}

/// 通用"编辑一笔流水"底部弹层：改名 / 改分类 / 记住规则 / 归属账户 / 归入旅程 / 删除
Future<TxnEditResult?> showTxnEditSheet(
  BuildContext context, {
  required Txn txn,
  required List<Account> accounts,
  required List<Trip> trips,
  List<Map<String, Object?>> userRules = const [],
}) {
  return showModalBottomSheet<TxnEditResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _TxnEditBody(
      txn: txn,
      accounts: accounts,
      trips: trips,
      userRules: userRules,
    ),
  );
}

/// 弹层内容：StatefulWidget，controller 存于 State（生命周期内只创建一次，
/// 键盘收起/视图重建不会丢失输入）
class _TxnEditBody extends StatefulWidget {
  final Txn txn;
  final List<Account> accounts;
  final List<Trip> trips;
  final List<Map<String, Object?>> userRules;

  const _TxnEditBody({
    required this.txn,
    required this.accounts,
    required this.trips,
    required this.userRules,
  });

  @override
  State<_TxnEditBody> createState() => _TxnEditBodyState();
}

class _TxnEditBodyState extends State<_TxnEditBody> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _kwCtrl;
  late String _category;
  bool _remember = false;
  String? _accountId;
  String? _tripId;

  @override
  void initState() {
    super.initState();
    _nameCtrl =
        TextEditingController(text: widget.txn.description.trim());
    _kwCtrl =
        TextEditingController(text: widget.txn.description.trim());
    _category = widget.txn.category;
    _accountId = widget.txn.accountId;
    _tripId = widget.txn.tripId;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _kwCtrl.dispose();
    super.dispose();
  }

  String get _finalName {
    final t = _nameCtrl.text.trim();
    return t.isEmpty ? widget.txn.description : t;
  }

  void _finish({bool deleted = false}) {
    Navigator.of(context).pop(TxnEditResult(
      description: _finalName,
      category: _category,
      remember: _remember,
      keyword: _remember ? _kwCtrl.text.trim() : null,
      accountId: _accountId,
      tripId: _tripId,
      deleted: deleted,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final txn = widget.txn;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('编辑流水',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.grey.shade800)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Color(0xFFE05B4B)),
                  tooltip: '删除这笔',
                  onPressed: () => _finish(deleted: true),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF6F7F9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Text(txn.date,
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 12)),
                  const Spacer(),
                  Text(
                    '${txn.amountCents < 0 ? '-' : '+'}¥ ${fmtCents(txn.amountCents.abs())}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: txn.amountCents > 0
                          ? const Color(0xFF2E9E5B)
                          : const Color(0xFFE05B4B),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _nameCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '交易名称（可改）',
                hintText: '这笔钱花在哪/是什么',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Text('分类',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const SizedBox(height: 6),
            CategoryGrid(
              selected: _category,
              onSelect: (c) => setState(() => _category = c),
            ),
            const SizedBox(height: 4),
            // 账户归属
            DropdownButtonFormField<String?>(
              initialValue: _accountId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '归属账户',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('不指定')),
                for (final a in widget.accounts)
                  DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text('${a.emoji} ${a.name}',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _accountId = v),
            ),
            const SizedBox(height: 10),
            // 旅程归属
            DropdownButtonFormField<String?>(
              initialValue: _tripId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '归入旅程（旅游等）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('不归入旅程')),
                for (final tr in widget.trips)
                  DropdownMenuItem<String?>(
                      value: tr.id,
                      child: Text('🧳 ${tr.name}',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _tripId = v),
            ),
            const SizedBox(height: 10),
            // 记住规则
            CheckboxListTile(
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('记住规则：包含下面关键词的自动归为此类',
                  style: TextStyle(fontSize: 13)),
            ),
            if (_remember)
              TextField(
                controller: _kwCtrl,
                decoration: const InputDecoration(
                  labelText: '关键词（可精简，如：美团、滴滴）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => _finish(),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text('保存修改'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
