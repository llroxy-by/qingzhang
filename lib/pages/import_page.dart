import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../models/account.dart';
import '../models/categories.dart';
import '../models/txn.dart';
import '../services/classifier.dart';
import '../services/bank_pdf_parser.dart';
import '../services/csv_importer.dart';
import '../services/encrypted_zip.dart';
import '../services/pdf_text_extractor.dart';
import '../utils/format.dart';
import 'mail_page.dart';
import 'txns_page.dart';

/// 导入页：选择账单文件 → 自动解析 + 分类 → 预览纠正 → 导入
/// 支持 CSV / XLSX / TXT / 加密 ZIP（招行）/ PDF（银行流水）
class ImportPage extends StatefulWidget {
  final int tick;
  const ImportPage({super.key, required this.tick});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  List<Txn>? _pending; // 当前待导入（已按选项过滤）
  List<Txn> _allParsed = []; // 本次文件解析出的全部（未过滤）
  String _platform = '';
  int _skipped = 0;
  List<String> _warnings = [];
  List<Map<String, Object?>> _userRules = [];
  List<Account> _accounts = [];
  String? _defaultAccountId; // "这份账单归属账户"（未匹配渠道的交易用它）
  bool _skipBankChannel = true; // 跳过银行卡渠道交易（防重复）
  bool _importing = false;
  int _existingCount = 0;
  bool _hasAccount = false; // 是否已设置云端账号（决定导入提示）
  // 文件处理状态（显示在页面内，不依赖一闪而过的 toast）
  String? _statusMsg;
  bool _busy = false;
  bool _statusErr = false;
  // 编辑弹层的输入框 controller 放在页面 State 上：
  // 避免 bottom sheet 因键盘收起等视图重建而丢失输入
  final TextEditingController _editNameCtrl = TextEditingController();
  final TextEditingController _editKwCtrl = TextEditingController();

  @override
  void dispose() {
    _editNameCtrl.dispose();
    _editKwCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadMeta();
  }

