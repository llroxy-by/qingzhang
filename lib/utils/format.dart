/// 金额/日期格式化工具。金额内部一律用 int 分，避免浮点误差。
String fmtCents(int cents, {bool withSign = false}) {
  final negative = cents < 0;
  final abs = cents.abs();
  final yuan = (abs / 100).toStringAsFixed(2);
  // 千分位
  final parts = yuan.split('.');
  final intPart = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  final s = '$buf.${parts[1]}';
  if (withSign) {
    return negative ? '-$s' : '+$s';
  }
  return negative ? '-$s' : s;
}

/// 把用户输入的元字符串解析为分；非法输入返回 null
int? parseYuanToCents(String input) {
  var s = input.trim().replaceAll(',', '').replaceAll('¥', '').replaceAll('￥', '');
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null) return null;
  return (v * 100).round();
}

/// 分 → 输入框里的元字符串（去掉多余小数位）
String centsToInput(int cents) {
  final yuan = cents / 100;
  if (cents % 100 == 0) return yuan.toStringAsFixed(0);
  if (cents % 10 == 0) return yuan.toStringAsFixed(1);
  return yuan.toStringAsFixed(2);
}

String fmtDate(String yyyyMMdd) {
  final p = yyyyMMdd.split('-');
  if (p.length != 3) return yyyyMMdd;
  return '${p[0]}.${p[1]}.${p[2]}';
}

/// 中文友好日期：今天 / 昨天 / N天前 / yyyy.MM.dd
String friendlyDate(String yyyyMMdd) {
  final now = DateTime.now();
  final today = _d(now);
  if (yyyyMMdd == today) return '今天';
  final y = now.subtract(const Duration(days: 1));
  if (yyyyMMdd == _d(y)) return '昨天';
  final d = DateTime.parse(yyyyMMdd);
  final diff = now.difference(d).inDays;
  if (diff > 0 && diff < 7) return '$diff 天前';
  return fmtDate(yyyyMMdd);
}

String _d(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
