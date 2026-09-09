import '../models/categories.dart';

/// 自动分类引擎：
/// 1) 先匹配用户自定义规则（数据库 category_rules，用户可添加/删除）
/// 2) 再按顺序匹配内置关键词规则（kBuiltinRules）
/// 3) 都没匹配上 → 按收支方向给默认分类
class Classifier {
  /// userRules: 来自数据库 category_rules 的行列表 [{keyword, category}]
  static String classify(String description, int amountCents,
      {List<Map<String, Object?>> userRules = const []}) {
    final d = description.trim().toLowerCase();

    // 1. 用户自定义规则优先
    for (final r in userRules) {
      final kw = (r['keyword'] as String).trim().toLowerCase();
      if (kw.isNotEmpty && d.contains(kw)) {
        return (r['category'] as String?) ?? 'unknown';
      }
    }

    // 2. 内置规则（按顺序，先出现的优先）
    for (final rule in kBuiltinRules) {
      final kw = rule[0].toLowerCase();
      if (d.contains(kw)) {
        return rule[1];
      }
    }

    // 3. 兜底：按收支方向给默认分类
    if (amountCents > 0) return 'income_other';
    return 'other_expense';
  }

  /// 把一个关键词快速归类（给"从这条流水学习规则"用，逻辑同 classify）
  static String classifyKeyword(String keyword) {
    return classify(keyword, 0, userRules: const []);
  }
}
