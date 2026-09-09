/// 一条交易流水（从账单导入）
/// amountCents 带符号：支出为负，收入为正
class Txn {
  final String? id; // uuid（同步主键；导入预览时可为 null）
  final String date; // yyyy-MM-dd
  final String description;
  final int amountCents;

  /// 支付渠道原文，如"零钱""招商银行(8899)"
  final String channel;

  final String source; // alipay / wechat / bank / manual
  final String category; // 分类 key，见 categories.dart
  final String? accountId; // uuid
  final String? tripId; // uuid（旅程）
  final int createdAt;
  final int updatedAt; // 毫秒时间戳（同步用）
  final bool deleted;

  const Txn({
    this.id,
    required this.date,
    required this.description,
    required this.amountCents,
    this.channel = '',
    this.source = 'manual',
    this.category = 'unknown',
    this.accountId,
    this.tripId,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.deleted = false,
  });

  bool get isExpense => amountCents < 0;
  bool get isIncome => amountCents > 0;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'date': date,
        'description': description,
        'amount_cents': amountCents,
        'channel': channel,
        'source': source,
        'category': category,
        'account_id': accountId,
        'trip_id': tripId,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
      };

  factory Txn.fromMap(Map<String, Object?> m) => Txn(
        id: m['id'] as String?,
        date: (m['date'] as String?) ?? '',
        description: (m['description'] as String?) ?? '',
        amountCents: (m['amount_cents'] as int?) ?? 0,
        channel: (m['channel'] as String?) ?? '',
        source: (m['source'] as String?) ?? 'manual',
        category: (m['category'] as String?) ?? 'unknown',
        accountId: m['account_id'] as String?,
        tripId: m['trip_id'] as String?,
        createdAt: (m['created_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
      );

  Txn copyWith({
    String? description,
    String? category,
    String? accountId,
    String? channel,
    String? tripId,
    bool clearAccount = false,
    bool clearTrip = false,
  }) =>
      Txn(
        id: id,
        date: date,
        description: description ?? this.description,
        amountCents: amountCents,
        channel: channel ?? this.channel,
        source: source,
        category: category ?? this.category,
        accountId: clearAccount ? null : (accountId ?? this.accountId),
        tripId: clearTrip ? null : (tripId ?? this.tripId),
        createdAt: createdAt,
        updatedAt: updatedAt,
        deleted: deleted,
      );
}