  Future<void> _loadMeta() async {
    final db = appState.db;
    final rules = await db.listUserRules();
    final count = await db.txnCount();
    final accounts = await db.listAccounts(onlyActive: true);
    final uid = await db.getMeta('userId');
    if (!mounted) return;
    setState(() {
      _userRules = rules;
      _existingCount = count;
      _accounts = accounts;
      _hasAccount = uid != null && uid.isNotEmpty;
    });
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'txt', 'zip', 'pdf'],
    );
    if (files.isEmpty) return;
    final file = files.single;
    try {
      final bytes = await file.readAsBytes();
      final lower = file.name.toLowerCase();
      if (lower.endsWith('.zip')) {
        await _handleZip(bytes);
      } else if (lower.endsWith('.pdf')) {
        await _handlePdf(bytes);
      } else {
        await _parseBytes(bytes, file.name);
      }
    } catch (e) {
      _setStatus('读取文件失败：$e', err: true);
    }
  }

  /// 打开邮箱账单页；用户选择附件解析成功后返回流水进入预览
  Future<void> _openMailFetch() async {
    final result = await Navigator.of(context).push<List<Txn>>(
      MaterialPageRoute(builder: (_) => const MailPage()),
    );
    if (result == null) return;
    _finishParsed(result, 'bank');
    _setStatus('邮箱账单解析出 ${result.length} 笔，可在下方预览');
  }

  /// 解析收尾公共步骤：分类 + 账户归属 + 进入预览
  void _finishParsed(List<Txn> txns, String platform,
      {List<String> warnings = const [], int skipped = 0}) {
    if (warnings.isNotEmpty && txns.isEmpty) {
      _toast(warnings.join('；'));
    }
    // 分类 + 账户归属
    final classified = txns
        .map((t) => t.copyWith(
            category: Classifier.classify(t.description, t.amountCents,
                userRules: _userRules)))
        .toList();
    if (!mounted) return;
    setState(() {
      _allParsed = classified;
      _platform = platform;
      _skipped = skipped;
      _warnings = warnings;
      _busy = false;
      _applyFiltersLocked();
    });
  }

  /// 银行 PDF 账单（招商银行交易流水等）
  Future<void> _handlePdf(Uint8List bytes) async {
    try {
      _setStatus('正在识别 PDF…', busy: true);
      final text = await extractPdfText(bytes);
      final txns = parseBankPdf(text);
      if (txns.isEmpty) {
        // 诊断：显示 pdfium 实际提取的文本前几行，便于适配解析器
        final preview = text
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .take(12)
            .join('\n');
        _setStatus('未能识别出流水。文本预览（前 12 行）：\n$preview',
            err: true);
      } else {
        _setStatus('识别到 ${txns.length} 笔流水，可在下方预览');
      }
      _finishParsed(txns, 'bank');
    } catch (e, st) {
      _setStatus('PDF 解析失败：$e', err: true);
      debugPrint('pdf 解析异常: $e\n$st');
    }
  }

  /// 加密 zip 账单（招行邮件附件：输密码 → 解出 PDF → 解析）
  Future<void> _handleZip(Uint8List bytes) async {
    final pwd = await _askPassword();
    if (pwd == null) return;
    if (pwd.isEmpty) {
      _setStatus('密码不能为空', err: true);
      return;
    }
    try {
      _setStatus('正在解压…', busy: true);
      final entries = decryptZipWithCentral(bytes, pwd);
      Uint8List? pdfBytes;
      String? pdfName;
      for (final e in entries.entries) {
        if (e.key.toLowerCase().endsWith('.pdf')) {
          pdfBytes = e.value;
          pdfName = e.key;
          break;
        }
      }
      if (pdfBytes == null) {
        _setStatus('压缩包里没找到 PDF 账单文件（共 ${entries.length} 个文件）',
            err: true);
        return;
      }
      _setStatus('解压成功，正在识别 PDF…', busy: true);
      final text = await extractPdfText(pdfBytes);
      final txns = parseBankPdf(text);
      if (txns.isEmpty) {
        // 诊断：显示 pdfium 实际提取的文本前几行，便于适配解析器
        final preview = text
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .take(12)
            .join('\n');
        _setStatus('未能识别出流水（$pdfName）。文本预览（前 12 行）：\n$preview',
            err: true);
      } else {
        _setStatus('识别到 ${txns.length} 笔流水（$pdfName），可在下方预览');
      }
      _finishParsed(txns, 'bank');
    } catch (e, st) {
      // 捕获所有异常（含 Error 类），避免静默失败
      final msg = '$e';
      if (msg.contains('密码错误')) {
        _setStatus('解压密码不对，请重新输入（招行邮件里的解压码每次不同）',
            err: true);
      } else {
        _setStatus('解压解析失败：$msg', err: true);
        debugPrint('zip 解析异常: $e\n$st');
      }
    }
  }

  Future<String?> _askPassword() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('压缩包密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('输入招行邮件里的解压密码：',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              decoration:
                  const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('解压解析')),
        ],
      ),
    );
  }

  Future<void> _parseBytes(Uint8List bytes, String fileName) async {
    try {
      final platform = _detectPlatform(fileName, bytes);
      final parsed = CsvImporter.parseBytes(bytes, fileName, source: platform);
      _finishParsed(parsed.txns, platform,
          warnings: parsed.warnings, skipped: parsed.skipped);
    } catch (e) {
      _setStatus('解析出错：$e', err: true);
    }
  }

  /// 按渠道关键词自动匹配账户；未匹配则用"默认归属账户"
  String? _matchAccount(Txn t) {
    if (t.channel.trim().isNotEmpty) {
      for (final a in _accounts) {
        final kws = a.channelKeywords
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (kws.any(t.channel.contains)) return a.id;
      }
    }
    return _defaultAccountId;
  }

  /// 重新生成 _pending（依据：跳过银行卡渠道 + 账户归属）
  void _applyFiltersLocked() {
    _pending = [
      for (final t in _allParsed)
        if (!(_skipBankChannel && CsvImporter.isBankChannel(t.channel)))
          t.copyWith(accountId: _matchAccount(t)),
    ];
  }

  void _applyFilters() {
    setState(_applyFiltersLocked);
  }

  String _detectPlatform(String fileName, Uint8List bytes) {
    // 优先用表头内容探测，xlsx 也先解码文本不行则用文件名提示
    if (fileName.toLowerCase().endsWith('.xlsx')) return 'wechat';
    try {
      final text = utf8.decode(bytes);
      final p = CsvImporter.detectPlatform(text);
      if (p != 'unknown') return p;
    } catch (_) {}
    return 'unknown';
  }

  Future<void> _confirmImport() async {
    final pending = _pending;
    if (pending == null || pending.isEmpty) return;
    setState(() => _importing = true);

    final db = appState.db;
    // 去重：与库内已有流水比对（同日期+摘要+金额 视为重复）
    final existing = await db.listTxns();
    final seen = <String>{};
    for (final t in existing) {
      seen.add('${t.date}|${t.description}|${t.amountCents}');
    }
    final fresh = pending
        .where((t) => !seen.contains('${t.date}|${t.description}|${t.amountCents}'))
        .toList();

    await db.insertTxns(fresh);
    appState.refresh();
    if (!mounted) return;
    setState(() {
      _pending = null;
      _platform = '';
      _importing = false;
      _existingCount += fresh.length;
    });
    _toast('已导入 ${fresh.length} 条'
        '${pending.length - fresh.length > 0 ? '，跳过 ${pending.length - fresh.length} 条重复' : ''}'
        '${_hasAccount ? '（去 设置→立即同步 可传到云端）' : ''}');
  }

  /// 判断两条交易是否为同一笔（date+描述+金额相同）
  bool _sameTxn(Txn a, Txn b) =>
      a.date == b.date &&
      a.description == b.description &&
      a.amountCents == b.amountCents;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  /// 页面内状态条（持久可见，方便排查）
  void _setStatus(String msg, {bool err = false, bool busy = false}) {
    if (!mounted) return;
    setState(() {
      _statusMsg = msg;
      _statusErr = err;
      _busy = busy;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            const Text('导入流水',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('已有 $_existingCount 条流水记录',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 16),
            // 导入引导卡
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('从账单文件导入',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade800)),
                    const SizedBox(height: 8),
                    Text(
                      '在支付宝 / 微信 / 银行 App 的账单页找到「导出账单」，'
                      '把导出的 CSV 或 Excel(xlsx) 文件发到手机（微信文件传输助手即可），'
                      '然后用下面按钮选择文件。'
                      '系统会自动识别格式与平台、按商户关键词分类，'
                      '并根据支付渠道避免与银行卡账单重复。',
                      style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                          height: 1.6),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: _openMailFetch,
                        icon: const Icon(Icons.mail_outline),
                        label: const Text('从邮箱获取（账单邮件自动拉取）'),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _pickFile,
                        icon: const Icon(Icons.upload_file),
                        label: const Text('选择账单文件（CSV / XLSX / ZIP / PDF）'),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14)),
                      ),
                    ),
                    if (_busy || _statusMsg != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _statusErr
                              ? const Color(0xFFFFEBEE)
                              : const Color(0xFFE8F5E9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(children: [
                          if (_busy)
                            const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                          else
                            Icon(
                              _statusErr
                                  ? Icons.error_outline
                                  : Icons.check_circle_outline,
                              size: 18,
                              color: _statusErr
                                  ? const Color(0xFFE05B4B)
                                  : const Color(0xFF2E9E5B),
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_statusMsg ?? '',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: _statusErr
                                        ? const Color(0xFFB71C1C)
                                        : const Color(0xFF1B5E20),
                                    height: 1.4)),
                          ),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.lightbulb_outline,
                            size: 16, color: Colors.grey.shade500),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '小技巧：招行账单邮件是加密压缩包，选 ZIP 后输入邮件里的解压密码即可。',
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (pending != null && pending.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildPendingCard(pending),
            ],
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.receipt_long_outlined,
                    color: Color(0xFF00897B)),
                title: const Text('流水记录',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text(
                    '查看已导入的流水：改分类 / 换账户 / 归入旅程 / 删除错账',
                    style: TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const TxnsPage()));
                  await _loadMeta();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingCard(List<Txn> pending) {
    final expenseCount = pending.where((t) => t.amountCents < 0).length;
    final incomeCount = pending.length - expenseCount;
    final filteredBankCount = _allParsed.length - pending.length;
    String? accountNameOf(String? id) {
      if (id == null) return null;
      for (final a in _accounts) {
        if (a.id == id) return a.name;
      }
      return null;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('解析结果',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade800)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00897B).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    CsvImporter.platformLabel(_platform),
                    style: const TextStyle(
                        color: Color(0xFF00897B),
                        fontSize: 12,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '解析 ${_allParsed.length} 笔'
              '${filteredBankCount > 0 ? '，其中银行卡渠道 $filteredBankCount 笔将跳过' : ''}'
              '（本次导入 $expenseCount 支出 / $incomeCount 收入）'
              '${_skipped > 0 ? '，跳过无效行 $_skipped' : ''}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
            if (_warnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('⚠ ${_warnings.join('；')}',
                    style: const TextStyle(
                        color: Color(0xFFE05B4B), fontSize: 12)),
              ),
            const SizedBox(height: 4),
            // ---- 防重复 & 账户归属选项 ----
            SwitchListTile(
              value: _skipBankChannel,
              onChanged: (v) {
                setState(() => _skipBankChannel = v);
                _applyFilters();
              },
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('跳过银行卡/信用卡渠道的交易（避免与银行卡账单重复）',
                  style: TextStyle(fontSize: 13)),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text('这份账单归属账户：',
                      style: TextStyle(
                          color: Colors.grey.shade700, fontSize: 13)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String?>(
                      value: _defaultAccountId,
                      isExpanded: true,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      hint: const Text('不指定', style: TextStyle(fontSize: 13)),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('不指定', style: TextStyle(fontSize: 13))),
                        for (final a in _accounts)
                          DropdownMenuItem<String?>(
                              value: a.id,
                              child: Text('${a.emoji} ${a.name}',
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (v) {
                        setState(() => _defaultAccountId = v);
                        _applyFilters();
                      },
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '归属用于余额推算与去重：支付渠道匹配账户关键词（设置→资金构成里配置）会自动归户，'
              '其余归到上面选的账户。渠道不明确的银行卡账单建议选对应银行卡。',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11, height: 1.5),
            ),
            const SizedBox(height: 6),
            Text('点击某条可修改分类；修改时可勾选"记住规则"以后自动归类。',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
            const SizedBox(height: 10),
            // 分类准确度提示
            _accuracyHint(pending),
            const SizedBox(height: 10),
            ...pending.take(30).map((t) => _TxnPreviewRow(
                  txn: t,
                  accountName: accountNameOf(t.accountId),
                  onTap: () => _openEditSheet(t),
                )),
            if (pending.length > 30)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('…共 ${pending.length} 条，导入后可在分析页查看完整统计',
                    style: TextStyle(
                        color: Colors.grey.shade500, fontSize: 12)),
              ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _importing ? null : _confirmImport,
                icon: _importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_done),
                label: Text(_importing ? '导入中…' : '导入这 ${pending.length} 条'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _accuracyHint(List<Txn> pending) {
    // 未知分类的比例
    final unknown =
        pending.where((t) => t.category == 'unknown').length;
    final total = pending.length;
    if (total == 0) return const SizedBox.shrink();
    final known = total - unknown;
    final pct = (known / total * 100).round();
    final color =
        pct >= 85 ? const Color(0xFF2E9E5B) : pct >= 60 ? const Color(0xFFF9A825) : const Color(0xFFE05B4B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            pct >= 85
                ? Icons.verified
                : pct >= 60
                    ? Icons.auto_awesome
                    : Icons.tune,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '自动分类命中 $known/$total（$pct%），未识别的点开改一下即可',
              style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // -------- 单条修改 --------

  Future<void> _openEditSheet(Txn txn) async {
    var category = txn.category;
    var remember = false;
    _editKwCtrl.text = txn.description.trim();
    _editNameCtrl.text = txn.description.trim();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('修改交易',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.grey.shade800)),
              const SizedBox(height: 10),
              Container(
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
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(txn.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    Text(
                      '¥ ${fmtCents(txn.amountCents.abs())}',
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
              const SizedBox(height: 12),
              TextField(
                controller: _editNameCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '交易名称（可改）',
                  hintText: '这笔钱花在哪/是什么',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              _CategoryGrid(
                selected: category,
                onSelect: (c) => setSheet(() => category = c),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: remember,
                onChanged: (v) => setSheet(() => remember = v ?? false),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('记住规则：包含下面关键词的自动归为此类',
                    style: TextStyle(fontSize: 13)),
                secondary: null,
              ),
              if (remember)
                TextField(
                  controller: _editKwCtrl,
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
                  onPressed: () async {
                    final def = categoryOf(category);
                    final newDesc = _editNameCtrl.text.trim().isEmpty
                        ? txn.description
                        : _editNameCtrl.text.trim();
                    if (remember && _editKwCtrl.text.trim().isNotEmpty) {
                      await appState.db
                          .addUserRule(_editKwCtrl.text.trim(), category);
                      await _loadMeta(); // 刷新 _userRules
                    }
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop();
                    setState(() {
                      // 修改名称+分类：同时作用于本次过滤列表与全量列表
                      List<Txn> mapCat(List<Txn> list) => [
                            for (final t in list)
                              _sameTxn(t, txn)
                                  ? t.copyWith(
                                      description: newDesc,
                                      category: category)
                                  : t,
                          ];
                      _pending = mapCat(_pending!);
                      _allParsed = mapCat(_allParsed);
                      if (remember) {
                        // 用新规则重分类尚未识别的交易
                        _allParsed = [
                          for (final t in _allParsed)
                            if (t.category == 'unknown')
                              t.copyWith(
                                  category: Classifier.classify(
                                      t.description,
                                      t.amountCents,
                                      userRules: _userRules))
                            else
                              t,
                        ];
                        _applyFiltersLocked();
                      }
                    });
                    if (def.isExpense || def.isIncome || def.isTransfer) {
                      _toast('已设为「${def.emoji} ${def.label}」'
                          '${remember ? '，并记住了规则' : ''}');
                    }
                  },
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryGrid extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;
  const _CategoryGrid({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in kCategories)
          ChoiceChip(
            label: Text('${c.emoji} ${c.label}'),
            selected: selected == c.key,
            onSelected: (_) => onSelect(c.key),
            visualDensity: VisualDensity.compact,
            selectedColor: const Color(0xFF00897B).withValues(alpha: 0.15),
            labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: selected == c.key ? FontWeight.w700 : FontWeight.w400,
              color: selected == c.key
                  ? const Color(0xFF00695C)
                  : Colors.grey.shade800,
            ),
          ),
      ],
    );
  }
}

class _TxnPreviewRow extends StatelessWidget {
  final Txn txn;
  final VoidCallback onTap;
  final String? accountName;
  const _TxnPreviewRow(
      {required this.txn, required this.onTap, this.accountName});

  @override
  Widget build(BuildContext context) {
    final def = categoryOf(txn.category);
    final expense = txn.amountCents < 0;
    final subParts = [
      txn.date,
      def.label,
      if (txn.channel.trim().isNotEmpty) txn.channel.trim(),
      if (accountName != null) '归入：$accountName',
    ];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xFF00897B).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(def.emoji, style: const TextStyle(fontSize: 15)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(txn.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(subParts.join(' · '),
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
                fontSize: 13,
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
