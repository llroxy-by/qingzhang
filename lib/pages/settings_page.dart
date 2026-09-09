import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart';
import '../models/account.dart';
import '../models/categories.dart';
import '../services/sync_service.dart';
import '../utils/format.dart';

class SettingsPage extends StatelessWidget {
  final int tick;
  const SettingsPage({super.key, required this.tick});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            const Text('设置',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            const _SectionHeader('账号与云端同步'),
            const SizedBox(height: 8),
            AccountSyncCard(),
            const SizedBox(height: 20),
            const _SectionHeader('资金构成'),
            const SizedBox(height: 8),
            _AccountsCard(),
            const SizedBox(height: 20),
            const _SectionHeader('分类'),
            const SizedBox(height: 8),
            _buildCard(
              context,
              icon: Icons.manage_search,
              title: '分类关键词规则',
              subtitle: '查看/添加"关键词 → 分类"规则，用于账单自动分类',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RulesPage())),
            ),
            const SizedBox(height: 20),
            const _SectionHeader('数据'),
            const SizedBox(height: 8),
            _buildCard(
              context,
              icon: Icons.backup_outlined,
              title: '导出备份',
              subtitle: '把快照和流水导出为 JSON 文件（可分享保存）',
              onTap: () => _exportBackup(context),
            ),
            const SizedBox(height: 8),
            _buildCard(
              context,
              icon: Icons.delete_outline,
              title: '清空流水',
              subtitle: '删除所有导入的账单流水（保留快照和账户）',
              onTap: () => _clearTxns(context),
              danger: true,
            ),
            const SizedBox(height: 8),
            _buildCard(
              context,
              icon: Icons.delete_forever_outlined,
              title: '清空全部数据（重置）',
              subtitle: '删除流水/旅程/快照/规则/账户，恢复出厂状态',
              onTap: () => _resetAll(context),
              danger: true,
            ),
            const SizedBox(height: 20),
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) {
                final info = snap.data;
                final ver =
                    info == null ? '?' : '${info.version} (${info.buildNumber})';
                return Center(
                  child: Text('轻账 v$ver · 数据仅保存在本机',
                      style: TextStyle(
                          color: Colors.grey.shade400, fontSize: 12)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    return Card(
      child: ListTile(
        leading: Icon(icon,
            color: danger ? const Color(0xFFE05B4B) : const Color(0xFF00897B)),
        title: Text(title,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: danger ? const Color(0xFFE05B4B) : null)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  Future<void> _exportBackup(BuildContext context) async {
    try {
      final db = appState.db;
      final accounts = await db.listAccounts();
      final snapshots = await db.listSnapshots();
      final txns = await db.listTxns();

      final data = jsonEncode({
        'app': 'qingzhang',
        'version': 1,
        'exported_at': DateTime.now().toIso8601String(),
        'accounts': accounts.map((a) => a.toMap()).toList(),
        'snapshots': snapshots.map((s) => {
              'date': s.date,
              'total_cents': s.totalCents,
              'entries': s.entries
                  .map((e) => {'account_id': e.accountId, 'amount_cents': e.amountCents})
                  .toList(),
            }).toList(),
        'txns': txns.map((t) => t.toMap()).toList(),
      });
      final dateStr = DateTime.now().toIso8601String().substring(0, 10);
      final fileName = '轻账备份_$dateStr.json';
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(utf8.encode(data), mimeType: 'application/json', name: fileName)],
          subject: '轻账备份',
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  Future<void> _clearTxns(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空流水？'),
        content: const Text('将删除所有导入的账单流水，此操作不可恢复。\n（账户与快照不受影响）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE05B4B)),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) {
      await appState.db.clearTxns();
      appState.refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('流水已清空')));
      }
    }
  }

  Future<void> _resetAll(BuildContext context) async {
    // 第一层确认
    final ok1 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部数据？'),
        content: const Text(
            '将删除所有数据：流水、旅程、快照、自定义分类规则和账户设置，\n'
            '并恢复默认资金构成。此操作不可恢复！\n'
            '若已设置云端账号，服务器上的该账号数据也会一并清除。\n'
            '建议先"导出备份"再重置。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE05B4B)),
              child: const Text('继续')),
        ],
      ),
    );
    if (ok1 != true || !context.mounted) return;
    // 第二层：输入"清空"确认
    final ctrl = TextEditingController();
    final ok2 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('最后确认'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('输入"清空"两个字以确认：'),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, ctrl.text.trim() == '清空'),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE05B4B)),
              child: const Text('重置')),
        ],
      ),
    );
    ctrl.dispose();
    if (ok2 != true) return;
    // 云端联动：先清服务器（有账号时），失败不阻塞本地清空
    var cloudNote = '';
    final uid = await appState.db.getMeta('userId');
    if (uid != null && uid.isNotEmpty) {
      try {
        await SyncService.resetCloud();
        cloudNote = '，云端已同步清空';
      } catch (_) {
        cloudNote = '（云端清空失败，可稍后同步覆盖）';
      }
    }
    await appState.db.resetAllData();
    appState.refresh();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已清空全部数据，恢复默认资金构成$cloudNote')));
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Colors.grey.shade600));
  }
}

