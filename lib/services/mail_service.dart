import 'dart:convert';

import 'package:http/http.dart' as http;

import '../main.dart';
import 'sync_service.dart';

/// 邮箱账单服务（走自己的服务器，服务器连 QQ 邮箱 IMAP）
class MailService {
  static Future<String> _base() => SyncService.serverUrl();

  static Future<Map<String, dynamic>> _api(String path,
      {String method = 'GET', Object? body}) async {
    final uri = Uri.parse('${await _base()}$path');
    final headers = {'Content-Type': 'application/json'};
    final token = await appState.db.getMeta('token');
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    http.Response resp;
    if (method == 'POST') {
      resp = await http
          .post(uri, headers: headers, body: jsonEncode(body ?? {}))
          .timeout(const Duration(seconds: 30));
    } else {
      resp = await http.get(uri).timeout(const Duration(seconds: 90));
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (resp.statusCode != 200) {
      throw Exception((decoded as Map)['error'] ?? 'HTTP ${resp.statusCode}');
    }
    return (decoded as Map).cast<String, dynamic>();
  }

  static Future<Map<String, dynamic>> getConfig() =>
      _api('/api/mail/config');

  static Future<void> saveConfig(String email, String authCode) =>
      _api('/api/mail/config',
          method: 'POST', body: {'email': email, 'authCode': authCode});

  static Future<List<Map<String, dynamic>>> listMails() async {
    final r = await _api('/api/mail/list');
    return (r['mails'] as List).cast<Map<String, dynamic>>();
  }

  /// 下载附件字节（zip/pdf）
  static Future<List<int>> downloadAttachment(int uid, String part) async {
    final uri = Uri.parse(
        '${await _base()}/api/mail/attachment/$uid/${Uri.encodeComponent(part)}');
    final headers = <String, String>{};
    final token = await appState.db.getMeta('token');
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final resp = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      final msg = utf8.decode(resp.bodyBytes);
      throw Exception(msg.contains('error')
          ? (jsonDecode(msg)['error'] ?? 'HTTP ${resp.statusCode}')
          : '下载失败 HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }
}
