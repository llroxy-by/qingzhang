import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/bank_pdf_parser.dart';
import '../services/encrypted_zip.dart';
import '../services/mail_service.dart';
import '../services/pdf_text_extractor.dart';

/// 邮箱账单：配置 QQ 邮箱（IMAP 授权码）→ 服务器拉取招商银行账单邮件
/// → 选附件 → zip 输密码解压 / pdf 直接识别 → 解析成流水返回上一页导入
class MailPage extends StatefulWidget {
  const MailPage({super.key});

  @override
  State<MailPage> createState() => _MailPageState();
}

class _MailPageState extends State<MailPage> {
  bool _loaded = false;
  bool _configured = false;
  String _email = '';
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _codeCtrl = TextEditingController();
  bool _busy = false;
  String? _status;
  bool _statusErr = false;
  List<Map<String, dynamic>> _mails = [];
  bool _loadingList = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final cfg = await MailService.getConfig();
      if (!mounted) return;
      setState(() {
        _configured = (cfg['configured'] ?? false) as bool;
        _email = (cfg['email'] ?? '') as String;
        _loaded = true;
      });
      if (_configured) await _fetchMails();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _status = '连接服务器失败：$e';
        _statusErr = true;
      });
    }
  }

  void _setStatus(String msg, {bool err = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _statusErr = err;
    });
  }

  Future<void> _saveAndFetch() async {
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (email.isEmpty || code.isEmpty) {
      _setStatus('请填写 QQ 邮箱和授权码', err: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await MailService.saveConfig(email, code);
      setState(() {
        _configured = true;
        _email = email;
      });
      _setStatus('配置已保存，正在连接邮箱…');
      await _fetchMails();
    } catch (e) {
      _setStatus('$e', err: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetchMails() async {
    setState(() => _loadingList = true);
    try {
      final mails = await MailService.listMails();
      if (!mounted) return;
      setState(() {
        _mails = mails;
        _loadingList = false;
        if (mails.isEmpty) {
          _status = '近 90 天没有带 zip/pdf 附件的邮件';
          _statusErr = false;
        } else {
          _status = '找到 ${mails.length} 封账单邮件，点附件开始导入';
          _statusErr = false;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingList = false;
        _status = '$e';
        _statusErr = true;
      });
    }
  }

  /// 点附件：下载 → zip 解密 / pdf 识别 → 解析 → pop 回导入页
  Future<void> _openAttachment(Map<String, dynamic> mail, Map att) async {
    final uid = mail['uid'] as int;
    final part = att['part'] as String;
    final name = (att['filename'] ?? 'attachment') as String;
    setState(() {
      _busy = true;
      _status = '正在下载「$name」…';
      _statusErr = false;
    });
    try {
      final bytes = await MailService.downloadAttachment(uid, part);
      if (!mounted) return;
      setState(() => _status = '下载完成，正在解析…');
      final lower = name.toLowerCase();
      Uint8List? pdfBytes;
      String? pdfName = name;
      if (lower.endsWith('.zip')) {
        final pwd = await _askPassword();
        if (pwd == null) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        final entries = decryptZipWithCentral(
            Uint8List.fromList(bytes), pwd);
        Uint8List? inner;
        for (final e in entries.entries) {
          if (e.key.toLowerCase().endsWith('.pdf')) {
            inner = e.value;
            pdfName = e.key;
            break;
          }
        }
        if (inner == null) {
          if (mounted) {
            setState(() {
              _busy = false;
              _status = '压缩包里没有 PDF（共 ${entries.length} 个文件）';
              _statusErr = true;
            });
          }
          return;
        }
        pdfBytes = inner;
      } else {
        pdfBytes = Uint8List.fromList(bytes);
      }
      final text = await extractPdfText(pdfBytes);
      final txns = parseBankPdf(text);
      if (!mounted) return;
      if (txns.isEmpty) {
        // 诊断：显示 pdfium 实际提取的文本前几行，便于适配解析器
        final preview = text
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .take(12)
            .join('\n');
        setState(() {
          _busy = false;
          _status = '未能从「$pdfName」中识别出流水\n文本预览（前 12 行）：\n$preview';
          _statusErr = true;
        });
        return;
      }
      setState(() => _busy = false);
      // 返回流水给导入页
      Navigator.of(context).pop(txns);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = e.toString().contains('密码错误')
            ? '解压密码不对，请重试'
            : '处理失败：$e';
        _statusErr = true;
      });
    }
  }

  Future<String?> _askPassword() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('压缩包密码'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration:
              const InputDecoration(labelText: '招行邮件里的解压密码'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('邮箱账单')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!_configured) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('📧 配置 QQ 邮箱',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Text(
                            '用于接收银行（招行/工行等）和支付宝的账单邮件。'
                            '授权码获取：\n'
                            'QQ 邮箱网页版 → 设置 → 账户 → 开启 IMAP/SMTP → 生成授权码',
                            style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 12.5,
                                height: 1.6),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _emailCtrl,
                            decoration: const InputDecoration(
                              labelText: 'QQ 邮箱地址',
                              hintText: 'xxx@qq.com',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _codeCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: '授权码（不是 QQ 密码）',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _saveAndFetch,
                              icon: const Icon(Icons.link),
                              label: Text(_busy ? '连接中…' : '保存并拉取账单'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.mark_email_read_outlined,
                        color: Color(0xFF00897B)),
                    title: Text('已连接：$_email',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('点附件即可导入；解压密码需手动输入'),
                    trailing: TextButton(
                      onPressed: () {
                        _emailCtrl.text = _email;
                        setState(() {
                          _configured = false;
                          _codeCtrl.clear();
                        });
                      },
                      child: const Text('更换'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _fetchMails,
                    icon: const Icon(Icons.refresh),
                    label: Text(_loadingList ? '拉取中…' : '重新拉取账单邮件'),
                  ),
                  const SizedBox(height: 12),
                  if (_mails.isEmpty && !_loadingList)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                          child: Text('暂无账单邮件，点上方按钮拉取',
                              style: TextStyle(
                                  color: Colors.grey.shade500))),
                    ),
                  for (final m in _mails)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text((m['subject'] ?? '') as String,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13.5)),
                            const SizedBox(height: 2),
                            if ((m['from'] ?? '') != '')
                              Text((m['from'] ?? '') as String,
                                  style: TextStyle(
                                      color: Colors.grey.shade400,
                                      fontSize: 11)),
                            const SizedBox(height: 2),
                            Text(
                              m['date'] == null
                                  ? ''
                                  : (m['date'] as String).substring(0, 10),
                              style: TextStyle(
                                  color: Colors.grey.shade500,
                                  fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final att in m['attachments']
                                    as List)
                                  ActionChip(
                                    avatar: const Icon(
                                        Icons.attach_file,
                                        size: 14),
                                    label: Text(
                                        '${att['filename']}'
                                        '（${(att['size'] ?? 0) ~/ 1024}KB）',
                                        style:
                                            const TextStyle(fontSize: 11)),
                                    visualDensity:
                                        VisualDensity.compact,
                                    onPressed: _busy
                                        ? null
                                        : () => _openAttachment(
                                            m,
                                            att as Map),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                if (_status != null) ...[
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
                    child: Text(
                      (_busy ? '⏳ ' : (_statusErr ? '⚠️ ' : '✅ ')) +
                          _status!,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: _statusErr
                              ? const Color(0xFFB71C1C)
                              : const Color(0xFF1B5E20)),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
