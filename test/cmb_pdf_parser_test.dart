import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhang/services/cmb_pdf_parser.dart';

void main() {
  group('招行 PDF 文本解析', () {
    test('基础行：金额符号方向 + 千分位', () {
      const text = '''
招商银行交易流水
2026-03-07 -- 2026-09-07
户 名：梁睿

记账日期 货币 交易金额 联机余额 交易摘要 对手信息
2026-07-08 CNY 1,000.00 1,000.00 网联收款 梁睿
2026-07-09 CNY -29.60 971.43 快捷支付 五华区鑫员点心铺
2026-07-10 CNY -1,234.50 -263.07 银联无卡自助消费 财付通-茶百道
1/11
''';
      final txns = CmbPdfParser.parse(text);
      expect(txns, hasLength(3));
      expect(txns[0].amountCents, 100000);
      expect(txns[0].date, '2026-07-08');
      expect(txns[0].description, '梁睿');
      expect(txns[1].amountCents, -2960);
      expect(txns[1].description, '五华区鑫员点心铺');
      expect(txns[2].amountCents, -123450);
      expect(txns[2].description, '财付通-茶百道');
    });

    test('对手名跨行续接', () {
      const text = '''
记账日期 货币 交易金额 联机余额 交易摘要 对手信息
2026-07-11 CNY -21.00 621.80 快捷支付 云南强林乐家连锁便利店有限公
司
2026-07-12 CNY -8.50 613.30 快捷支付 昆明盒马
''';
      final txns = CmbPdfParser.parse(text);
      expect(txns, hasLength(2));
      expect(txns[0].description, '云南强林乐家连锁便利店有限公司');
    });

    test('摘要词剥离（快捷支付/一网通鼓励金）', () {
      const text = '''
记账日期 货币 交易金额 联机余额 交易摘要 对手信息
2026-07-08 CNY 0.87 972.30 一网通支付鼓励金 其它应收款-零售客户移动支付
2026-07-09 CNY -8.10 833.25 快捷支付 云南7-11
''';
      final txns = CmbPdfParser.parse(text);
      expect(txns[0].description, '其它应收款-零售客户移动支付');
      expect(txns[1].description, '云南7-11');
    });

    test('页脚温馨提示不混入最后一笔', () {
      const text = '''
记账日期 货币 交易金额 联机余额 交易摘要 对手信息
2026-09-07 CNY -55.00 100.00 快捷支付 德克士
——————————————————————————————————————————————
温馨提示：1.交易流水验真：进入一网通首页点击“在线服务”。
2.本流水最终解释权归招商银行所有。
''';
      final txns = CmbPdfParser.parse(text);
      expect(txns, hasLength(1));
      expect(txns[0].description, '德克士');
    });
  });
}
