/// 一次"资金快照"里某个账户的余额
class SnapshotEntry {
  final String? id; // uuid
  final String snapshotId; // uuid
  final String accountId; // uuid
  final int amountCents;
  final int updatedAt;
  final bool deleted;

  const SnapshotEntry({
    this.id,
    required this.snapshotId,
    required this.accountId,
    required this.amountCents,
    this.updatedAt = 0,
    this.deleted = false,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'snapshot_id': snapshotId,
        'account_id': accountId,
        'amount_cents': amountCents,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
      };

  factory SnapshotEntry.fromMap(Map<String, Object?> m) => SnapshotEntry(
        id: m['id'] as String?,
        snapshotId: (m['snapshot_id'] as String?) ?? '',
        accountId: (m['account_id'] as String?) ?? '',
        amountCents: (m['amount_cents'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
      );
}

/// 某一天记录的各账户余额（date 为 yyyy-MM-dd）
class Snapshot {
  final String? id; // uuid
  final String date;
  final int createdAt;
  final int updatedAt;
  final bool deleted;
  final List<SnapshotEntry> entries;

  const Snapshot({
    this.id,
    required this.date,
    required this.entries,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.deleted = false,
  });

  int get totalCents => entries.fold(0, (sum, e) => sum + e.amountCents);

  int? amountOf(String accountId) {
    for (final e in entries) {
      if (e.accountId == accountId) return e.amountCents;
    }
    return null;
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'date': date,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
      };

  factory Snapshot.fromMap(Map<String, Object?> m) => Snapshot(
        id: m['id'] as String?,
        date: (m['date'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
        entries: const [],
      );

  Snapshot withEntries(List<SnapshotEntry> es) =>
      Snapshot(id: id, date: date, createdAt: createdAt, updatedAt: updatedAt, deleted: deleted, entries: es);
}
