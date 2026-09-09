import 'package:flutter/material.dart';

import '../models/categories.dart';

/// 分类选择网格（Wrap of ChoiceChip），支出/收入/转账分组展示
class CategoryGrid extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;
  const CategoryGrid({super.key, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<CategoryDef>>{
      '支出': [
        for (final c in kCategories)
          if (c.isExpense) c,
      ],
      '收入/转账': [
        for (final c in kCategories)
          if (c.isIncome || c.isTransfer) c,
      ],
      '其他': [
        for (final c in kCategories)
          if (!c.isExpense && !c.isIncome && !c.isTransfer) c,
      ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in groups.entries)
          if (entry.value.isNotEmpty) ...[
            Text(entry.key,
                style: TextStyle(
                    color: Colors.grey.shade500, fontSize: 11)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in entry.value)
                  ChoiceChip(
                    label: Text('${c.emoji} ${c.label}'),
                    selected: selected == c.key,
                    onSelected: (_) => onSelect(c.key),
                    visualDensity: VisualDensity.compact,
                    selectedColor:
                        const Color(0xFF00897B).withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: selected == c.key
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: selected == c.key
                          ? const Color(0xFF00695C)
                          : Colors.grey.shade800,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
          ],
      ],
    );
  }
}
