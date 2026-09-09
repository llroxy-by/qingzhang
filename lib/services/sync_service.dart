import 'dart:convert';

import 'package:http/http.dart' as http;

import '../main.dart';

/// 云端账号 + 数据同步
///
/// 同步模型：全量 push → 服务器按 updated_at last-write-wins 合并
/// → 返回合并后全量 → 本地替换（服务器为权威，各端收敛一致）。
class SyncService {
  // 服务器地址默认空（开源版）：安装后到 设置 → 账号与同步 →「服务器地址」填写。
  // 自用分发版构建时注入内置地址，无需手动填写：
  //   flutter build apk --release --dart-define=QINGZHANG_SERVER=http://你的服务器:8080
  static const defaultServer =
      String.fromEnvironment('QINGZHANG_SERVER', defaultValue: '');

  static Future<String> serverUrl() async {
    final v = (await appState.db.getMeta('serverUrl')) ?? defaultServer;
    if (v.trim().isEmpty) {
      throw Exception('未设置服务器地址：设置 → 账号与同步 → 点"服务器"行填写');
    }
    return v.trim();
  }

  static Future<void> setServerUrl(String url) async {
    var u = url.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    u = u.replaceAll(RegExp(r'/+$'), '');
    await appState.db.setMeta('serverUrl', u);
  }

  static Future<String?> currentNickname() =>
      appState.db.getMeta('nickname');

  static Future<String?> currentUserId() => appState.db.getMeta('userId');

  static Future<String?> currentToken() => appState.db.getMeta('token');

  static Future<String?> lastSyncAt() => appState.db.getMeta('lastSyncAt');

  static Future<void> clearAccount() async {
    await appState.db.setMeta('userId', '');
    await appState.db.setMeta('nickname', '');
    await appState.db.setMeta('token', '');
    await appState.db.setMeta('lastSyncAt', '');
  }

  static Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    final base = await serverUrl();
    final uri = Uri.parse('$base$path');
    final headers = {'Content-Type': 'application/json'};
    final token = await currentToken();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    http.Response resp;
    if (method == 'POST') {
      resp = await http
          .post(uri, headers: headers, body: jsonEncode(body ?? {}))
          .timeout(const Duration(seconds: 40));
    } else {
      resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 40));
    }
    if (resp.statusCode != 200) {
      final msg = utf8.decode(resp.bodyBytes);
      String reason;
      try {
        reason = ((jsonDecode(msg) as Map)['error'] ?? 'HTTP ${resp.statusCode}')
            .toString();
      } catch (_) {
        reason = 'HTTP ${resp.statusCode}';
      }
      throw Exception(reason);
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    return (decoded as Map).cast<String, dynamic>();
  }

  /// 保存登录/注册返回的账号信息到本地
  static Future<void> _saveSession(Map<String, dynamic> r) async {
    final user = (r['user'] as Map).cast<String, dynamic>();
    await appState.db.setMeta('userId', user['id'].toString());
    await appState.db.setMeta('nickname', user['nickname'].toString());
    await appState.db.setMeta('token', (r['token'] ?? '').toString());
  }

  /// 注册：昵称+密码。老账号（此前无密码）自动绑定密码；重名已设密码报错。
  static Future<Map<String, dynamic>> register(
      String nickname, String password) async {
    final r = await _request('/api/user/register',
        method: 'POST', body: {'nickname': nickname, 'password': password});
    await _saveSession(r);
    return r;
  }

  /// 登录：昵称+密码
  static Future<Map<String, dynamic>> login(
      String nickname, String password) async {
    final r = await _request('/api/user/login',
        method: 'POST', body: {'nickname': nickname, 'password': password});
    await _saveSession(r);
    return r;
  }

  /// 服务器上所有用户（Web 端用；App 也可查"我的账号存在吗"）
  static Future<List<Map<String, dynamic>>> listUsers() async {
    final r = await _request('/api/users');
    final users = (r['users'] as List).cast<Map<String, dynamic>>();
    return users;
  }

  /// 执行一次全量双向同步。返回人类可读结果；失败抛异常。
  static Future<String> syncNow() async {
    final uid = await currentUserId();
    if (uid == null || uid.isEmpty) {
      throw Exception('还没有账号：先在"账号与同步"里设置昵称');
    }
    final payload = await appState.db.buildSyncPayload();
    final r = await _request('/api/data/$uid',
        method: 'POST', body: payload);
    final merged = (r['merged'] as Map).cast<String, dynamic>();
    final data = (r['data'] as Map).cast<String, dynamic>();
    await appState.db.applySyncedData(data);
    await appState.db.setMeta(
        'lastSyncAt', DateTime.now().toIso8601String());
    final parts = <String>[];
    merged.forEach((k, v) => parts.add('$k+$v'));
    return '同步完成：云端合并 ${parts.join(' / ')}';
  }

  /// 清空服务器上当前账号的全部业务数据（App"清空全部数据"联动）。
  /// 保留账号记录（昵称仍可登录）。失败抛异常。
  static Future<void> resetCloud() async {
    final uid = await currentUserId();
    if (uid == null || uid.isEmpty) return;
    await _request('/api/reset/$uid', method: 'POST', body: const {});
  }
}
