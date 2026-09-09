import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhang/models/txn.dart';
import 'package:qingzhang/services/analytics.dart';

Txn _t(String desc, int cents, {String category = 'food'}) => Txn(
      date: '2026-09-01',
      description: desc,
      amountCents: cents,
      category: category,
    );

void main() {
  group('analytics 消费统计', () {
    test('expenseOnly 排除收入/转账/存钱', () {
      final txns = [
        _t('美团', -2500),
        _t('工资', 800000, category: 'income_salary'),
        _t('转出零钱通', 30000, category: 'transfer'),
        _t('基金定投', -50000, category: 'saving'),
      ];
      final only = expenseOnly(txns);
      expect(only.length, 1);
      expect(only.single.amountCents, -2500);
    });

    test('expenseByCategory 聚合', () {
      final txns = [
        _t('美团', -2500),
        _t('滴滴', -1800, category: 'transport'),
        _t('瑞幸', -1900),
        _t('超市', -8000, category: 'shopping'),
      ];
      final byCat = expenseByCategory(txns);
      expect(byCat['food'], -4400);
      expect(byCat['transport'], -1800);
      expect(byCat['shopping'], -8000);
    });

    test('topExpenses 单笔大头排序', () {
      final txns = [
        _t('奶茶', -1500),
        _t('机票', -120000, category: 'transport'),
        _t('手机', -500000, category: 'shopping'),
        _t('酒店', -80000, category: 'housing'),
      ];
      final top = topExpenses(txns, n: 2);
      expect(top.length, 2);
      expect(top[0].description, '手机');
      expect(top[1].description, '机票');
    });

    test('topExpenses 数量不足时全返回', () {
      final txns = [_t('奶茶', -1500)];
      final top = topExpenses(txns, n: 10);
      expect(top.length, 1);
    });

    test('sumCents', () {
      expect(sumCents([_t('a', -100), _t('b', -200)]), -300);
      expect(sumCents(const <Txn>[]), 0);
    });
  });
}
