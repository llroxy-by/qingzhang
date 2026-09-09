import '../models/txn.dart';
import 'cmb_pdf_parser.dart';
import 'icbc_pdf_parser.dart';

/// 银行 PDF 账单自动识别 + 解析：
/// 招行（CNY/记账日期表头）→ CmbPdfParser；工行（收入/支出金额列）→ IcbcPdfParser。
List<Txn> parseBankPdf(String text) {
  if (text.contains('收入/支出金额') ||
      text.contains('中国工商银行') ||
      text.contains('借记账户历史明细')) {
    return IcbcPdfParser.parse(text);
  }
  return CmbPdfParser.parse(text);
}
