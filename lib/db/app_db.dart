import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/account.dart';
import '../models/snapshot.dart';
import '../models/trip.dart';
import '../models/txn.dart';
import '../utils/uuid.dart';

/// 轻账本地数据库 v4：
/// - 业务表主键为 uuid（与云端一致，跨设备同步）
/// - 所有写操作带 updated_at（毫秒），删除为软删（deleted=1，保留 tombstone 供同步）
/// - 云端同步：push 全量 → 服务器 last-write-wins 合并 → 返回全量 → 本地替换
class AppDb {
  static const _dbName = 'qingzhang.db';
  static const _dbVersion = 4;

  /// 与服务器同步的业务表（服务器按这些表合并）
  static const syncTables = [
    'accounts',
    'snapshots',
    'snapshot_entries',
    'txns',
    'trips',
  ];

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, _dbName),
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: _ensureSchema,
    );
    return _db!;
  }

  /// 兜底自检：不依赖 user_version。
  /// v1.6.0 曾把旧库的版本号标成 4 而未迁移表结构（无 onUpgrade），
  /// 导致后续版本号的升级钩子不触发、查询报 no such column: deleted。
  /// 这里每次打开检查 accounts 是否含 v4 的 deleted 列，旧结构一律重建。
  Future<void> _ensureSchema(Database db) async {
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='accounts'");
    if (tables.isEmpty) {
      // 无 accounts 表（异常态）也重建
      await _dropAllAndRecreate(db);
      return;
    }
    final cols = await db.rawQuery('PRAGMA table_info(accounts)');
    final hasDeleted = cols.any((c) => c['name'] == 'deleted');
    if (!hasDeleted) {
      await _dropAllAndRecreate(db);
    }
  }

  Future<void> _dropAllAndRecreate(Database db) async {
    await db.execute('DROP TABLE IF EXISTS accounts');
    await db.execute('DROP TABLE IF EXISTS snapshots');
    await db.execute('DROP TABLE IF EXISTS snapshot_entries');
    await db.execute('DROP TABLE IF EXISTS txns');
    await db.execute('DROP TABLE IF EXISTS trips');
    await db.execute('DROP TABLE IF EXISTS category_rules');
    await db.execute('DROP TABLE IF EXISTS meta');
    await _createSchemaAndSeed(db);
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createSchemaAndSeed(db);
  }

  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    // v4 是破坏性重构（int 自增主键 → uuid 主键 + 软删/时间戳）。
    // 旧结构（v1~v3）无法平滑迁移，按约定直接重建（旧数据由用户重新导入）。
    if (oldV < 4) {
      await _dropAllAndRecreate(db);
    }
  }

  Future<void> _createSchemaAndSeed(Database db) async {
    await db.execute('''
      CREATE TABLE accounts(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        emoji TEXT NOT NULL DEFAULT '💳',
        type TEXT NOT NULL DEFAULT 'bank',
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        channel_keywords TEXT NOT NULL DEFAULT '',
        opening_date TEXT,
        opening_cents INTEGER,
        updated_at INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE snapshots(
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE snapshot_entries(
        id TEXT PRIMARY KEY,
        snapshot_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        amount_cents INTEGER NOT NULL,
        updated_at INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE txns(
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        amount_cents INTEGER NOT NULL,
        channel TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'manual',
        category TEXT NOT NULL DEFAULT 'unknown',
        account_id TEXT,
        trip_id TEXT,
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE trips(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE category_rules(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        keyword TEXT NOT NULL UNIQUE,
        category TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // 本地元信息（账号/服务器地址/上次同步时间）
    await db.execute('''
      CREATE TABLE meta(
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_txns_date ON txns(date) WHERE deleted = 0');
    await db.execute(
        'CREATE INDEX idx_entries_snap ON snapshot_entries(snapshot_id) WHERE deleted = 0');

    // 注意：不播种任何默认账户——资金构成由用户手动添加
  }

  // ==================== 元信息 ====================

  Future<String?> getMeta(String key) async {
    final db = await database;
    final r = await db.query('meta', where: 'key = ?', whereArgs: [key]);
    if (r.isEmpty) return null;
    return r.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    final db = await database;
    await db.insert('meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ==================== 账户 ====================

  Future<List<Account>> listAccounts({bool onlyActive = false}) async {
    final db = await database;
    final rows = await db.query(
      'accounts',
      where: onlyActive ? 'is_active = 1 AND deleted = 0' : 'deleted = 0',
      orderBy: 'sort_order ASC, id ASC',
    );
    return rows.map(Account.fromMap).toList();
  }

  Future<String> insertAccount(Account a) async {
    final db = await database;
    final id = a.id ?? genUuid();
    final row = a.copyWith().toMap()
      ..remove('id')
      ..remove('updated_at')
      ..remove('deleted');
    await db.insert('accounts', {
      ...row,
      'id': id,
      'updated_at': nowMillis(),
      'deleted': 0,
    });
    return id;
  }

  Future<void> updateAccount(Account a) async {
    final db = await database;
    final row = a.toMap()
      ..remove('id')
      ..remove('updated_at')
      ..remove('deleted');
    await db.update('accounts', {
      ...row,
      'updated_at': nowMillis(),
    }, where: 'id = ?', whereArgs: [a.id]);
  }

  /// 软删除账户（同步用 tombstone 保留）
  Future<void> deleteAccount(String id) async {
    final db = await database;
    await db.update('accounts',
        {'deleted': 1, 'updated_at': nowMillis()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> reorderAccounts(List<Account> accounts) async {
    final db = await database;
    final batch = db.batch();
    for (var i = 0; i < accounts.length; i++) {
      batch.update('accounts', {'sort_order': i, 'updated_at': nowMillis()},
          where: 'id = ?', whereArgs: [accounts[i].id]);
    }
    await batch.commit(noResult: true);
  }

  // ==================== 快照 ====================

  Future<List<Snapshot>> listSnapshots() async {
    final db = await database;
    final rows = await db.query('snapshots',
        where: 'deleted = 0', orderBy: 'date DESC');
    final result = <Snapshot>[];
    for (final r in rows) {
      final s = Snapshot.fromMap(r);
      final entries = await db.query('snapshot_entries',
          where: 'snapshot_id = ? AND deleted = 0', whereArgs: [s.id]);
      result.add(s.withEntries(entries.map(SnapshotEntry.fromMap).toList()));
    }
    return result;
  }

  Future<Snapshot?> latestSnapshot() async {
    final db = await database;
    final rows = await db.query('snapshots',
        where: 'deleted = 0', orderBy: 'date DESC', limit: 1);
    if (rows.isEmpty) return null;
    final s = Snapshot.fromMap(rows.first);
    final entries = await db.query('snapshot_entries',
        where: 'snapshot_id = ? AND deleted = 0', whereArgs: [s.id]);
    return s.withEntries(entries.map(SnapshotEntry.fromMap).toList());
  }

  Future<Snapshot?> snapshotOn(String date) async {
    final db = await database;
    final rows = await db.query('snapshots',
        where: 'date = ? AND deleted = 0', whereArgs: [date]);
    if (rows.isEmpty) return null;
    final s = Snapshot.fromMap(rows.first);
    final entries = await db.query('snapshot_entries',
        where: 'snapshot_id = ? AND deleted = 0', whereArgs: [s.id]);
    return s.withEntries(entries.map(SnapshotEntry.fromMap).toList());
  }

  /// 保存（覆盖式）某一天的快照。date 已存在则更新行与明细。
  Future<void> saveSnapshot(Snapshot snap) async {
    final db = await database;
    final now = nowMillis();
    await db.transaction((txn) async {
      final existing = await txn.query('snapshots',
          where: 'date = ? AND deleted = 0', whereArgs: [snap.date]);
      String snapId;
      if (existing.isEmpty) {
        snapId = genUuid();
        await txn.insert('snapshots', {
          'id': snapId,
          'date': snap.date,
          'created_at': now,
          'updated_at': now,
          'deleted': 0,
        });
      } else {
        snapId = existing.first['id'] as String;
        await txn.update('snapshots', {'updated_at': now},
            where: 'id = ?', whereArgs: [snapId]);
        // 旧明细软删
        await txn.update('snapshot_entries',
            {'deleted': 1, 'updated_at': now},
            where: 'snapshot_id = ? AND deleted = 0', whereArgs: [snapId]);
      }
      for (final e in snap.entries) {
        await txn.insert('snapshot_entries', {
          'id': genUuid(),
          'snapshot_id': snapId,
          'account_id': e.accountId,
          'amount_cents': e.amountCents,
          'updated_at': now,
          'deleted': 0,
        });
      }
    });
  }

  Future<void> deleteSnapshot(String id) async {
    final db = await database;
    final now = nowMillis();
    await db.update('snapshots', {'deleted': 1, 'updated_at': now},
        where: 'id = ?', whereArgs: [id]);
    await db.update('snapshot_entries',
        {'deleted': 1, 'updated_at': now},
        where: 'snapshot_id = ? AND deleted = 0', whereArgs: [id]);
  }

  // ==================== 旅程 ====================

  Future<List<Trip>> listTrips() async {
    final db = await database;
    final rows = await db.query('trips',
        where: 'deleted = 0', orderBy: 'start_date DESC, id DESC');
    return rows.map(Trip.fromMap).toList();
  }

  Future<String> insertTrip(Trip trip) async {
    final db = await database;
    final id = genUuid();
    await db.insert('trips', {
      'id': id,
      'name': trip.name,
      'start_date': trip.startDate,
      'end_date': trip.endDate,
      'created_at': nowMillis(),
      'updated_at': nowMillis(),
      'deleted': 0,
    });
    return id;
  }

  /// 删除旅程（软删）；流水仍保留 trip_id 引用（显示时忽略已删旅程）
  Future<void> deleteTrip(String id) async {
    final db = await database;
    await db.update('trips', {'deleted': 1, 'updated_at': nowMillis()},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 批量把若干流水归入/移出旅程
  Future<void> setTxnTripBulk(List<String> txnIds, String? tripId) async {
    if (txnIds.isEmpty) return;
    final db = await database;
    final now = nowMillis();
    final batch = db.batch();
    for (final id in txnIds) {
      batch.update('txns', {'trip_id': tripId, 'updated_at': now},
          where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  // ==================== 流水 ====================

  Future<void> insertTxns(List<Txn> txns) async {
    if (txns.isEmpty) return;
    final db = await database;
    final now = nowMillis();
    final batch = db.batch();
    for (final t in txns) {
      batch.insert('txns', {
        'id': t.id ?? genUuid(),
        'date': t.date,
        'description': t.description,
        'amount_cents': t.amountCents,
        'channel': t.channel,
        'source': t.source,
        'category': t.category,
        'account_id': t.accountId,
        'trip_id': t.tripId,
        'created_at': t.createdAt == 0 ? now : t.createdAt,
        'updated_at': now,
        'deleted': 0,
      });
    }
    await batch.commit(noResult: true);
  }

  /// 清空流水（软删全部，可同步传播）
  Future<void> clearTxns() async {
    final db = await database;
    await db.update('txns',
        {'deleted': 1, 'updated_at': nowMillis()},
        where: 'deleted = 0');
  }

  Future<List<Txn>> listTxns({String? start, String? end}) async {
    final db = await database;
    final where = <String>['deleted = 0'];
    final args = <Object?>[];
    if (start != null) {
      where.add('date >= ?');
      args.add(start);
    }
    if (end != null) {
      where.add('date <= ?');
      args.add(end);
    }
    final rows = await db.query('txns',
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: 'date DESC');
    return rows.map(Txn.fromMap).toList();
  }

  Future<int> txnCount() async {
    final db = await database;
    final r = await db.rawQuery(
        'SELECT COUNT(*) c FROM txns WHERE deleted = 0');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// 某账户在 (startExclusive, endInclusive] 日期区间的流水净额（分）
  Future<int> txnNetByAccount(
      String accountId, String startExclusive, String endInclusive) async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(amount_cents), 0) s FROM txns '
      'WHERE account_id = ? AND deleted = 0 AND date > ? AND date <= ?',
      [accountId, startExclusive, endInclusive],
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  Future<void> updateTxn(Txn t) async {
    final db = await database;
    final row = t.toMap()
      ..remove('id')
      ..remove('updated_at')
      ..remove('deleted');
    await db.update('txns', {...row, 'updated_at': nowMillis()},
        where: 'id = ?', whereArgs: [t.id]);
  }

  Future<void> deleteTxn(String id) async {
    final db = await database;
    await db.update('txns', {'deleted': 1, 'updated_at': nowMillis()},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 批量更新流水分类（重新分类用，单事务）
  Future<void> batchSetTxnCategory(Map<String, String> idToCategory) async {
    if (idToCategory.isEmpty) return;
    final db = await database;
    final now = nowMillis();
    final batch = db.batch();
    idToCategory.forEach((id, cat) {
      batch.update('txns', {'category': cat, 'updated_at': now},
          where: 'id = ?', whereArgs: [id]);
    });
    await batch.commit(noResult: true);
  }

  // ==================== 分类规则（本地，不同步） ====================

  Future<List<Map<String, Object?>>> listUserRules() async {
    final db = await database;
    return db.query('category_rules', orderBy: 'priority ASC, id ASC');
  }

  Future<void> addUserRule(String keyword, String category) async {
    final db = await database;
    final exists = await db.query('category_rules',
        where: 'keyword = ?', whereArgs: [keyword]);
    if (exists.isEmpty) {
      final r = await db.rawQuery(
          'SELECT COALESCE(MAX(priority), -1) + 1 p FROM category_rules');
      await db.insert('category_rules', {
        'keyword': keyword,
        'category': category,
        'priority': Sqflite.firstIntValue(r) ?? 0,
      });
    }
  }

  Future<void> deleteUserRule(int id) async {
    final db = await database;
    await db.delete('category_rules', where: 'id = ?', whereArgs: [id]);
  }

  // ==================== 重置 ====================

  /// 清空全部数据（账户等由用户重新手动添加）
  Future<void> resetAllData() async {
    final db = await database;
    await db.transaction((txn) async {
      for (final t in syncTables) {
        await txn.delete(t);
      }
      await txn.delete('category_rules');
      await txn.delete('meta');
    });
  }

  // ==================== 云同步 ====================

  /// 构建推送 payload：5 张业务表全部行（含 deleted tombstone），
  /// 列名与服务器一致（snake_case；不含 user_id，服务器按 URL 填充）。
  Future<Map<String, List<Map<String, Object?>>>> buildSyncPayload() async {
    final db = await database;
    final out = <String, List<Map<String, Object?>>>{};
    for (final table in syncTables) {
      final rows = await db.query(table);
      out[table] = rows.map((r) => Map<String, Object?>.from(r)).toList();
    }
    return out;
  }

  /// 应用服务器返回的合并后全量数据（先物理清空再全量插入）。
  /// 服务器是合并权威（已含本地上传内容），直接替换保证各端一致。
  Future<void> applySyncedData(Map<String, dynamic> data) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final table in syncTables) {
        await txn.delete(table);
        final rows = (data[table] as List?) ?? const [];
        for (final row in rows) {
          final m = Map<String, Object?>.from(row as Map);
          m.remove('user_id'); // 本地表无该列
          await txn.insert(table, m);
        }
      }
    });
  }
}
