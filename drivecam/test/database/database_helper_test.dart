// Unit tests for `DatabaseHelper` and the database-backed SQL workflow.
//
// These tests use the FFI SQLite backend so they can run in the Linux test
// environment. They verify that the helper creates the expected tables and that
// the SQL constants in `queries.dart` behave correctly when executed.

import 'package:drivecam/database/database_helper.dart';
import 'package:drivecam/database/queries.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Configures sqflite to use the FFI database factory for unit tests.
///
/// This switches the database layer away from a mobile-only platform plugin and
/// into a desktop-friendly SQLite backend.
void initializeDatabaseTestEnvironment() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// Entry point for database helper tests.
void main() {
  late Database db;

  // The test database needs the FFI backend before DatabaseHelper opens it.
  setUpAll(() async {
    initializeDatabaseTestEnvironment();
    db = await DatabaseHelper().database;
  });

  // Clearing rows keeps the tests independent while still reusing the cached
  // database instance that DatabaseHelper provides.
  setUp(() async {
    await db.delete('clips');
    await db.delete('recording');
  });

  // Closing the shared database at the end keeps the test suite tidy.
  tearDownAll(() async {
    await db.close();
  });

  // DatabaseHelper should open one cached database and create the tables.
  test('creates the expected database tables and caches the same instance', () async {
    final helper = DatabaseHelper();
    final cachedDatabase = await helper.database;

    expect(identical(db, cachedDatabase), isTrue);

    final recordingColumns = await db.rawQuery('PRAGMA table_info(recording)');
    expect(
      recordingColumns.map((row) => row['name']).toList(),
      equals(<String>[
        'id',
        'recording_location',
        'recording_length',
        'recording_size',
        'thumbnail_location',
      ]),
    );
    expect(
      recordingColumns.firstWhere((row) => row['name'] == 'recording_location')['notnull'],
      1,
    );
    expect(
      recordingColumns.firstWhere((row) => row['name'] == 'recording_size')['notnull'],
      0,
    );

    final clipColumns = await db.rawQuery('PRAGMA table_info(clips)');
    expect(
      clipColumns.map((row) => row['name']).toList(),
      equals(<String>[
        'id',
        'date_time',
        'date_time_pretty',
        'clip_length',
        'clip_size',
        'trigger_type',
        'is_flagged',
        'clip_location',
        'thumbnail_location',
      ]),
    );
    expect(
      clipColumns.firstWhere((row) => row['name'] == 'is_flagged')['dflt_value'],
      '0',
    );
  });

  // Recording SQL should insert, update, select, and delete the single row the
  // app stores for the current recording session.
  test('supports the full recording CRUD workflow', () async {
    await db.rawInsert(insertRecording, [
      'recording-1',
      '/videos/recording.mp4',
      120,
      null,
      null,
    ]);

    var rows = await db.rawQuery(selectRecording);
    expect(rows, hasLength(1));
    expect(rows.single['id'], 'recording-1');
    expect(rows.single['recording_location'], '/videos/recording.mp4');
    expect(rows.single['recording_length'], 120);
    expect(rows.single['recording_size'], isNull);
    expect(rows.single['thumbnail_location'], isNull);

    await db.rawUpdate(updateRecording, [
      '/videos/recording-updated.mp4',
      240,
      18,
      '/thumbnails/recording.png',
      'recording-1',
    ]);

    rows = await db.rawQuery(selectRecording);
    expect(rows, hasLength(1));
    expect(rows.single['recording_location'], '/videos/recording-updated.mp4');
    expect(rows.single['recording_length'], 240);
    expect(rows.single['recording_size'], 18);
    expect(rows.single['thumbnail_location'], '/thumbnails/recording.png');

    await db.rawDelete(deleteRecording, ['recording-1']);
    rows = await db.rawQuery(selectRecording);
    expect(rows, isEmpty);
  });

  // Clip SQL should preserve ordering, flag updates, and the oldest-clip delete
  // behavior used by the app when storage needs to be reclaimed.
  test('supports clip ordering, flag updates, and oldest-row deletion', () async {
    await db.rawInsert(insertClip, [
      'clip-old',
      '2026-01-01T10:00:00.000Z',
      'Jan 1, 2026 10:00 AM',
      30,
      12,
      'manual',
      0,
      '/clips/old.mp4',
      '/thumbs/old.png',
    ]);
    await db.rawInsert(insertClip, [
      'clip-new',
      '2026-01-02T10:00:00.000Z',
      'Jan 2, 2026 10:00 AM',
      45,
      15,
      'impact',
      0,
      '/clips/new.mp4',
      '/thumbs/new.png',
    ]);

    var rows = await db.rawQuery(selectAllClips);
    expect(rows, hasLength(2));
    expect(rows.first['id'], 'clip-new');
    expect(rows.last['id'], 'clip-old');

    await db.rawUpdate(updateClipFlag, [1, 'clip-old']);
    rows = await db.rawQuery('SELECT id, is_flagged FROM clips WHERE id = ?', ['clip-old']);
    expect(rows.single['is_flagged'], 1);

    await db.rawDelete(deleteOldestClip);
    rows = await db.rawQuery(selectAllClips);
    expect(rows, hasLength(1));
    expect(rows.single['id'], 'clip-new');
  });
}