// ================= 账号与云端同步 =================

class AccountSyncCard extends StatefulWidget {
  const AccountSyncCard({super.key});

  @override
  State<AccountSyncCard> createState() => _AccountSyncCardState();
}

class _AccountSyncCardState extends State<AccountSyncCard> {
  String? _nickname;
  String? _server;
  String? _lastSync;
  bool _syncing = false;
  bool _loaded = false;
  // 账号弹窗输入框 controller 放 State（弹窗复用，避免生命周期问题）
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _pwdCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final n = await SyncService.currentNickname();
    String s;
    try {
      s = await SyncService.serverUrl();
    } catch (_) {
      s = ''; // 未设置服务器地址
    }
    final t = await SyncService.lastSyncAt();
    if (!mounted) return;
    setState(() {
      _nickname = (n?.isEmpty ?? true) ? null : n;
      _server = (s.isEmpty) ? '未设置' : s;
      // 空串视为从未同步（退出登录后 lastSyncAt 被清空）
      _lastSync = (t == null || t.isEmpty) ? null : t;
      _loaded = true;
    });
  }

  /// 修改服务器地址（开源版默认空，自建服务器后在此填写）
  Future<void> _editServer() async {
    final ctrl = TextEditingController(text: _server == '未设置' ? '' : _server);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('云端服务器地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'http://你的服务器:端口',
                hintText: '例如 http://192.168.1.10:8080',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text('自用版本通常已内置；开源版需填写自己部署的服务器（见 README）。',
                style:
                    TextStyle(color: Colors.grey.shade500, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      await SyncService.setServerUrl(ctrl.text);
      await _load();
    }
    ctrl.dispose();
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: error ? const Color(0xFFE05B4B) : null,
        duration: const Duration(seconds: 4)));
  }

  Future<void> _authFlow() async {
    _nameCtrl.text = _nickname ?? '';
    _pwdCtrl.clear();
    var mode = 'login'; // login / register
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(mode == 'login' ? '登录账号' : '注册账号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: '昵称',
                  hintText: '给自己起个名字，如：阿伟',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _pwdCtrl,
                obscureText: true,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: '密码',
                  hintText: '至少 4 位',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                mode == 'login'
                    ? '没有账号？点下方"注册"创建（老账号直接注册即可绑定密码）'
                    : '已有账号？直接点"登录"',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            TextButton(
              onPressed: () => setDlg(() => mode = mode == 'login' ? 'register' : 'login'),
              child: Text(mode == 'login' ? '去注册' : '去登录'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                  ctx, mode == 'login' ? 'login' : 'register'),
              child: Text(mode == 'login' ? '登录' : '注册'),
            ),
          ],
        ),
      ),
    );
    final nickname = _nameCtrl.text.trim();
    final password = _pwdCtrl.text;
    final wasLogin = result == 'login';
    if (result == null) return;
    if (nickname.isEmpty || password.isEmpty) {
      _toast('请填写昵称和密码', error: true);
      return;
    }
    if (password.length < 4) {
      _toast('密码至少 4 位', error: true);
      return;
    }
    try {
      final r = wasLogin
          ? await SyncService.login(nickname, password)
          : await SyncService.register(nickname, password);
      final user = (r['user'] as Map).cast<String, dynamic>();
      _toast('已${wasLogin ? '登录' : '注册'}「${user['nickname']}」\n建议点"立即同步"把本机数据传到云端');
      await _load();
    } catch (e) {
      _toast('$e', error: true);
      if (!wasLogin && e.toString().contains('已被注册')) {
        _toast('该昵称已注册，请改用"登录"', error: true);
      }
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text('退出后本机数据保留，只是不能再同步；随时可重新登录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (ok == true) {
      await SyncService.clearAccount();
      appState.refresh();
      await _load();
    }
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final msg = await SyncService.syncNow();
      _toast(msg);
      appState.refresh();
      await _load();
    } catch (e) {
      _toast('同步失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator())));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: CircleAvatar(
                radius: 18,
                backgroundColor:
                    const Color(0xFF00897B).withValues(alpha: 0.12),
                child: Text(_nickname == null ? '?' : _nickname!.characters.first,
                    style: const TextStyle(
                        color: Color(0xFF00897B),
                        fontWeight: FontWeight.w800)),
              ),
              title: Text(
                _nickname == null ? '未设置账号' : _nickname!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${_nickname == null ? '注册账号后数据可同步到云端' : '数据按账号存在服务器'}\n'
                '服务器：$_server\n'
                '上次同步：${_lastSync == null ? '从未' : _lastSync!.substring(0, 19).replaceAll('T', ' ')}',
                style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 11,
                    height: 1.5),
              ),
              onTap: _editServer, // 点账号卡头部即可改服务器地址
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _editServer,
                icon: const Icon(Icons.dns_outlined, size: 15),
                label: const Text('服务器地址', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _authFlow,
                    icon: Icon(
                        _nickname == null
                            ? Icons.person_outline
                            : Icons.swap_horiz,
                        size: 18),
                    label: Text(_nickname == null ? '登录/注册' : '换账号'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _sync,
                    icon: _syncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: Text(_syncing ? '同步中…' : '立即同步'),
                  ),
                ),
                if (_nickname != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _logout,
                    tooltip: '退出登录',
                    icon: const Icon(Icons.logout, size: 20),
                    color: Colors.grey.shade600,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text('昵称 + 密码登录；换设备用同一昵称密码登录后同步即可。',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ================= 资金构成管理 =================

class _AccountsCard extends StatefulWidget {
  @override
  State<_AccountsCard> createState() => _AccountsCardState();
}

class _AccountsCardState extends State<_AccountsCard> {
  List<Account> _accounts = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await appState.db.listAccounts();
    if (!mounted) return;
    setState(() {
      _accounts = list;
      _loaded = true;
    });
  }

  Future<void> _edit(Account? account) async {
    final result = await showDialog<Account>(
      context: context,
      builder: (_) => _AccountDialog(account: account),
    );
    if (result != null) {
      if (account == null) {
        await appState.db.insertAccount(result);
      } else {
        await appState.db.updateAccount(result);
      }
      appState.refresh();
      await _load();
    }
  }

  Future<void> _remove(Account account) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${account.name}」？'),
        content: const Text('该账户的快照余额与流水记录会一并删除。'),
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
      await appState.db.deleteAccount(account.id!);
      appState.refresh();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_accounts.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Text('还没有账户'),
              const SizedBox(height: 8),
              FilledButton.icon(
                  onPressed: () => _edit(null),
                  icon: const Icon(Icons.add),
                  label: const Text('添加账户')),
            ],
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _accounts.length + 1,
      onReorderItem: (oldI, newI) async {
        setState(() {
          final a = _accounts.removeAt(oldI);
          _accounts.insert(newI, a);
          for (var i = 0; i < _accounts.length; i++) {
            _accounts[i] = _accounts[i].copyWith(sortOrder: i);
          }
        });
        await appState.db.reorderAccounts(_accounts);
        appState.refresh();
      },
      itemBuilder: (context, index) {
        if (index == _accounts.length) {
          return Padding(
            key: const ValueKey('add'),
            padding: const EdgeInsets.only(top: 4),
            child: OutlinedButton.icon(
              onPressed: () => _edit(null),
              icon: const Icon(Icons.add),
              label: const Text('添加账户'),
            ),
          );
        }
        final a = _accounts[index];
        return Card(
          key: ValueKey(a.id),
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Text(a.emoji, style: const TextStyle(fontSize: 20)),
            title: Text(a.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(a.type.label,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: () => _edit(a),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (v) {
                    if (v == 'delete') _remove(a);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('删除账户')),
                  ],
                ),
              ],
            ),
            onTap: () => _edit(a),
          ),
        );
      },
    );
  }
}

