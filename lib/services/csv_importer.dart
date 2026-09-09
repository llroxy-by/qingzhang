import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:fast_gbk/fast_gbk.dart';

import '../models/txn.dart';

/// 从账单文件解析出流水。支持格式：
///  - CSV/TXT（支付宝、微信、部分银行）
///  - XLSX（微信 App 导出的账单等 Excel 表格）
///
/// 三种主流表格结构：
///  A) 支付宝/微信：「收/支」列 + 「金额」列（金额为正，方向由收/支决定）
///  B) 银行双列：「收入」列 + 「支出」列（各自为正，按列决定方向）
///  C) 带符号金额：只有「金额」列，金额本身带负号
class TxnParseResult {
  final List<Txn> txns;
  final int skipped; // 跳过的行数（表头/空行/无效）
  final List<String> warnings; // 解析中遇到的说明

  const TxnParseResult(
      {required this.txns, required this.skipped, this.warnings = const []});
}

class CsvImporter {
  static const _dateKeys = ['交易时间', '交易日期', '记账日期', '日期', '时间'];
  static const _amountKeys = ['金额'];
  static const _incomeKeys = ['收入'];
  static const _expenseKeys = ['支出', '付出'];
  static const _flowKeys = ['收/支', '收支'];
  // 描述列：优先"商品说明/摘要"这类真正描述交易内容的列，
  // 其次才是"交易对方/备注"（支付宝表头里交易对方排在商品说明前面）
  static const _descPrimary = ['商品说明', '商品', '摘要', '说明'];
  static const _descFallback = ['交易对方', '对方', '备注'];
  static const _statusKeys = ['交易状态', '当前状态', '状态'];
  static const _nameKeys = ['交易类型', '类型'];
  // 支付渠道列：如微信"支付方式"、支付宝"收/付款方式"
  static const _channelKeys = ['支付方式', '收/付款方式', '付款方式', '渠道'];

  /// 渠道文本含这些词 = 通过银行卡/信用支付（会在银行卡账单重复出现）
  static const bankChannelKeywords = [
    '银行', '储蓄卡', '信用卡', '借记卡', '贷记卡', '尾号', '花呗', '白条', '闪付',
  ];

  /// 判断某渠道是否为银行卡渠道（用于导入时防重复过滤）
  static bool isBankChannel(String channel) {
    if (channel.trim().isEmpty) return false;
    final c = channel.toLowerCase();
    return bankChannelKeywords.any(c.contains);
  }

