import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhang/services/csv_importer.dart';

void main() {
  group('CsvImporter 平台探测', () {
    test('识别支付宝格式', () {
      const csv = '交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,'
          '收/付款方式,交易状态,交易订单号,商家订单号,备注\n'
          '2026-09-01 12:00:00,餐饮美食,某某餐厅,xxx,美团外卖,支出,25.00,'
          '余额宝,交易成功,123,456,\n';
      expect(CsvImporter.detectPlatform(csv), 'alipay');
    });

    test('识别微信格式', () {
      const csv = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,'
          '当前状态,交易单号,商户单号,备注\n'
          '2026-09-01 12:00:00,商户消费,某店,商品A,支出,10.00,零钱,支付成功,'
          't1,m1,\n';
      expect(CsvImporter.detectPlatform(csv), 'wechat');
    });
  });

  group('CsvImporter 支付宝账单解析', () {
    test('跳过文件头噪音、正确识别收支方向', () {
      const csv = '---------------------------------BEGIN-------------------------------\n'
          '支付宝交易记录明细查询\n'
          '账号:[test@test.com]\n'
          '起始日期:[2026-09-01 00:00:00]    终止日期:[2026-09-07 23:59:59]\n'
          '\n'
          '交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,'
          '交易状态,交易订单号,商家订单号,备注\n'
          '2026-09-01 12:00:00,餐饮美食,某餐厅,alipay@x,美团外卖,支出,25.00,'
          '余额宝,交易成功,1,a,\n'
          '2026-09-02 09:00:00,转账,李四,alipay@y,生活费,收入,500.00,'
          '余额,交易成功,2,b,\n'
          '2026-09-03 10:00:00,退款,某店,alipay@z,订单退款,不计收支,25.00,'
          '余额,退款成功,3,c,\n'
          '---------------------------------END---------------------------------\n'
          '合计:2笔\n';
      final r = CsvImporter.parse(csv, source: 'alipay');
      expect(r.txns.length, 2, reason: '退款行应被跳过');
      expect(r.skipped, greaterThan(0));
      // 支出为负、收入为正
      final expense = r.txns.firstWhere((t) => t.description.contains('美团'));
      final income = r.txns.firstWhere((t) => t.description.contains('生活费'));
      expect(expense.amountCents, -2500);
      expect(income.amountCents, 50000);
      expect(expense.date, '2026-09-01');
    });
  });

  group('CsvImporter 微信账单解析', () {
    test('微信格式（金额列名带单位）', () {
      const csv = '微信支付账单明细,,,,,,,\n'
          '微信昵称：[测试],,,,,,,\n'
          '\n'
          '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,'
          '交易单号,商户单号,备注\n'
          '2026-09-05 13:30:00,商户消费,滴滴出行,滴滴快车,支出,18.50,零钱,'
          '支付成功,t1,m1,\n'
          '2026-09-06 20:00:00,微信红包,王五,红包,收入,200.00,零钱,已存入零钱,'
          't2,m2,\n';
      final r = CsvImporter.parse(csv, source: 'wechat');
      expect(r.txns.length, 2);
      expect(r.txns[0].amountCents, -1850);
      expect(r.txns[1].amountCents, 20000);
      expect(r.txns[0].date, '2026-09-05');
    });
  });

  group('CsvImporter 银行双列格式', () {
    test('收入/支出独立两列', () {
      const csv = '交易日期,交易时间,摘要,收入,支出,余额\n'
          '2026/09/01,10:00:00,工资代发,8000.00,,15000.00\n'
          '2026/09/02,12:00:00,美团外卖,,25.50,14974.50\n';
      final r = CsvImporter.parse(csv, source: 'bank');
      expect(r.txns.length, 2);
      expect(r.txns[0].amountCents, 800000);
      expect(r.txns[1].amountCents, -2550);
    });
  });

  group('金额解析', () {
    test('千分位/货币符号/括号负数', () {
      final csv = '日期,金额,备注\n'
          '2026-09-01,"1,234.56",千分位\n'
          '2026-09-02,¥200.00,人民币符号\n'
          '2026-09-03,"(88.00)",括号负数\n'
          '2026-09-04,-45.5,负号\n';
      final r = CsvImporter.parse(csv);
      expect(r.txns.length, 4);
      expect(r.txns[0].amountCents, 123456);
      // 无收支列时符号只能来自金额本身；¥200 是正数
      expect(r.txns[1].amountCents, 20000);
      expect(r.txns[2].amountCents, -8800);
      expect(r.txns[3].amountCents, -4550);
    });

    test('日期格式兼容 yyyy/M/d', () {
      final csv = '日期,金额\n2026/9/1,10.00\n';
      final r = CsvImporter.parse(csv);
      expect(r.txns.single.date, '2026-09-01');
    });

    test('引号内逗号不拆列', () {
      final csv = '日期,摘要,金额\n2026-09-01,"超市,便利店",10.00\n';
      final r = CsvImporter.parse(csv);
      expect(r.txns.length, 1);
      expect(r.txns.single.description, '超市,便利店');
    });
  });

  group('空文件与坏格式', () {
    test('无表头时给出警告', () {
      final r = CsvImporter.parse('随便一些文字\n没有金额列\n');
      expect(r.txns, isEmpty);
      expect(r.warnings, isNotEmpty);
    });

    test('空文件', () {
      final r = CsvImporter.parse('');
      expect(r.txns, isEmpty);
      expect(r.warnings, isNotEmpty);
    });
  });

  group('编码与文件头噪音（真实支付宝电脑端结构）', () {
    test('GBK 编码 + 单列汇总叙述行不误判为表头', () {
      // 结构还原支付宝电脑端导出：分隔线/账单信息/收支汇总（单列）在前，
      // 真正的表头在第 6 行且末尾列带多余逗号。
      final csv = '----'
          '------------------------------------------------------------------------------------\n'
          '账单信息：\n'
          '共194笔记录\n'
          '收入：10笔 1428.76元\n'
          '支出：90笔 16137.64元\n'
          '----'
          '------------------------------------------------------------------------------------\n'
          '交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,\n'
          '2026-09-08 12:00:00,收入,某人,alipay1,收钱码收款,收入,50.00,余额,交易成功,1001,,,\n'
          '2026-09-07 13:00:00,支出,某店,alipay2,早餐,支出,12.50,余额,交易成功,1002,,,\n';
      // 转成 GBK 字节（支付宝电脑端真实编码）
      final bytes = Uint8List.fromList(gbk.encode(csv));
      final r = CsvImporter.parseBytes(bytes, 'alipay_gbk.csv',
          source: 'alipay');
      expect(r.txns, hasLength(2), reason: 'warnings=${r.warnings}');
      expect(r.warnings, isEmpty);
      expect(r.txns[0].amountCents, 5000);
      expect(r.txns[0].date, '2026-09-08');
      expect(r.txns[0].channel, contains('余额'));
      expect(r.txns[1].amountCents, -1250);
    });
  });
}
