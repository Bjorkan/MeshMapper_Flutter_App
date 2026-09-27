import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/models/api_queue_item.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// SCOPES is a repeater's answer to a direct scope discovery question, sent
/// only after a discovery found it. It is modelled on DEFER (the public key
/// rides in the heardRepeats slot, the scopes list gets its own field), but
/// unlike DEFER it depends on another queued item: the server refuses a
/// SCOPES whose DISC only arrives in a LATER batch or chunk, so the queue
/// must never upload one ahead of the DISC it depends on.
void main() {
  ApiQueueService newQueue() => ApiQueueService(apiService: ApiService());

  const key1 = 'A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2';
  const key2 = 'B4C3D2E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3';

  Future<void> enqueueDisc(ApiQueueService queue,
          {String pubkeyFull = key1, int timestamp = 1757400000}) =>
      queue.enqueueDisc(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: pubkeyFull.substring(0, 2),
        nodeType: 'REPEATER',
        localSnr: 10.5,
        localRssi: -88,
        remoteSnr: 8.25,
        pubkeyFull: pubkeyFull,
        timestamp: timestamp,
        externalAntenna: false,
      );

  group('ApiQueueItem.fromScopes JSON shape', () {
    test('carries public_key, scopes, timestamp, lat and lon', () {
      final item = ApiQueueItem.fromScopes(
        publicKeyHex: key1,
        scopes: ['ROOM1', '*'],
        lat: 45.26974,
        lon: -75.77746,
        timestamp: 1757400000,
      );
      expect(item.toApiJson(), {
        'type': 'SCOPES',
        'public_key': key1,
        'scopes': ['ROOM1', '*'],
        'timestamp': 1757400000,
        'lat': 45.26974,
        'lon': -75.77746,
      });
    });

    test('an empty scopes list is kept as an empty array', () {
      final item = ApiQueueItem.fromScopes(
        publicKeyHex: key1,
        scopes: const [],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
      );
      expect(item.toApiJson()['scopes'], <String>[]);
    });

    test('33 names, case and the * wildcard are kept exactly as given', () {
      final names = [
        for (var i = 0; i < 32; i++) 'name$i',
        '*',
      ];
      final item = ApiQueueItem.fromScopes(
        publicKeyHex: key1,
        scopes: names,
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
      );
      final scopes = item.toApiJson()['scopes'] as List;
      expect(scopes, hasLength(33));
      expect(scopes.last, '*');
      expect(scopes, names,
          reason: 'case and punctuation are passed through unchanged');
    });

    test('radio_freq rides along when set, never auto_mode', () {
      final item = ApiQueueItem.fromScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
        radioFreq: '910.525,62.5,7,5',
      );
      final json = item.toApiJson();
      expect(json['radio_freq'], '910.525,62.5,7,5');
      expect(json.containsKey('auto_mode'), isFalse);
    });

    test('timestamp is always an integer number of seconds', () {
      final item = ApiQueueItem.fromScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
      );
      expect(item.toApiJson()['timestamp'], isA<int>());
      expect(item.toApiJson()['timestamp'], 1757400000);
    });

    test('the public key is normalized to 64 upper-case hex', () {
      final item = ApiQueueItem.fromScopes(
        publicKeyHex: key1.toLowerCase(),
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
      );
      expect(item.toApiJson()['public_key'], key1);
    });
  });

  group('enqueueScopes', () {
    test('returns true and lands in the memory fallback with no init()',
        () async {
      final queue = newQueue();
      var updates = 0;
      queue.onQueueUpdated = (_) => updates++;

      final ok = await queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.26974,
        lon: -75.77746,
        timestamp: 1757400000,
        expectedGeneration: queue.generation,
      );

      expect(ok, isTrue);
      expect(queue.queueSize, 1);
      expect(updates, 1);
      final json = await queue.extractAllAsJson();
      expect(json.single['type'], 'SCOPES');
      expect(json.single['public_key'], key1);
    });

    test('false for non-finite lat/lon, nothing queued', () async {
      final queue = newQueue();
      final ok = await queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: double.nan,
        lon: -75.0,
        timestamp: 1757400000,
        expectedGeneration: queue.generation,
      );
      expect(ok, isFalse);
      expect(queue.queueSize, 0);
    });

    test('false on a generation mismatch, nothing queued', () async {
      final queue = newQueue();
      final staleGeneration = queue.generation;
      await queue.clearOnDisconnect(); // bumps generation

      final ok = await queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
        expectedGeneration: staleGeneration,
      );
      expect(ok, isFalse);
      expect(queue.queueSize, 0);
    });

    test('false for an invalid public key, nothing queued: the server '
        'rejects the whole item otherwise', () async {
      final queue = newQueue();
      final ok = await queue.enqueueScopes(
        publicKeyHex: 'not-a-key',
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
        expectedGeneration: queue.generation,
      );
      expect(ok, isFalse);
      expect(queue.queueSize, 0);
    });

    test('a lower-case key is normalized and still accepted', () async {
      final queue = newQueue();
      final ok = await queue.enqueueScopes(
        publicKeyHex: key1.toLowerCase(),
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
        expectedGeneration: queue.generation,
      );
      expect(ok, isTrue);
      final json = await queue.extractAllAsJson();
      expect(json.single['public_key'], key1);
    });

    test('an explicit radioFreq is used over the getter, and the getter is '
        'the fallback when none is given', () async {
      final queue = newQueue();
      queue.radioConfigGetter = () => '910.525,62.5,7,5';

      await queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
        expectedGeneration: queue.generation,
        radioFreq: '906.875,250,10,5',
      );
      await queue.enqueueScopes(
        publicKeyHex: key2,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400001,
        expectedGeneration: queue.generation,
      );

      final json = await queue.extractAllAsJson();
      expect(json[0]['radio_freq'], '906.875,250,10,5',
          reason: 'the explicit value Task 6 passes wins');
      expect(json[1]['radio_freq'], '910.525,62.5,7,5',
          reason: 'no explicit value falls back to the live radio getter, '
              'the same as every other item type');
    });

    test('a disconnect racing the pending Hive write inserts nothing',
        () async {
      final dir = await Directory.systemTemp.createTemp('mm_scopes_');
      Hive.init(dir.path);
      try {
        final queue = newQueue();
        await queue.init();
        final gen = queue.generation;

        // Started but not yet awaited: this runs synchronously up to its
        // internal `await box.add(item)` and then suspends.
        final enqueueFuture = queue.enqueueScopes(
          publicKeyHex: key1,
          scopes: ['*'],
          lat: 45.0,
          lon: -75.0,
          timestamp: 1757400000,
          expectedGeneration: gen,
        );

        // clearOnDisconnect() bumps the generation synchronously, before its
        // own first internal await, so this is guaranteed to happen before
        // the pending write above is checked against it.
        await queue.clearOnDisconnect();

        final result = await enqueueFuture;
        expect(result, isFalse);
        expect(queue.queueSize, 0);
      } finally {
        await Hive.close();
        await dir.delete(recursive: true);
      }
    });

    test('a normal Hive write succeeds and is not a memory fallback',
        () async {
      final dir = await Directory.systemTemp.createTemp('mm_scopes_');
      Hive.init(dir.path);
      try {
        final queue = newQueue();
        await queue.init();

        final ok = await queue.enqueueScopes(
          publicKeyHex: key1,
          scopes: ['*'],
          lat: 45.0,
          lon: -75.0,
          timestamp: 1757400000,
          expectedGeneration: queue.generation,
        );

        expect(ok, isTrue);
        expect(queue.queueSize, 1);
        // Prove it is really in Hive, not the memory fallback: reopen the
        // box directly (the service's own box is still the open instance,
        // so this reads it, not a different one).
        final reopened = await Hive.openBox<ApiQueueItem>('api_queue');
        expect(reopened.length, 1);
        expect(reopened.getAt(0)!.type, 'SCOPES');
      } finally {
        await Hive.close();
        await dir.delete(recursive: true);
      }
    });

    test(
        'a failed Hive write recovers (deletes and reopens the box) and '
        'the retry lands in the fresh box', () async {
      final dir = await Directory.systemTemp.createTemp('mm_scopes_');
      Hive.init(dir.path);
      try {
        final queue = newQueue();
        await queue.init();

        // Close the box out from under the service without clearing its
        // `_box` reference (queue.testBox stays pointed at the now-closed
        // instance): the next write on it throws exactly like a corrupted
        // box would in production, which is what drives `_recoverBox()`.
        await queue.testBox!.close();

        final ok = await queue.enqueueScopes(
          publicKeyHex: key1,
          scopes: ['*'],
          lat: 45.0,
          lon: -75.0,
          timestamp: 1757400000,
          expectedGeneration: queue.generation,
        );

        expect(ok, isTrue);
        expect(queue.queueSize, 1);
        // The recovered box is fresh (deleted from disk and reopened), and
        // the retry-write landed in it, not in memory.
        final reopened = await Hive.openBox<ApiQueueItem>('api_queue');
        expect(reopened.length, 1);
        expect(reopened.getAt(0)!.type, 'SCOPES');
      } finally {
        await Hive.close();
        await dir.delete(recursive: true);
      }
    });

    test(
        'Hive unavailable (the box could not be reached at all) falls back '
        'to memory', () async {
      final queue = newQueue();
      // No init(): `_box` is null from the start, the same end state a
      // write-then-recovery failure reaches (both leave `_box` null before
      // the write attempt below), so both take the identical fallback
      // line. Explicitly nulling `testBox` here isolates that shared
      // fallback from the recovery machinery covered by the test above.
      queue.testBox = null;

      final ok = await queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400000,
        expectedGeneration: queue.generation,
      );

      expect(ok, isTrue);
      expect(queue.queueSize, 1);
      final json = await queue.extractAllAsJson();
      expect(json.single['type'], 'SCOPES');
    });

    group('offline mode', () {
      ApiQueueService offlineQueue() => newQueue()..offlineMode = true;

      test('lands in the offline payload', () async {
        final queue = offlineQueue();
        final ok = await queue.enqueueScopes(
          publicKeyHex: key1,
          scopes: ['*'],
          lat: 45.0,
          lon: -75.0,
          timestamp: 1757400000,
          expectedGeneration: queue.generation,
        );
        expect(ok, isTrue);
        expect(queue.offlinePingCount, 1);
        expect(queue.queueSize, 0);
      });

      test('the airborne pause drops it like any other offline row',
          () async {
        final queue = offlineQueue();
        queue.setOfflineRecordingPaused(true);
        final ok = await queue.enqueueScopes(
          publicKeyHex: key1,
          scopes: ['*'],
          lat: 45.0,
          lon: -75.0,
          timestamp: 1757400000,
          expectedGeneration: queue.generation,
        );
        expect(ok, isFalse);
        expect(queue.offlinePingCount, 0);
      });
    });
  });

  test('extractAllAsJson keeps SCOPES untagged', () async {
    final queue = newQueue();
    await queue.enqueueScopes(
      publicKeyHex: key1,
      scopes: ['*'],
      lat: 45.0,
      lon: -75.0,
      timestamp: 1757400000,
      expectedGeneration: queue.generation,
    );
    final json = await queue.extractAllAsJson();
    expect(json.single['type'], 'SCOPES');
    expect(json.single.containsKey('wire_tag'), isFalse);
  });

  test('withoutScopesItems leaves every other type in order', () {
    final rows = [
      {'type': 'TX'},
      {'type': 'SCOPES'},
      {'type': 'RX'},
      {'type': 'SCOPES'},
      {'type': 'DISC'},
      {'type': 'DEFER'},
    ];
    expect(withoutScopesItems(rows).map((r) => r['type']),
        ['TX', 'RX', 'DISC', 'DEFER']);
  });

  test('orderDiscBeforeScopes is a stable partition, storage order does not '
      'matter (an export that stored a SCOPES in Hive ahead of a memory '
      'DISC must still put the DISC first)', () {
    final rows = [
      {'type': 'SCOPES', 'public_key': key1},
      {'type': 'RX'},
      {'type': 'DISC', 'repeater_id': 'a3'},
      {'type': 'SCOPES', 'public_key': key2},
    ];
    expect(orderDiscBeforeScopes(rows).map((r) => r['type']),
        ['RX', 'DISC', 'SCOPES', 'SCOPES']);
  });

  test(
      'extractAllAsJson puts DISC before SCOPES even when SCOPES was queued '
      'first (proves the reorder, not just insertion order)', () async {
    final queue = newQueue();
    // Enqueued in the "wrong" order: without the reorder this would come
    // back SCOPES-then-DISC, and a chunk boundary right after the SCOPES row
    // would upload it a whole chunk ahead of the DISC it depends on.
    await queue.enqueueScopes(
      publicKeyHex: key1,
      scopes: ['*'],
      lat: 45.0,
      lon: -75.0,
      timestamp: 1757400001,
      expectedGeneration: queue.generation,
    );
    await enqueueDisc(queue, pubkeyFull: key1, timestamp: 1757400000);

    final json = await queue.extractAllAsJson();
    expect(json.map((j) => j['type']), ['DISC', 'SCOPES']);
  });

  group('selectBatchWithScopesDependency', () {
    ApiQueueItem disc(String key, {int retryCount = 0}) => ApiQueueItem(
          type: 'DISC',
          latitude: 45.0,
          longitude: -75.0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1757400000000),
          heardRepeats: 'a3:REPEATER:10.50:-88:8.25:$key',
          canUploadAfter: 0,
          externalAntenna: false,
          retryCount: retryCount,
        );

    ApiQueueItem scopes(String key) => ApiQueueItem(
          type: 'SCOPES',
          latitude: 45.0,
          longitude: -75.0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1757400000000),
          heardRepeats: key,
          canUploadAfter: 0,
          externalAntenna: false,
          scopes: const ['*'],
        );

    ApiQueueItem rx() => ApiQueueItem(
          type: 'RX',
          latitude: 45.0,
          longitude: -75.0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1757400000000),
          heardRepeats: '4e(12.0)',
          canUploadAfter: 0,
          externalAntenna: false,
        );

    test('a SCOPES rides along when its DISC is in the same batch', () {
      final d = disc(key1);
      final s = scopes(key1);
      final selected = selectBatchWithScopesDependency(
        eligible: [d, s],
        allQueued: [d, s],
        batchSize: 50,
      );
      expect(selected, [d, s]);
    });

    test('a SCOPES is released when no DISC for its key remains anywhere '
        '(its DISC already went out in an earlier batch)', () {
      final s = scopes(key1);
      final selected = selectBatchWithScopesDependency(
        eligible: [s],
        allQueued: [s], // the matching DISC is gone from the queue entirely
        batchSize: 50,
      );
      expect(selected, [s]);
    });

    test('a DISC in retry backoff holds back its SCOPES', () {
      // The SCOPES' own DISC (key1) is only reachable through allQueued,
      // still climbing the retry ladder (not eligible for this batch). An
      // unrelated, eligible DISC (key2) fills the batch instead.
      final backedOffTwin = disc(key1, retryCount: 1);
      final s = scopes(key1);
      final otherDisc = disc(key2);
      final selected = selectBatchWithScopesDependency(
        eligible: [otherDisc, s],
        allQueued: [otherDisc, s, backedOffTwin],
        batchSize: 50,
      );
      expect(selected, [otherDisc],
          reason: 'the SCOPES cannot go out: its DISC is still queued '
              '(in backoff) and is not in this batch');
    });

    test('a run of 50 blocked SCOPES never crowds out the DISC items behind '
        'them', () {
      final blockedScopes =
          List.generate(50, (i) => scopes('C' * 63 + i.toString()));
      final theirDiscs =
          blockedScopes.map((s) => disc(s.heardRepeats, retryCount: 1)).toList();
      final laterDisc = disc(key2);
      final eligible = [...blockedScopes, laterDisc];
      final allQueued = [...blockedScopes, ...theirDiscs, laterDisc];

      final selected = selectBatchWithScopesDependency(
        eligible: eligible,
        allQueued: allQueued,
        batchSize: 50,
      );

      expect(selected, [laterDisc],
          reason: 'every blocked SCOPES is held back, so the DISC behind '
              'them still fills the batch instead of losing its slot');
    });

    test('storage origin does not matter to the rule: a mix of items that '
        'would come from Hive and from the memory fallback is treated the '
        'same', () {
      final hiveStyleDisc = disc(key1);
      final memoryStyleScopes = scopes(key1);
      final selected = selectBatchWithScopesDependency(
        eligible: [hiveStyleDisc, memoryStyleScopes],
        allQueued: [hiveStyleDisc, memoryStyleScopes],
        batchSize: 50,
      );
      expect(selected, [hiveStyleDisc, memoryStyleScopes]);
    });

    test('DISC and other non-SCOPES items are always selected regardless of '
        'any SCOPES dependency', () {
      final d = disc(key1);
      final r = rx();
      final selected = selectBatchWithScopesDependency(
        eligible: [d, r],
        allQueued: [d, r],
        batchSize: 50,
      );
      expect(selected, [d, r]);
    });
  });

  group('the batch builder and the scope discovery upload door', () {
    Future<({ApiQueueService queue, List<List<Map<String, dynamic>>> posted})>
        build({
      required List<UploadOutcome> outcomes,
    }) async {
      final posted = <List<Map<String, dynamic>>>[];
      var call = 0;
      final api = ApiService(client: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          return http.Response(
            json.encode({
              'success': true,
              'session_id': 'YOW-20260926-0001',
              'tx_allowed': true,
              'rx_allowed': true,
            }),
            200,
          );
        }
        final body = json.decode(request.body) as Map<String, dynamic>;
        final data = (body['data'] as List).cast<Map<String, dynamic>>();
        posted.add(data);
        final outcome = outcomes[call.clamp(0, outcomes.length - 1)];
        call++;
        if (outcome == UploadOutcome.retryable) {
          return http.Response(json.encode({'success': false}), 200);
        }
        return http.Response(json.encode({'success': true}), 200);
      }));
      await api.requestAuth(
        reason: 'connect',
        publicKey: 'AB' * 32,
        lat: 45.0,
        lon: -75.0,
        accuracyMeters: 5,
      );
      final queue = ApiQueueService(apiService: api);
      return (queue: queue, posted: posted);
    }

    test('drops SCOPES when the key is absent, keeps DISC either way',
        () async {
      final t = await build(outcomes: [UploadOutcome.success]);
      t.queue.scopesAllowedGetter = () => false;
      await enqueueDisc(t.queue, pubkeyFull: key1);
      await t.queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400001,
        expectedGeneration: t.queue.generation,
      );

      await t.queue.flushQueue();

      expect(t.posted.single.map((p) => p['type']), ['DISC']);
      expect(t.queue.queueSize, 0);
    });

    test('keeps SCOPES when the key is present and false (not enforced)',
        () async {
      final t = await build(outcomes: [UploadOutcome.success]);
      t.queue.scopesAllowedGetter = () => true;
      await enqueueDisc(t.queue, pubkeyFull: key1);
      await t.queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400001,
        expectedGeneration: t.queue.generation,
      );

      await t.queue.flushQueue();

      expect(t.posted.single.map((p) => p['type']).toSet(), {'DISC', 'SCOPES'});
    });

    test('a batch that fails and retries re-sends its SCOPES with its DISC, '
        'nothing duplicated', () async {
      final t = await build(outcomes: [UploadOutcome.retryable, UploadOutcome.success]);
      t.queue.scopesAllowedGetter = () => true;
      await enqueueDisc(t.queue, pubkeyFull: key1);
      await t.queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400001,
        expectedGeneration: t.queue.generation,
      );

      await t.queue.flushQueue(); // fails, both items marked for retry
      // Reset the backoff so the second attempt is immediately eligible.
      for (final item in t.queue.heldItems) {
        item.retryCount = 0;
        item.lastRetryAt = null;
      }
      await t.queue.flushQueue(); // succeeds

      expect(t.posted, hasLength(2));
      expect(t.posted[0].map((p) => p['type']).toSet(), {'DISC', 'SCOPES'});
      expect(t.posted[1].map((p) => p['type']).toSet(), {'DISC', 'SCOPES'});
      expect(t.queue.queueSize, 0);
    });

    test('an item dropped at the upload door is never forwarded', () async {
      // CustomApiService.forwardPings is called with the exact `pings` list
      // that goes to MeshMapper (`api_queue_service.dart`'s
      // `customApiService?.forwardPings(pings)`), so proving a dropped
      // SCOPES never reaches that list (asserted on `posted`, the actual
      // MeshMapper upload body) proves it is never forwarded either.
      final t = await build(outcomes: [UploadOutcome.success]);
      t.queue.scopesAllowedGetter = () => false;
      await enqueueDisc(t.queue, pubkeyFull: key1);
      await t.queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400001,
        expectedGeneration: t.queue.generation,
      );

      await t.queue.flushQueue();

      expect(t.posted.single.any((p) => p['type'] == 'SCOPES'), isFalse);
    });

    test(
        'a SCOPES item that survives the drop attempt is still excluded '
        'from the batch and never forwarded: exclusion cannot depend on '
        'the drop having succeeded', () async {
      final t = await build(outcomes: [UploadOutcome.success]);
      await enqueueDisc(t.queue, pubkeyFull: key1);
      await t.queue.enqueueScopes(
        publicKeyHex: key1,
        scopes: ['*'],
        lat: 45.0,
        lon: -75.0,
        timestamp: 1757400001,
        expectedGeneration: t.queue.generation,
      );

      // The drop pass (`_dropDisallowedScopesItems`, the FIRST call) sees
      // the feature as allowed and removes nothing, standing in for a Hive
      // deletion that was attempted and failed (logged, otherwise
      // harmless): either way, the SCOPES item is still sitting in storage
      // when selection runs. Every LATER call (the batch-selection filter)
      // sees it as disallowed, so the exclusion there must not depend on
      // the drop pass having actually removed anything.
      var calls = 0;
      t.queue.scopesAllowedGetter = () {
        calls++;
        return calls > 1 ? false : true;
      };

      await t.queue.flushQueue();

      expect(calls, greaterThan(1));
      expect(t.posted.single.map((p) => p['type']), ['DISC']);
    });

    test('overlapping flushes upload the queued items only once', () async {
      final t = await build(outcomes: [UploadOutcome.success]);
      await enqueueDisc(t.queue, pubkeyFull: key1);

      // Neither is awaited before the other starts: both calls run
      // synchronously up to their own first internal await, exactly the
      // window the batch timer and the ping flush timer can both land in.
      final first = t.queue.flushQueue();
      final second = t.queue.flushQueue();
      await Future.wait([first, second]);

      expect(t.posted, hasLength(1),
          reason: 'the guard must already be claimed by the time the '
              'second flush checks it, or the same DISC item is selected, '
              'uploaded and forwarded twice');
      expect(t.posted.single, hasLength(1));
    });

    test(
        'a real mix of one Hive item and one memory-fallback item uploads '
        'DISC before SCOPES through the queue itself', () async {
      final dir = await Directory.systemTemp.createTemp('mm_scopes_mixed_');
      Hive.init(dir.path);
      try {
        final t = await build(outcomes: [UploadOutcome.success]);
        await t.queue.init(); // now Hive-backed, same temp dir
        t.queue.scopesAllowedGetter = () => true;

        await enqueueDisc(t.queue, pubkeyFull: key1); // real Hive write

        // Force exactly the next write to memory without touching the
        // already-committed Hive item: nulling `_box` (not closing or
        // deleting it) skips straight to the memory-fallback branch.
        final realBox = t.queue.testBox;
        t.queue.testBox = null;
        await t.queue.enqueueScopes(
          publicKeyHex: key1,
          scopes: ['*'],
          lat: 45.0,
          lon: -75.0,
          timestamp: 1757400001,
          expectedGeneration: t.queue.generation,
        );
        t.queue.testBox = realBox;

        // Both items are now genuinely visible: the DISC via the real
        // (still open) Hive box, the SCOPES via the memory queue.
        expect(t.queue.heldItems.map((i) => i.type).toSet(), {'DISC', 'SCOPES'});
        expect(t.queue.heldItems.where((i) => i.isInBox).single.type, 'DISC');
        expect(t.queue.heldItems.where((i) => !i.isInBox).single.type, 'SCOPES');

        await t.queue.flushQueue();

        expect(t.posted.single.map((p) => p['type']).toSet(), {'DISC', 'SCOPES'});
      } finally {
        await Hive.close();
        await dir.delete(recursive: true);
      }
    });

    test(
        'a real mix of one Hive item and one memory-fallback item exports '
        'DISC before SCOPES through the queue itself', () async {
      final dir = await Directory.systemTemp.createTemp('mm_scopes_mixed2_');
      Hive.init(dir.path);
      try {
        final queue = newQueue();
        await queue.init();

        // Enqueue the SCOPES row FIRST but keep it in Hive too (both
        // items real Hive rows initially), forcing the second one (DISC)
        // to memory instead, so raw storage order alone (Hive-then-memory
        // concatenation) would put SCOPES first without the reorder.
        await queue.enqueueScopes(
          publicKeyHex: key1,
          scopes: ['*'],
          lat: 45.0,
          lon: -75.0,
          timestamp: 1757400001,
          expectedGeneration: queue.generation,
        );

        final realBox = queue.testBox;
        queue.testBox = null;
        await enqueueDisc(queue, pubkeyFull: key1, timestamp: 1757400000);
        queue.testBox = realBox;

        expect(queue.heldItems.where((i) => i.isInBox).single.type, 'SCOPES');
        expect(queue.heldItems.where((i) => !i.isInBox).single.type, 'DISC');

        final json = await queue.extractAllAsJson();
        expect(json.map((j) => j['type']), ['DISC', 'SCOPES']);
      } finally {
        await Hive.close();
        await dir.delete(recursive: true);
      }
    });
  });
}

enum UploadOutcome { success, retryable }