class _AccountDialog extends StatefulWidget {
  final Account? account;
  const _AccountDialog({this.account});

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _name;
  late final TextEditingController _emoji;
  late final TextEditingController _channelKeywords;
  late final TextEditingController _openingAmount;
  late AccountType _type;
  late bool _active;
  bool _openingEnabled = false;
  DateTime? _openingDate;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _name = TextEditingController(text: a?.name ?? '');
    _emoji = TextEditingController(text: a?.emoji ?? '💳');
    _channelKeywords =
        TextEditingController(text: a?.channelKeywords ?? '');
    _openingAmount = TextEditingController(
        text: a?.openingCents != null && a!.openingCents! != 0
            ? centsToInput(a.openingCents!)
            : '');
    _type = a?.type ?? AccountType.bank;
    _active = a?.isActive ?? true;
    _openingEnabled = a?.openingDate != null;
    _openingDate = a?.openingDate != null
        ? DateTime.parse(a!.openingDate!)
        : null;
  }

  @override
  void dispose() {
    _name.dispose();
    _emoji.dispose();
    _channelKeywords.dispose();
    _openingAmount.dispose();
    super.dispose();
  }

  Future<void> _pickOpeningDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _openingDate ?? DateTime.now(),
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
      helpText: '选择期初日期（此日起流水完整）',
    );
    if (picked != null) {
      setState(() => _openingDate = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.account != null;
    final d = _openingDate;
    return AlertDialog(
      title: Text(isEdit ? '编辑账户' : '添加账户'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称（如：工行卡）'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _emoji,
                    decoration:
                        const InputDecoration(labelText: '图标 emoji'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<AccountType>(
                    initialValue: _type,
                    decoration: const InputDecoration(labelText: '类型'),
                    items: [
                      for (final t in AccountType.values)
                        DropdownMenuItem(value: t, child: Text(t.label)),
                    ],
                    onChanged: (v) =>
                        setState(() => _type = v ?? AccountType.other),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _channelKeywords,
              decoration: const InputDecoration(
                labelText: '渠道关键词（逗号分隔，可空）',
                hintText: '如：招商银行,尾号8899',
                helperText:
                    '账单"支付方式"含这些词时自动归入此账户，用于余额推算与去重',
                helperMaxLines: 2,
              ),
            ),
            const Divider(height: 28),
            Row(
              children: [
                const Expanded(
                    child: Text('设置期初余额（流水完整，可推算余额）',
                        style: TextStyle(fontSize: 13))),
                Switch(
                  value: _openingEnabled,
                  onChanged: (v) => setState(() => _openingEnabled = v),
                ),
              ],
            ),
            if (_openingEnabled) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickOpeningDate,
                      icon: const Icon(Icons.event, size: 18),
                      label: Text(d == null
                          ? '选期初日期'
                          : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _openingAmount,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                          labelText: '期初余额', prefixText: '¥ ', isDense: true),
                    ),
                  ),
                ],
              ),
            ],
            if (isEdit) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('启用（在记快照时显示）',
                    style: TextStyle(fontSize: 13)),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            final oc = _openingAmount.text.trim();
            Navigator.pop(
              context,
              Account(
                id: widget.account?.id,
                name: name,
                emoji: _emoji.text.trim().isEmpty ? '💳' : _emoji.text.trim(),
                type: _type,
                sortOrder: widget.account?.sortOrder ?? 0,
                isActive: isEdit ? _active : true,
                channelKeywords: _channelKeywords.text.trim(),
                openingDate:
                    _openingEnabled && _openingDate != null && oc.isNotEmpty
                        ? '${_openingDate!.year}-${_openingDate!.month.toString().padLeft(2, '0')}-${_openingDate!.day.toString().padLeft(2, '0')}'
                        : null,
                openingCents:
                    _openingEnabled && oc.isNotEmpty ? parseYuanToCents(oc) : null,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

// ================= 分类规则管理 =================

class RulesPage extends StatefulWidget {
  const RulesPage({super.key});

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  List<Map<String, Object?>> _rules = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rules = await appState.db.listUserRules();
    if (!mounted) return;
    setState(() {
      _rules = rules;
      _loaded = true;
    });
  }

  Future<void> _add() async {
    final kwController = TextEditingController();
    var category = 'food';
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: const Text('添加规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: kwController,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: '关键词（摘要包含即匹配）'),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('归类为',
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 13)),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in kCategories)
                    ChoiceChip(
                      label: Text('${c.emoji} ${c.label}'),
                      selected: category == c.key,
                      onSelected: (_) => setSheet(() => category = c.key),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () {
                  if (kwController.text.trim().isEmpty) return;
                  Navigator.pop(ctx, true);
                },
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (result == true && kwController.text.trim().isNotEmpty) {
      await appState.db.addUserRule(kwController.text.trim(), category);
      appState.refresh();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('分类关键词规则')),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '导入账单时，系统会按「关键词 → 分类」自动归类：\n'
                  '1. 你的自定义规则（下方）优先级最高\n'
                  '2. 然后是内置规则（200+ 常用商户关键词）\n'
                  '3. 在导入页修改分类时勾选"记住规则"，会自动添加到这里\n\n'
                  '长按规则可删除。',
                  style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                      height: 1.6),
                ),
                const SizedBox(height: 12),
                if (_rules.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: Text('还没有自定义规则',
                          style: TextStyle(color: Colors.grey.shade500)),
                    ),
                  ),
                for (final r in _rules)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      leading: const Icon(Icons.vpn_key, size: 20),
                      title: Text((r['keyword'] as String?) ?? '',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00897B)
                                  .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${categoryOf((r['category'] as String?) ?? '').emoji} ${categoryOf((r['category'] as String?) ?? '').label}',
                              style: const TextStyle(
                                  color: Color(0xFF00897B),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: 20, color: Color(0xFFE05B4B)),
                            onPressed: () async {
                              await appState.db
                                  .deleteUserRule(r['id'] as int);
                              appState.refresh();
                              await _load();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
