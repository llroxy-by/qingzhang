import 'dart:math';

/// 生成 uuid（v4 风格，32 位 hex，无横线）。
/// 跨设备同步的主键，与服务端 TEXT 主键兼容。
String genUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40; // version 4
  b[8] = (b[8] & 0x3F) | 0x80; // variant
  return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// 当前毫秒时间戳（同步冲突 last-write-wins 依据）
int nowMillis() => DateTime.now().millisecondsSinceEpoch;
