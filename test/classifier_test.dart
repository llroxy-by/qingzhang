import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhang/models/categories.dart';
import 'package:qingzhang/services/classifier.dart';

void main() {
  group('Classifier 自动分类', () {
    test('餐饮关键词', () {
      expect(Classifier.classify('美团外卖订单123', -2500), 'food');
      expect(Classifier.classify('瑞幸咖啡', -1900), 'food');
      expect(Classifier.classify('食堂消费', -1200), 'food');
      expect(Classifier.classify('滴滴代驾-某某餐厅', -3000), 'food');
    });

    test('交通关键词', () {
      expect(Classifier.classify('滴滴出行快车', -1800), 'transport');
      expect(Classifier.classify('地铁乘车码', -400), 'transport');
      expect(Classifier.classify('12306 火车票', -5200), 'transport');
    });

    test('存钱/转账类（不计消费）', () {
      expect(Classifier.classify('转入零钱通', -100000), 'saving');
      expect(Classifier.classify('基金定投-某某混合', -50000), 'saving');
      expect(Classifier.classify('余额宝-转入', -20000), 'saving');
      expect(Classifier.classify('零钱提现到银行卡', 30000), 'transfer');
      expect(Classifier.classify('零钱通提现', 50000), 'transfer');
      expect(Classifier.classify('招商银行ATM取现', -2000), 'transfer');
    });

    test('平台存取裸描述兜底为中性（不计消费）', () {
      expect(Classifier.classify('零钱通', -888800), 'transfer');
      expect(Classifier.classify('理财通', -100000), 'transfer');
      expect(Classifier.classify('余额宝', -50000), 'transfer');
      expect(Classifier.classify('零钱通转出到卡', -100000), 'transfer');
    });

    test('收益描述不被误判为转账', () {
      expect(Classifier.classify('零钱通收益发放', 120), 'income_invest');
      expect(Classifier.classify('理财通收益到账', 88), 'income_invest');
      expect(Classifier.classify('余额宝收益', 66), 'income_invest');
    });

    test('收入类', () {
      expect(Classifier.classify('工资代发', 800000), 'income_salary');
      expect(Classifier.classify('生活费转账', 300000), 'income_transfer');
      expect(Classifier.classify('零钱通收益发放', 120), 'income_invest');
    });

    test('购物/娱乐/居住', () {
      expect(Classifier.classify('淘宝-某某旗舰店', -9900), 'shopping');
      expect(Classifier.classify('京东商城订单', -20000), 'shopping');
      expect(Classifier.classify('Steam 游戏', -6800), 'entertainment');
      expect(Classifier.classify('房租', -150000), 'housing');
    });

    test('未命中时按收支方向兜底', () {
      expect(Classifier.classify('路边摊煎饼摊（自定义）', -800), 'other_expense');
      expect(Classifier.classify('收到一笔不明款项', 5000), 'income_other');
    });

    test('用户自定义规则优先于内置', () {
      final userRules = [
        {'keyword': '路边摊', 'category': 'food'},
      ];
      expect(
        Classifier.classify('路边摊煎饼', -800, userRules: userRules),
        'food',
      );
    });

    test('大小写不敏感', () {
      expect(Classifier.classify('STEAM 充值', -100), 'entertainment');
      expect(Classifier.classify('steam充值', -100), 'entertainment');
    });
  });

  group('分类定义', () {
    test('所有分类 key 都能查到定义', () {
      for (final c in kCategories) {
        expect(categoryOf(c.key).key, c.key);
      }
      expect(categoryOf('不存在的分类').key, 'unknown');
    });

    test('内置规则引用的分类都存在', () {
      for (final rule in kBuiltinRules) {
        expect(
          kCategoryMap.containsKey(rule[1]),
          isTrue,
          reason: '规则「${rule[0]}」引用了不存在的分类「${rule[1]}」',
        );
      }
    });
  });
}
