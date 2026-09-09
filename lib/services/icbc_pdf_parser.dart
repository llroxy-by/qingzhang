import '../models/txn.dart';
import 'classifier.dart';

/// 工商银行借记账户历史明细 PDF（文本提取后）→ 流水列表。
///
/// 文本提取有两种布局，自动适配：
/// 1. PDFKit（macOS 预览）：整行输出，日期先整列列出再交易行
/// 2. pdfium（Android pdfrx）：表格被拆成碎片行，列间空格常丢失：
///      2026-08-23
///      15:35:58 0200002901028490175 活期 00000人民币
///      钞开户 0200+0.00 0.00 自助终端
///    日期行穿插在每笔之前（交错型）
///
/// 因此不依赖"空格分列"，改为：日期行切块 + 块内正则扫描
/// （±金额 / 摘要词表 / 渠道词表），容错两种布局。
class IcbcPdfParser {
  static final _dateRe = RegExp(r'^\s*(\d{4}-\d{2}-\d{2})\s*$');
  static final _timeRe = RegExp(r'\d{2}:\d{2}:\d{2}');
  // 千分位规范金额（带 +/- 号）
  static final _amountRe =
      RegExp(r'[+-]\d{1,3}(?:,\d{3})*\.\d{2}');

  // 行级噪声（表头/页眉/页脚/汇总说明）——整行丢弃
  static bool _noiseLine(String t) {
    return t.contains('中国工商银行') ||
        t.contains('本页') ||
        t.contains('起止日期') ||
        t.contains('请扫描二维码') ||
        t.contains('识别明细真伪') ||
        t.contains('算术合计') ||
        t.contains('交易日期') ||
        t.contains('户名') ||
        (t.contains('共 ') && t.contains('页')) ||
        t.contains('历史明细') && t.contains('电子版');
  }

  // 摘要词表（按长度降序，先匹配长词再短词）
  static const _summaryWords = [
    'ATM存款', 'ATM取款', '跨行汇款', '账户管理', '短信服务',
    '转账', '消费', '退款', '开户', '结息', '利息', '工资',
    '报销', '还款', '缴费', '收款', '取款', '汇款', '存入', '代发',
  ];
  // 渠道词表
  static const _channelWords = [
    '自助终端', 'ATM交易', '快捷支付', '手机银行', '网上银行',
    '超级网银', '柜面', '银联', '支付宝', '微信', '他行', '人行',
  ];

  static String? _firstWord(String text, List<String> words) {
    for (final w in words) {
      if (text.contains(w)) return w;
    }
    return null;
  }

  /// 解析整份文本为流水
  static List<Txn> parse(String text, {String source = 'bank'}) {
    // 收集有效行（跳过噪声行/空行），去两边空白
    final lines = <String>[];
    for (final raw in text.split('\n')) {
      final t = raw.trim();
      if (t.isEmpty || _noiseLine(t)) continue;
      lines.add(t);
    }
    // 判断布局：
    //  整列型（PDFKit 等）：同日多笔的日期行连续相邻输出（8/23×3 紧贴）→ 用配对法
    //  交错型（pdfium/Android）：日期行被交易碎片隔开（几乎无相邻 date 行）→ 用块法
    var adjacentDatePairs = 0;
    for (var i = 0; i < lines.length - 1; i++) {
      if (_dateRe.hasMatch(lines[i]) && _dateRe.hasMatch(lines[i + 1])) {
        adjacentDatePairs++;
      }
    }
    final hasStandaloneDate = lines.any(_dateRe.hasMatch);
    // 有独立日期行且它们不相邻（被交易碎片隔开）→ pdfium 交错型
    final interleaved = hasStandaloneDate && adjacentDatePairs == 0;

    final txns = <Txn>[];
    if (interleaved) {
      // ---- 交错碎片型：日期行切块，块内扫描 ----
      String? date;
      final buf = StringBuffer();
      void flush() {
        if (date == null) return;
        final b = buf.toString();
        final amount = _amountRe.firstMatch(b);
        if (amount == null) return;
        final cents = _parseAmount(amount.group(0)!);
        final summary = _firstWord(b, _summaryWords);
        final channel = _firstWord(b, _channelWords);
        final desc = summary ?? '';
        txns.add(Txn(
          date: date,
          description: desc,
          amountCents: cents,
          channel: channel ?? '',
          source: source,
          category: Classifier.classify(desc, cents),
        ));
      }

      for (final line in lines) {
        final dm = _dateRe.firstMatch(line);
        if (dm != null) {
          flush();
          buf.clear();
          date = dm.group(1);
        } else {
          // 碎片行：去掉纯空白后拼进块（去噪已在行级完成）
          buf.write(line.replaceAll(RegExp(r'\s+'), ''));
        }
      }
      flush();
    } else {
      // ---- 整行/整列型（PDFKit 等）：原逐行解析 ----
      _parseWholeLines(lines, txns, source);
    }
    return txns;
  }

  /// 整行型解析：日期独立行队列配对 + 尾部固定 token
  static void _parseWholeLines(
      List<String> lines, List<Txn> txns, String source) {
    final pendingDates = <String>[];
    var lastDate = '';
    for (final line in lines) {
      final dm = _dateRe.firstMatch(line);
      if (dm != null) {
        pendingDates.add(dm.group(1)!);
        continue;
      }
      if (!_timeRe.hasMatch(line)) continue;
      // 去掉开头的日期前缀（若有），并优先作为本笔日期
      var body = line;
      String? inlineDate;
      final pre = RegExp(r'^(\d{4}-\d{2}-\d{2})\s+').firstMatch(line);
      if (pre != null) {
        body = line.substring(pre.end);
        inlineDate = pre.group(1);
      }
      // 去掉开头的 时间:分:秒
      final tm = RegExp(r'^\d{2}:\d{2}:\d{2}\s*').firstMatch(body);
      if (tm != null) body = body.substring(tm.end);
      final toks = body.trim().split(RegExp(r'\s+'));
      if (toks.length < 6) continue;
      String date;
      if (inlineDate != null) {
        date = inlineDate;
      } else if (pendingDates.isNotEmpty) {
        date = pendingDates.removeAt(0);
      } else {
        date = lastDate;
      }
      // 金额定位：带符号千分位金额
      int amountIdx = -1;
      final am = RegExp(r'^[+-]\d{1,3}(?:,\d{3})*\.\d{2}$');
      for (var i = toks.length - 3; i >= 0 && i >= toks.length - 7; i--) {
        if (am.hasMatch(toks[i])) {
          amountIdx = i;
          break;
        }
      }
      if (amountIdx < 0) continue;
      final amount = _parseAmount(toks[amountIdx]);
      final channel = toks[toks.length - 1];
      // 摘要 = 金额前那个非"地区(纯3-4位数字)" token
      var desc = '';
      final region = RegExp(r'^\d{3,4}$');
      if (amountIdx - 1 >= 0 && !region.hasMatch(toks[amountIdx - 1])) {
        desc = toks[amountIdx - 1];
      } else if (amountIdx - 2 >= 0) {
        desc = toks[amountIdx - 2];
      }
      if (date.isEmpty) date = lastDate;
      lastDate = date;
      txns.add(Txn(
        date: date,
        description: desc,
        amountCents: amount,
        channel: channel,
        source: source,
        category: Classifier.classify(desc, amount),
      ));
    }
  }

  static int _parseAmount(String s) {
    final n = double.parse(s.replaceAll(',', '').replaceAll('+', ''));
    return (n * 100).round();
  }
}
