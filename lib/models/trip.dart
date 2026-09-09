import 'txn.dart';

/// 一段"旅程"（如一次旅游）：把某段时间内的消费归到一起统计
class Trip {
  final String? id; // uuid（同步主键）
  final String name;
  final String startDate; // yyyy-MM-dd
  final String endDate; // yyyy-MM-dd
  final int createdAt;
  final int updatedAt;
  final bool deleted;

  const Trip({
    this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.deleted = false,
  });

  /// 这笔流水是否属于本旅程：手动归入的（tripId 指向），
  /// 或日期落在旅程起止区间内的（区间内消费自动包含，
  /// 机票/返程后的 AA 等区间外消费则手动归入）。
  bool includes(Txn t) =>
      t.tripId == id ||
      (startDate.isNotEmpty &&
          endDate.isNotEmpty &&
          t.date.compareTo(startDate) >= 0 &&
          t.date.compareTo(endDate) <= 0);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'start_date': startDate,
        'end_date': endDate,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
      };

  factory Trip.fromMap(Map<String, Object?> m) => Trip(
        id: m['id'] as String?,
        name: (m['name'] as String?) ?? '',
        startDate: (m['start_date'] as String?) ?? '',
        endDate: (m['end_date'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
      );
}
