/// 账户类型：决定资金构成分组 + "存下来的钱"归类
enum AccountType {
  bank('银行卡'),
  wealth('零钱/理财'),
  invest('投资'),
  other('其他');

  const AccountType(this.label);
  final String label;

  /// 转入这类账户 = 存起来了（不算消费）
  bool get isSaving => this == AccountType.wealth || this == AccountType.invest;

  static AccountType fromName(String? name) {
    for (final t in AccountType.values) {
      if (t.name == name) return t;
    }
    return AccountType.other;
  }
}

/// 资金构成里的一个账户，如：工行卡、招行卡、零钱通、基金、币安
class Account {
  final String? id; // uuid（同步主键）
  final String name;
  final String emoji;
  final AccountType type;
  final int sortOrder;
  final bool isActive;

  /// 渠道关键词（逗号分隔）：账单"支付方式"列包含任一关键词即归此账户
  final String channelKeywords;

  /// 期初设置：从 openingDate 起本账户的流水是完整的
  final String? openingDate; // yyyy-MM-dd
  final int? openingCents;

  final int updatedAt; // 毫秒时间戳（同步用）
  final bool deleted;

  const Account({
    this.id,
    required this.name,
    this.emoji = '💳',
    this.type = AccountType.bank,
    this.sortOrder = 0,
    this.isActive = true,
    this.channelKeywords = '',
    this.openingDate,
    this.openingCents,
    this.updatedAt = 0,
    this.deleted = false,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'emoji': emoji,
        'type': type.name,
        'sort_order': sortOrder,
        'is_active': isActive ? 1 : 0,
        'channel_keywords': channelKeywords,
        'opening_date': openingDate,
        'opening_cents': openingCents,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
      };

  factory Account.fromMap(Map<String, Object?> m) => Account(
        id: m['id'] as String?,
        name: (m['name'] as String?) ?? '',
        emoji: (m['emoji'] as String?) ?? '💳',
        type: AccountType.fromName(m['type'] as String?),
        sortOrder: (m['sort_order'] as int?) ?? 0,
        isActive: (m['is_active'] as int? ?? 1) == 1,
        channelKeywords: (m['channel_keywords'] as String?) ?? '',
        openingDate: m['opening_date'] as String?,
        openingCents: m['opening_cents'] as int?,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
      );

  Account copyWith({
    String? name,
    String? emoji,
    AccountType? type,
    int? sortOrder,
    bool? isActive,
    String? channelKeywords,
    String? openingDate,
    int? openingCents,
    bool clearOpening = false,
  }) =>
      Account(
        id: id,
        name: name ?? this.name,
        emoji: emoji ?? this.emoji,
        type: type ?? this.type,
        sortOrder: sortOrder ?? this.sortOrder,
        isActive: isActive ?? this.isActive,
        channelKeywords: channelKeywords ?? this.channelKeywords,
        openingDate: clearOpening ? null : (openingDate ?? this.openingDate),
        openingCents: clearOpening ? null : (openingCents ?? this.openingCents),
        updatedAt: updatedAt,
        deleted: deleted,
      );
}
