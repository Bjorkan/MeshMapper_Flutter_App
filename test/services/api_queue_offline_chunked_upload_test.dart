import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/offline_session_service.dart';

/// `runOfflineChunkedUpload` is the orchestration `app_state_provider.dart`'s
/// offline upload delegates to (review round 1, finding 5: no
/// `AppStateProvider` harness exists in this repo, so the piece that
/// actually carries the bug risk is extracted here and tested directly):
/// strip SCOPES rows the upload auth cannot accept, move every remaining
/// SCOPES row after every other row (DISC before SCOPES), persist that
/// final order BEFORE the first chunk is built, then upload fixed-size
/// chunks in order, stopping at the first one that does not succeed.
///
/// Persisting before chunking is the point (finding 2): the caller's later
/// partial-upload cleanup removes a PREFIX of the STORED rows by uploaded
/// count, and that prefix only lines up with what was actually sent when
/// the file already holds the same order that was chunked. These tests
/// drive a REAL `OfflineSessionService` (SharedPreferences-backed) and
/// re-read it through a FRESH instance, so persistence is proven after a
/// reload, not merely against the instance that wrote it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> row(String type, int seq) => {'type': type, 'seq': seq};

  test(
      'key absent: SCOPES is stripped, the order is persisted before '
      'chunking, the first chunk succeeds and the second fails, the '
      'retained rows are exactly the unsent ones, and none of the failed '
      'chunk is forwarded', () async {
    SharedPreferences.setMockInitialValues({});
    final service = OfflineSessionService();
    await service.init();

    // Stored order: SCOPES first, then its DISC, then two more RX rows.
    final stored = [
      row('SCOPES', 0),
      row('DISC', 1),
      row('RX', 2),
      row('RX', 3),
    ];
    await service.updateCurrentSession(stored, deviceName: 'Test');
    final filename = service.sessions.single.filename;

    final forwarded = <List<Map<String, dynamic>>>[];
    final uploadCalls = <int>[];

    final result = await runOfflineChunkedUpload(
      stored,
      scopeDiscoveryOffered: false, // the key was absent
      batchSize: 2,
      persistRows: (ordered) => service.replacePings(filename, ordered),
      uploadChunk: (chunk, chunkNumber, totalChunks) async {
        uploadCalls.add(chunkNumber);
        if (chunkNumber == 1) {
          forwarded.add(chunk);
          return true;
        }
        return false; // the second chunk fails
      },
    );

    // SCOPES stripped: 3 rows remain, DISC first (nothing to reorder here
    // since there is no SCOPES left, but the shape matters for the next
    // test).
    expect(result.removedScopesCount, 1);
    expect(result.orderedRows, [row('DISC', 1), row('RX', 2), row('RX', 3)]);

    // Chunk 1 = [DISC, RX#2] succeeds; chunk 2 = [RX#3] fails. A would-be
    // chunk 3 (none here) must never be reached.
    expect(uploadCalls, [1, 2]);
    expect(result.uploadedCount, 2);
    expect(forwarded, [
      [row('DISC', 1), row('RX', 2)]
    ], reason: 'only the succeeding chunk is forwarded');

    // Persistence survives a reload: a FRESH service instance (not the one
    // that called persistRows) reads the same SharedPreferences-backed
    // store and sees the stripped, still-chunked-against order, not the
    // original stored rows.
    final reloadedBeforeCleanup = OfflineSessionService();
    await reloadedBeforeCleanup.init();
    final persistedBeforeCleanup = reloadedBeforeCleanup.getSession(filename)!;
    expect(persistedBeforeCleanup.data['pings'], result.orderedRows);

    // Mirrors what app_state_provider.dart does next: prune the uploaded
    // prefix by count. Because the stored order now matches what was
    // chunked, this removes exactly [DISC, RX#2] and retains exactly the
    // one row that was never sent.
    await service.removeProcessedPings(filename, result.uploadedCount);

    final reloadedAfterCleanup = OfflineSessionService();
    await reloadedAfterCleanup.init();
    final retained = reloadedAfterCleanup.getSession(filename)!;
    expect(retained.data['pings'], [row('RX', 3)],
        reason: 'retained rows are exactly the ones not uploaded, matched '
            'against the ordered/stripped list, not the original stored '
            'order');
    expect(retained.pingCount, 1);
  });

  test(
      'key present: no SCOPES is stripped, but an out-of-order SCOPES is '
      'still moved after its DISC and persisted before chunking',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = OfflineSessionService();
    await service.init();

    final stored = [
      row('SCOPES', 0),
      row('DISC', 1),
      row('RX', 2),
    ];
    await service.updateCurrentSession(stored, deviceName: 'Test');
    final filename = service.sessions.single.filename;

    var persistCalls = 0;
    final result = await runOfflineChunkedUpload(
      stored,
      scopeDiscoveryOffered: true, // the key was present
      batchSize: 50,
      persistRows: (ordered) {
        persistCalls++;
        return service.replacePings(filename, ordered);
      },
      uploadChunk: (chunk, chunkNumber, totalChunks) async => true,
    );

    expect(result.removedScopesCount, 0);
    // Nothing was stripped, but the SCOPES row must still land after
    // everything else before it is chunked.
    expect(result.orderedRows, [row('DISC', 1), row('RX', 2), row('SCOPES', 0)]);
    expect(persistCalls, 1);

    final reloaded = OfflineSessionService();
    await reloaded.init();
    expect(reloaded.getSession(filename)!.data['pings'], result.orderedRows);
  });

  test('no SCOPES rows at all: persistRows is never called (nothing to '
      'strip or reorder, the stored order already matches)', () async {
    var persistCalls = 0;
    final stored = [row('TX', 0), row('RX', 1)];

    final result = await runOfflineChunkedUpload(
      stored,
      scopeDiscoveryOffered: false,
      batchSize: 50,
      persistRows: (ordered) async => persistCalls++,
      uploadChunk: (chunk, chunkNumber, totalChunks) async => true,
    );

    expect(persistCalls, 0);
    expect(result.orderedRows, stored);
    expect(result.uploadedCount, 2);
    expect(result.removedScopesCount, 0);
  });
}
