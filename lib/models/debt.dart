/// 欠债方向：owe = 我欠别人（负债），lend = 别人欠我（应收）
enum DebtDirection {
  owe('我欠的'),
  lend('别人欠我');

  const DebtDirection(this.label);
  final String label;

  static DebtDirection fromName(String? name) {
    for (final d in DebtDirection.values) {
      if (d.name == name) return d;
    }
    return DebtDirection.owe;
  }
}

/// 一笔欠债/借出记录。金额一律存正数（分），方向决定是负债还是应收。
class Debt {
  final String? id; // uuid（同步主键）
  final String name; // 对方：如"老王"、"花呗"
  final DebtDirection direction;
  final int amountCents; // 正数（分）
  final String date; // yyyy-MM-dd 发生日期
  final String note; // 备注（可空）
  final bool settled; // 已结清？
  final int createdAt;
  final int updatedAt;
  final bool deleted;

  const Debt({
    this.id,
    required this.name,
    this.direction = DebtDirection.owe,
    required this.amountCents,
    required this.date,
    this.note = '',
    this.settled = false,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.deleted = false,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'direction': direction.name,
        'amount_cents': amountCents,
        'date': date,
        'note': note,
        'settled': settled ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
      };

  factory Debt.fromMap(Map<String, Object?> m) => Debt(
        id: m['id'] as String?,
        name: (m['name'] as String?) ?? '',
        direction: DebtDirection.fromName(m['direction'] as String?),
        amountCents: (m['amount_cents'] as int?) ?? 0,
        date: (m['date'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        settled: (m['settled'] as int? ?? 0) == 1,
        createdAt: (m['created_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
      );

  Debt copyWith({
    String? name,
    DebtDirection? direction,
    int? amountCents,
    String? date,
    String? note,
    bool? settled,
  }) =>
      Debt(
        id: id,
        name: name ?? this.name,
        direction: direction ?? this.direction,
        amountCents: amountCents ?? this.amountCents,
        date: date ?? this.date,
        note: note ?? this.note,
        settled: settled ?? this.settled,
        createdAt: createdAt,
        updatedAt: updatedAt,
        deleted: deleted,
      );
}
