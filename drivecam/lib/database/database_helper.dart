// DatabaseHelper provides a singleton-cached SQLite database for the app.
//
// Only one [Database] instance is created per app run. All model classes
// call [DatabaseHelper().database] to obtain it. The [setDatabaseForTesting]
// seam allows unit tests to inject an in-memory database without touching
// the on-disk 'drivecam.db' file.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'queries.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  /// Returns the cached database, opening and initializing it on first access.
  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  /// Injects [db] as the cached database instance.
  ///
  /// **Only for use in unit tests.** Call this before any code that accesses
  /// [database] so that the singleton never opens the on-disk file. Reset by
  /// passing `null` after the test completes.
  @visibleForTesting
  static void setDatabaseForTesting(Database? db) {
    _database = db;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'drivecam.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute(createRecordingTable);
    await db.execute(createClipsTable);
  }
}
