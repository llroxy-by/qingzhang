import '../models/txn.dart';
import 'classifier.dart';

/// 招商银行交易流水 PDF（文本提取后）→ 流水列表。
///
/// 样例文本行结构（PDFKit/pdfium 提取）：
///   2026-07-08 CNY 1,000.00 1,000.00 网联收款 梁睿
///   2026-07-09 CNY -29.60 971.43 快捷支付 五华区鑫员点心铺
/// 说明：
///   - 金额带千分位、正负号即收支方向；- = 支出，+ = 收入
///   - "交易摘要 对手信息"合并在一行的末尾（列宽不够时对手名会断行，
///     下一行以裸文本续接，需要拼回上一笔）
///   - 每页顶部有表头行（中英文混排）与页码（如 1/11）需跳过
class CmbPdfParser {
  /// 摘要列常见词（从行尾"摘要+对手"里剥掉，保留商户名，利于分类）
  static const _summaryWords = [
    '一网通支付鼓励金',
    '银联无卡自助消费',
    '银联快捷支付',
    '快捷支付',
    '网联收款',
    '数币兑出',
    '活动现金红包',
    '跨行汇款',
    'ATM取现',
    '代发工资',
    '消费支付',
    '消费',
  ];

  static final _txnRe = RegExp(
    r'^(\d{4}-\d{2}-\d{2})\s+CNY\s+'
    r'(-?[\d,]+\.\d{2})\s+' // 交易金额
    r'(-?[\d,]+\.\d{2})\s*' // 联机余额
    r'(.*)$',
  );
  static final _pageRe = RegExp(r'^\s*\d+\s*/\s*\d+\s*$');
  static final _footerRe = RegExp(
      r'温馨提示|验真|解释权|在线服务|一网通首页|本流水|招商银行所有|^[—\-—\s]+$');

  /// 解析整份文本（多页拼接）为流水。amountCents 带符号（分）。
  static List<Txn> parse(String text, {String source = 'bank'}) {
    final txns = <Txn>[];
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) continue;
      if (_pageRe.hasMatch(line)) continue;
      // 表头 / 非交易行
      if (line.contains('记账日期') ||
          line.contains('Transaction') ||
          line.contains('Date Currency') ||
          line.contains('金额') && line.contains('交易摘要') ||
          line.contains('合计') ||
          line.contains('小计')) {
        continue;
      }
      final m = _txnRe.firstMatch(line);
      if (m != null) {
        final date = m.group(1)!;
        final amount = _parseAmount(m.group(2)!);
        final rawDesc = m.group(4)?.trim() ?? '';
        txns.add(Txn(
          date: date,
          description: _cleanDesc(rawDesc),
          amountCents: amount,
          channel: '',
          source: source,
          category: Classifier.classify(_cleanDesc(rawDesc), amount),
        ));
        continue;
      }
      // 无日期开头的行：多半是上一笔对手名断行续接（如 "司"）
      if (txns.isNotEmpty) {
        final tail = line.trim();
        if (tail.isEmpty) continue;
        // 页脚（温馨提示/验真/解释权等说明文字）不是交易续行
        if (_footerRe.hasMatch(tail)) continue;
        final last = txns.removeLast();
        // 续行拼到上一笔描述尾部（中文断行直接拼接），再统一清理
        final joined = _cleanDesc('${last.description}$tail');
        txns.add(last.copyWith(
          description: joined,
          category: Classifier.classify(joined, last.amountCents),
        ));
      }
    }
    return txns;
  }

  /// 从"摘要+对手"文本剥离摘要词，保留对手/商户名
  static String _cleanDesc(String raw) {
    var d = raw.trim();
    // 页脚说明文字（如"温馨提示：…"）与装饰线截断
    final tip = d.indexOf('温馨提示');
    if (tip >= 0) d = d.substring(0, tip);
    d = d.replaceAll(RegExp(r'[—\-]+$'), '').trim();
    for (final w in _summaryWords) {
      if (d.startsWith(w)) {
        d = d.substring(w.length).trim();
        break; // 只剥最前面一个摘要词
      }
    }
    // 压缩多余空白
    return d.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// "1,000.00" → 100000；"-29.60" → -2960
  static int _parseAmount(String s) {
    final neg = s.trimLeft().startsWith('-');
    final n = double.parse(s.replaceAll(',', '').replaceAll('-', ''));
    final cents = (n * 100).round();
    return neg ? -cents : cents;
  }
}
