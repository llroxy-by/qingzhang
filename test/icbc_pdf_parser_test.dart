import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhang/services/bank_pdf_parser.dart';
import 'package:qingzhang/services/icbc_pdf_parser.dart';

void main() {
  group('工行 PDF 解析', () {
    test('独立日期列 + 金额符号 + 摘要/渠道', () {
      const text = '''
请扫描二维码识别明细真伪
中国工商银行借记账户历史明细（电子版）
卡号 6222************669 户名：测试 2026-08-23
起止日期：2026-03-09 — 2026-09-09
交易日期 账号 储种 序号 币种 钞汇 摘要 地区 收入/支出金额 余额 渠道
2026-08-23
2026-08-23
2026-08-23
15:35:58 0200002901028490175 活期 00000 人民币 钞 开户 0200 +0.00 0.00 自助终端
15:39:17 0200002901028490175 活期 00000 人民币 钞 ATM存款 2502 +1,400.00 1,400.00 ATM交易
16:02:04 0200002901028490175 活期 00000 人民币 钞 消费 0200 -3.50 1,396.50 快捷支付
2026-08-24
17:38:34 0200002901028490175 活期 00000 人民币 钞 退款 0200 +2.80 1,314.20 快捷支付
本页支出算术合计：1,400.60
本页交易笔数：17
''';
      final txns = IcbcPdfParser.parse(text);
      expect(txns, hasLength(4));
      expect(txns[0].date, '2026-08-23');
      expect(txns[0].amountCents, 0);
      expect(txns[0].description, '开户');
      expect(txns[0].channel, '自助终端');
      expect(txns[1].date, '2026-08-23');
      expect(txns[1].amountCents, 140000);
      expect(txns[1].description, 'ATM存款');
      expect(txns[2].amountCents, -350);
      expect(txns[2].description, '消费');
      expect(txns[2].channel, '快捷支付');
      expect(txns[3].date, '2026-08-24');
      expect(txns[3].amountCents, 280);
      expect(txns[3].description, '退款');
    });

    test('带日期前缀的单行格式（pdfium 可能输出）', () {
      const text = '''
交易日期 账号 储种 序号 币种 钞汇 摘要 地区 收入/支出金额 余额 渠道
2026-08-23 15:35:58 0200002901028490175 活期 00000 人民币 钞 开户 0200 +0.00 0.00 自助终端
2026-08-24 10:14:20 0200002901028490175 活期 00000 人民币 钞 消费 0200 -1,299.00 15.20 快捷支付
''';
      final txns = IcbcPdfParser.parse(text);
      expect(txns, hasLength(2));
      expect(txns[0].date, '2026-08-23');
      expect(txns[1].date, '2026-08-24');
      expect(txns[1].amountCents, -129900);
    });

    test('分派：工行特征走工行解析，招行特征走招行解析', () {
      const icbc = '借记账户历史明细 15:39:17 020000 活期 00000 人民币 钞 ATM存款 2502 +1,400.00 1,400.00 ATM交易';
      const cmb = '记账日期 货币 交易金额 联机余额 交易摘要 对手信息\n2026-07-08 CNY 1,000.00 1,000.00 网联收款 梁睿';
      final a = parseBankPdf(icbc);
      final b = parseBankPdf(cmb);
      expect(a.first.amountCents, 140000);
      expect(b.first.amountCents, 100000);
    });

    test('pdfium 交错碎片型（Android 实际布局）', () {
      // 模拟 pdfium 提取：列间空格丢失、日期行穿插、一笔拆 2-3 行
      const text = '''
请扫描二维码识别明细真伪
中国工商银行借记账户历史明细（电子版）
交易日期 账号 储种 序号 币种 钞汇 摘要 地区收入/支出金额 余额 渠道
2026-08-23
15:35:58 0200002901028490175 活期 00000人民币
钞开户 0200+0.00 0.00 自助终端
2026-08-23
15:39:17 0200002901028490175 活期 00000人民币
钞 ATM存款 2502+1,400.001,400.00 ATM交易
2026-08-23
16:02:04 0200002901028490175 活期 00000人民币
钞消费 0200-3.50 1,396.50 快捷支付
2026-08-24
10:14:20 0200002901028490175 活期 00000人民币
钞消费 0200-1,299.00 15.20 快捷支付
本页支出算术合计：1,400.60
本页交易笔数：17
''';
      final txns = IcbcPdfParser.parse(text);
      expect(txns, hasLength(4));
      expect(txns[0].date, '2026-08-23');
      expect(txns[0].amountCents, 0);
      expect(txns[0].description, '开户');
      expect(txns[0].channel, '自助终端');
      expect(txns[1].amountCents, 140000);
      expect(txns[1].description, 'ATM存款');
      expect(txns[1].channel, 'ATM交易');
      expect(txns[2].amountCents, -350);
      expect(txns[2].description, '消费');
      expect(txns[3].date, '2026-08-24');
      expect(txns[3].amountCents, -129900);
      expect(txns[3].channel, '快捷支付');
    });
  });
}
