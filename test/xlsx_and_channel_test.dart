import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhang/services/csv_importer.dart';

CellValue _cv(Object? v) {
  if (v == null) return TextCellValue('');
  if (v is String) return TextCellValue(v);
  if (v is int) return IntCellValue(v);
  if (v is double) return DoubleCellValue(v);
  if (v is DateTime) return DateCellValue.fromDateTime(v);
  return TextCellValue(v.toString());
}

Uint8List _makeXlsx(List<List<Object?>> rows) {
  final excel = Excel.createExcel();
  final sheet = excel['Sheet1'];
  for (final r in rows) {
    sheet.appendRow([for (final v in r) _cv(v)]);
  }
  return Uint8List.fromList(excel.encode()!);
}

void main() {
  group('xlsx 解析', () {
    test('微信 xlsx 账单（表头带标题行）', () {
      final bytes = _makeXlsx([
        ['微信支付账单明细'],
        ['交易时间', '交易类型', '交易对方', '商品', '收/支', '金额(元)', '支付方式', '当前状态'],
        ['2026-09-01 12:00:00', '商户消费', '美团', '外卖订单', '支出', 25.5, '零钱', '支付成功'],
        ['2026-09-02 08:30:00', '商户消费', '滴滴出行', '快车', '支出', 18.0, '招商银行(8899)', '支付成功'],
        ['2026-09-03 20:00:00', '转账', '张三', '生活费', '收入', 500, '零钱', '已收钱'],
      ]);
      final r = CsvImporter.parseBytes(bytes, '微信账单.xlsx', source: 'wechat');
      expect(r.txns.length, 3);
      expect(r.txns[0].amountCents, -2550);
      expect(r.txns[0].date, '2026-09-01');
      expect(r.txns[0].channel, '零钱');
      expect(r.txns[1].amountCents, -1800);
      expect(r.txns[1].channel, '招商银行(8899)');
      expect(r.txns[2].amountCents, 50000);
    });

    test('xlsx 数值金额无小数点尾巴', () {
      final bytes = _makeXlsx([
        ['日期', '金额', '备注'],
        ['2026-09-01', 88, '整数'],
        ['2026-09-02', 88.6, '小数'],
      ]);
      final r = CsvImporter.parseBytes(bytes, 'a.xlsx');
      expect(r.txns[0].amountCents, 8800);
      expect(r.txns[1].amountCents, 8860);
    });
  });

  group('支付渠道提取与银行卡识别', () {
    test('微信 CSV 提取支付方式列', () {
      const csv = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态\n'
          '2026-09-05 13:30:00,商户消费,某店,奶茶,支出,15.00,零钱通,支付成功\n'
          '2026-09-06 20:00:00,商户消费,京东,商品,支出,99.00,工商银行储蓄卡(1234),支付成功\n';
      final r = CsvImporter.parse(csv);
      expect(r.txns[0].channel, '零钱通');
      expect(r.txns[1].channel, '工商银行储蓄卡(1234)');
    });

    test('银行卡渠道识别', () {
      expect(CsvImporter.isBankChannel('招商银行(8899)'), isTrue);
      expect(CsvImporter.isBankChannel('工商银行储蓄卡(1234)'), isTrue);
      expect(CsvImporter.isBankChannel('信用卡(4567)'), isTrue);
      expect(CsvImporter.isBankChannel('花呗'), isTrue);
      expect(CsvImporter.isBankChannel('零钱'), isFalse);
      expect(CsvImporter.isBankChannel('零钱通'), isFalse);
      expect(CsvImporter.isBankChannel('余额宝'), isFalse);
      expect(CsvImporter.isBankChannel('余额'), isFalse);
      expect(CsvImporter.isBankChannel(''), isFalse);
    });

    test('支付宝 CSV 提取收/付款方式列', () {
      const csv = '交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,'
          '收/付款方式,交易状态,交易订单号,商家订单号,备注\n'
          '2026-09-01 12:00:00,餐饮美食,某餐厅,alipay@x,美团外卖,支出,25.00,'
          '余额宝,交易成功,1,a,\n'
          '2026-09-01 12:10:00,数码,某店,alipay@y,手机壳,支出,30.00,'
          '招商银行(8899),交易成功,2,b,\n';
      final r = CsvImporter.parse(csv);
      expect(r.txns[0].channel, '余额宝');
      expect(r.txns[1].channel, '招商银行(8899)');
    });
  });

  group('CSV 文本仍然可用', () {
    test('原有 CSV 路径回归', () {
      const csv = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态\n'
          '2026-09-05 13:30:00,商户消费,滴滴出行,滴滴快车,支出,18.50,零钱,支付成功\n';
      final r = CsvImporter.parse(csv, source: 'wechat');
      expect(r.txns.single.amountCents, -1850);
      expect(r.txns.single.channel, '零钱');
    });

    test('损坏的 xlsx 返回警告而非崩溃', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final r = CsvImporter.parseBytes(bytes, 'bad.xlsx');
      expect(r.txns, isEmpty);
      expect(r.warnings, isNotEmpty);
    });
  });
}