  /// 按文件名/扩展名解析文件字节。.xlsx 走 Excel 解析，其余按文本 CSV。
  static TxnParseResult parseBytes(Uint8List bytes, String fileName,
      {String source = 'unknown'}) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.xlsx')) {
      final rows = _xlsxToRows(bytes);
      if (rows == null) {
        return const TxnParseResult(txns: [], skipped: 0, warnings: [
          '无法读取 xlsx 文件（可能已损坏或格式不支持）'
        ]);
      }
      return parseRows(rows, source: source);
    }
    // 文本格式（CSV/TXT）：按 BOM → UTF-8 → GBK → ASCII 顺序解码。
    // 支付宝电脑端导出的 CSV 是 GBK/GB18030 编码（历史原因），
    // 微信/支付宝 App 导出多为 UTF-8（可能带 BOM）。
    String text;
    var data = bytes;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      data = Uint8List.sublistView(bytes, 3); // 去掉 UTF-8 BOM
    }
    try {
      text = utf8.decode(data);
    } catch (_) {
      try {
        text = gbk.decode(data); // 中文 GBK（支付宝电脑端/老导出）
      } catch (_) {
        text = String.fromCharCodes(data); // 纯 ASCII 等逐字节兜底
      }
    }
    return parse(text, source: source);
  }

  /// 解析 CSV 文本
  static TxnParseResult parse(String csvText, {String source = 'unknown'}) {
    final rows = _parseCsv(csvText);
    return parseRows(rows, source: source);
  }

  /// 解析统一的行列表（表头探测 + 数据行转换）
  static TxnParseResult parseRows(List<List<String>> rows,
      {String source = 'unknown'}) {
    final warnings = <String>[];
    if (rows.isEmpty) {
      return const TxnParseResult(txns: [], skipped: 0, warnings: [
        '文件为空或无法解析'
      ]);
    }

    // 找到表头行：真正的表头是"多列表格"（列数>=5）且含金额类列名。
    // 单列叙述行（如汇总"收入：10笔…支出：90笔…"、分隔线、账单信息）会被排除，
    // 避免被"收入/支出"字样误判为表头。
    int headerIdx = -1;
    for (var i = 0; i < rows.length && i < 60; i++) {
      if (rows[i].length < 5) continue; // 单列/窄行不是表头
      final joined = rows[i].join(',');
      final hasAmount = joined.contains('金额');
      final hasIncomeExpense =
          joined.contains('收入') && joined.contains('支出');
      if (hasAmount || hasIncomeExpense) {
        headerIdx = i;
        break;
      }
    }
    if (headerIdx == -1) {
      return const TxnParseResult(txns: [], skipped: 0, warnings: [
        '没找到账单表头（需要包含"金额"或"收入/支出"列）'
      ]);
    }

    final header = rows[headerIdx].map((h) => h.trim()).toList();
    int? dateCol, amountCol, flowCol, incomeCol, expenseCol, descCol, statusCol, nameCol, channelCol;
    int? descFallbackCol;
    for (var i = 0; i < header.length; i++) {
      final h = header[i];
      if (h.isEmpty) continue;
      if (dateCol == null && _dateKeys.any(h.contains)) dateCol = i;
      if (descCol == null && _descPrimary.any(h.contains)) descCol = i;
      if (descFallbackCol == null && _descFallback.any(h.contains)) {
        descFallbackCol = i;
      }
      if (flowCol == null && _flowKeys.any(h.contains)) flowCol = i;
      if (nameCol == null && _nameKeys.any(h.contains)) nameCol = i;
      if (statusCol == null && _statusKeys.any(h.contains)) statusCol = i;
      if (channelCol == null && _channelKeys.any(h.contains)) channelCol = i;
      // 金额列优先精确匹配"金额"而非余额列
      if (amountCol == null &&
          !h.contains('余额') &&
          _amountKeys.any(h.contains)) {
        amountCol = i;
      }
      if (incomeCol == null && !h.contains('支出') && _incomeKeys.any(h.contains)) {
        incomeCol = i;
      }
      if (expenseCol == null &&
          !h.contains('收入') &&
          _expenseKeys.any(h.contains)) {
        expenseCol = i;
      }
    }
    descCol ??= descFallbackCol;

    final formatB = incomeCol != null && expenseCol != null;
    if (amountCol == null && !formatB) {
      return const TxnParseResult(txns: [], skipped: 0, warnings: [
        '无法识别金额列，请确认导出的账单包含"金额"或"收入/支出"列'
      ]);
    }
    if (dateCol == null) {
      return const TxnParseResult(txns: [], skipped: 0, warnings: [
        '无法识别日期列，请确认导出的账单包含日期列'
      ]);
    }

    final txns = <Txn>[];
    var skipped = 0;

    for (var i = headerIdx + 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.length <= dateCol) {
        skipped++;
        continue;
      }
      final dateRaw = row[dateCol].trim();
      // 跳过空行和页脚（支付宝有 BEGIN/END/合计 行）
      if (dateRaw.isEmpty ||
          dateRaw.contains('合计') ||
          dateRaw.contains('----') ||
          dateRaw.contains('BEGIN') ||
          dateRaw.contains('END')) {
        skipped++;
        continue;
      }
      final date = _cleanDate(dateRaw);
      if (date == null) {
        skipped++;
        continue;
      }

      // 方向与金额
      int amount;
      if (formatB) {
        final inc = _parseAmount(row[incomeCol]);
        final exp = _parseAmount(row[expenseCol]);
        // 银行账单两列往往只有一列有值，空格子视为 0
        if (inc == null && exp == null) {
          skipped++;
          continue;
        }
        amount = (inc ?? 0) - (exp ?? 0);
      } else if (flowCol != null && row.length > flowCol) {
        final flow = row[flowCol].trim();
        final amt = _parseAmount(row[amountCol!]);
        if (amt == null || amt == 0) {
          skipped++;
          continue;
        }
        if (flow.contains('收入') || flow.contains('收款')) {
          amount = amt;
        } else if (flow.contains('不计收支') ||
            flow.contains('已退款') ||
            flow.contains('退款成功')) {
          skipped++; // 退款/不计收支的占位行
          continue;
        } else {
          amount = -amt; // 支出
        }
      } else {
        final amt = _parseAmount(row[amountCol!]);
        if (amt == null || amt == 0) {
          skipped++;
          continue;
        }
        amount = amt; // 金额本身带符号
      }

      // 交易状态过滤：已退款/关闭的交易不计
      if (statusCol != null && row.length > statusCol) {
        final st = row[statusCol];
        if (st.contains('退款成功') ||
            st.contains('已全额退款') ||
            st.contains('交易关闭')) {
          skipped++;
          continue;
        }
        if (st.contains('退款') && st.contains('成功')) {
          skipped++;
          continue;
        }
      }

      // 摘要：优先商品说明，其次交易对方+类型
      String desc = '';
      if (descCol != null && row.length > descCol) {
        desc = row[descCol].trim();
      }
      if (nameCol != null && row.length > nameCol && desc.isEmpty) {
        desc = row[nameCol].trim();
      }

      // 支付渠道（微信"支付方式"/支付宝"收/付款方式"）
      String channel = '';
      if (channelCol != null && row.length > channelCol) {
        channel = row[channelCol].trim();
      }

      final txn = Txn(
        date: date,
        description: desc.isEmpty ? '(无摘要)' : desc,
        amountCents: amount,
        channel: channel,
        source: source,
        category: 'unknown', // 导入后统一走分类引擎
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      txns.add(txn);
    }

    if (txns.isEmpty) {
      warnings.add('没有解析到有效交易（共跳过 $skipped 行），请检查文件格式');
    }

    return TxnParseResult(txns: txns, skipped: skipped, warnings: warnings);
  }

  // ---------- xlsx ----------

  /// 用 excel 包把 xlsx 解码成行列表；失败返回 null
  static List<List<String>>? _xlsxToRows(Uint8List bytes) {
    try {
      final excel = Excel.decodeBytes(bytes);
      if (excel.tables.isEmpty) return null;
      // 取第一个有数据的表
      for (final table in excel.tables.values) {
        final rows = <List<String>>[];
        for (final r in table.rows) {
          final cells = <String>[];
          var allEmpty = true;
          for (final c in r) {
            final s = _xlsxCellToString(c?.value);
            cells.add(s);
            if (s.isNotEmpty) allEmpty = false;
          }
          if (!allEmpty) rows.add(cells);
        }
        if (rows.isNotEmpty) return rows;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _xlsxCellToString(CellValue? v) {
    if (v == null) return '';
    if (v is TextCellValue) return v.value.toString().trim();
    if (v is IntCellValue) return v.value.toString();
    if (v is DoubleCellValue) return _trimNum(v.value);
    if (v is DateCellValue) {
      return '${v.year}-${v.month.toString().padLeft(2, '0')}-'
          '${v.day.toString().padLeft(2, '0')}';
    }
    if (v is TimeCellValue) {
      return '${v.hour.toString().padLeft(2, '0')}:'
          '${v.minute.toString().padLeft(2, '0')}:'
          '${v.second.toString().padLeft(2, '0')}';
    }
    if (v is BoolCellValue) return v.value ? 'TRUE' : 'FALSE';
    return v.toString().trim();
  }

  static String _trimNum(double d) {
    if (d == d.roundToDouble()) return d.toInt().toString();
    return d.toString();
  }

  // ---------- 工具 ----------

  static String? _cleanDate(String raw) {
    var s = raw.trim();
    // 取日期部分（去时间）
    final idx = s.indexOf(' ');
    if (idx > 0) s = s.substring(0, idx);
    s = s.replaceAll('/', '-');
    // 格式校验 yyyy-MM-dd
    final parts = s.split('-');
    if (parts.length == 3 &&
        parts[0].length == 4 &&
        parts[1].length == 2 &&
        parts[2].length == 2) {
      return s;
    }
    // 兼容 yyyy-M-d
    if (parts.length == 3 && parts[0].length == 4) {
      final p1 = parts[1].padLeft(2, '0');
      final p2 = parts[2].padLeft(2, '0');
      return '${parts[0]}-$p1-$p2';
    }
    return null;
  }

  /// 解析金额字符串 → 分（int）。失败返回 null。
  static int? _parseAmount(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    var negative = false;
    if (s.startsWith('(') && s.endsWith(')')) {
      negative = true;
      s = s.substring(1, s.length - 1);
    }
    s = s.replaceAll(RegExp(r'[¥￥,\s]'), '');
    if (s.startsWith('-')) {
      negative = true;
      s = s.substring(1);
    } else if (s.startsWith('+')) {
      s = s.substring(1);
    }
    if (s.isEmpty) return null;
    final v = double.tryParse(s);
    if (v == null) return null;
    final cents = (v * 100).round();
    return negative ? -cents : cents;
  }

  /// 简易 CSV 解析（处理引号与转义），兼容 UTF-8 BOM
  static List<List<String>> _parseCsv(String text) {
    var s = text;
    if (s.startsWith('\uFEFF')) s = s.substring(1);
    // 处理 \r\n 和 \r
    s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final result = <List<String>>[];
    final row = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < s.length && s[i + 1] == '"') {
            buf.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buf.write(c);
        }
      } else {
        if (c == '"') {
          inQuotes = true;
        } else if (c == ',') {
          row.add(buf.toString().trim());
          buf.clear();
        } else if (c == '\n') {
          row.add(buf.toString().trim());
          buf.clear();
          if (row.any((e) => e.isNotEmpty)) {
            result.add(List.of(row));
          }
          row.clear();
        } else {
          buf.write(c);
        }
      }
      i++;
    }
    // 最后一行
    if (buf.isNotEmpty || row.isNotEmpty) {
      row.add(buf.toString().trim());
      if (row.any((e) => e.isNotEmpty)) result.add(List.of(row));
    }
    return result;
  }

  /// 平台探测：根据表头关键词返回友好名称
  static String detectPlatform(String csvText) {
    final rows = _parseCsv(csvText);
    return detectPlatformRows(rows);
  }

  static String detectPlatformRows(List<List<String>> rows) {
    for (var i = 0; i < rows.length && i < 20; i++) {
      final joined = rows[i].join(',');
      if (joined.contains('支付宝') || joined.contains('交易订单号')) {
        return 'alipay';
      }
      if (joined.contains('微信支付') ||
          (joined.contains('交易单号') && joined.contains('商户单号'))) {
        return 'wechat';
      }
    }
    for (var i = 0; i < rows.length && i < 40; i++) {
      final joined = rows[i].join(',');
      if (joined.contains('金额')) {
        if (joined.contains('对方账号')) return 'alipay';
        if (joined.contains('商户单号')) return 'wechat';
        if (joined.contains('卡号') || joined.contains('交易卡号')) {
          return 'bank';
        }
      }
    }
    return 'unknown';
  }

  static String platformLabel(String p) {
    switch (p) {
      case 'alipay':
        return '支付宝';
      case 'wechat':
        return '微信';
      case 'bank':
        return '银行';
      default:
        return '未知';
    }
  }
}
