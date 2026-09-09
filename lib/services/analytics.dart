import '../models/categories.dart';
import '../models/txn.dart';

/// 流水消费统计的纯函数集合（便于单元测试）

/// 过滤出"真消费"：分类属于支出类 且 金额为支出方向。
/// 转账/存钱/收入类不计入消费统计。
List<Txn> expenseOnly(List<Txn> txns) => [
      for (final t in txns)
        if (t.amountCents < 0 && categoryOf(t.category).isExpense) t,
    ];

/// 按分类聚合支出金额（分），key 为分类 key
Map<String, int> expenseByCategory(List<Txn> txns) {
  final map = <String, int>{};
  for (final t in expenseOnly(txns)) {
    map[t.category] = (map[t.category] ?? 0) + t.amountCents;
  }
  return map;
}

/// 单笔消费金额 Top N（按支出金额降序）
List<Txn> topExpenses(List<Txn> txns, {int n = 10}) {
  final list = expenseOnly(txns);
  list.sort((a, b) => a.amountCents.compareTo(b.amountCents)); // 负→更小=更大额
  return list.take(n).toList();
}

/// 合计（分）。空列表返回 0
int sumCents(Iterable<Txn> txns) =>
    txns.fold(0, (s, t) => s + t.amountCents);
