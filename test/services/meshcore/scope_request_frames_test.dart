import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/meshcore/scope_lease.dart';

import 'scope_test_support.dart';

/// Byte vectors for the scope request, from examples/companion_radio/MyMesh.cpp
/// (CMD_GET_CONTACT_BY_KEY, CMD_ADD_UPDATE_CONTACT, CMD_SEND_ANON_REQ and
/// writeContactRespFrame).
void main() {
  final key = scopeKey(0xAB);
  final request = Uint8List.fromList([0x01, 0x00]);

  /// Starts a request on a fresh lease; [out] receives the outcome.
  void ask(FakeAsync async, MeshCoreConnection conn,
      void Function(ScopeRequestOutcome) out,
      {Duration? answerWait = const Duration(seconds: 7),
      DateTime? notAfter,
      void Function(Duration)? onSent}) {
    final lease = grant(async, conn)!;
    lease
        .requestScopes(key, request,
            answerWait: answerWait,
            notAfter: notAfter ?? clock.now().add(const Duration(seconds: 30)),
            onSent: onSent)
        .then(out);
    async.flushMicrotasks();
  }

  test('lookup, borrow, send and restore go out byte for byte', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      // A name with invalid UTF-8 and junk after its NUL must survive.
      final raw = rawNameBytes([0x48, 0xFF, 0xC3, 0x69], after: [0x5A, 0x5A]);
      final payload =
          scopeContactPayload(pubkey: key, rawName: raw, lastMod: 0x01020304);
      ScopeRequestOutcome? outcome;
      Duration? sentWait;
      ask(async, conn, (o) => outcome = o, onSent: (w) => sentWait = w);

      expect(radio.writes.last, [CommandCodes.getContactByKey, ...key]);
      radio.emit(contactFrame(payload));
      async.flushMicrotasks();

      // The borrow is the record as read with ONLY out_path_len changed.
      final borrow = radio.writes.last;
      expect(borrow[0], CommandCodes.addUpdateContact);
      expect(borrow.length, 1 + ContactRecord.payloadLength);
      final diffs = [
        for (var i = 0; i < payload.length; i++)
          if (borrow[i + 1] != payload[i]) i
      ];
      expect(diffs, [34], reason: 'only out_path_len (offset 34) may differ');
      expect(borrow[35], 0);

      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(radio.writes.last, [CommandCodes.sendAnonReq, ...key, 0x01, 0x00]);

      radio.emit(sentFrame(est: 1500));
      async.flushMicrotasks();
      expect(sentWait, const Duration(seconds: 7));
      // The restore is the lookup payload, byte for byte.
      expect(radio.writes.last, [CommandCodes.addUpdateContact, ...payload]);
      expect(conn.isScopeLeaseActive, isTrue,
          reason: 'held until the restore OK');

      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(conn.isScopeLeaseActive, isFalse);
      expect(conn.isScopeListenActive, isTrue);

      radio.emit(answerPush(body: [1, 0, 0, 0, 0x41, 0x2C, 0x42]));
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      final answered = outcome! as ScopeAnswered;
      expect(answered.body, [1, 0, 0, 0, 0x41, 0x2C, 0x42]);
      expect(answered.restoreOwed, isFalse);
      expect(answered.borrowedFrom?.publicKey, key);
      expect(conn.isScopeListenActive, isFalse);
      expect(conn.hasPendingAdminCommand, isFalse);
    });
  });

  test('a contact the radio does not know (ERR 2) goes straight to the send',
      () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      expect(radio.commands,
          [CommandCodes.getContactByKey, CommandCodes.sendAnonReq]);
      radio.emit(sentFrame());
      async.flushMicrotasks();
      expect(conn.isScopeLeaseActive, isFalse, reason: 'nothing to restore');
      radio.emit(answerPush());
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      expect(outcome!.borrowedFrom, isNull);
      expect(outcome!.restoreOwed, isFalse);
    });
  });

  test('an already zero-hop contact is not borrowed', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit(contactFrame(
          scopeContactPayload(pubkey: key, outPathLen: 0x80, outPath: [])));
      async.flushMicrotasks();
      expect(radio.commands,
          [CommandCodes.getContactByKey, CommandCodes.sendAnonReq]);
      radio.emit(sentFrame());
      radio.emit(answerPush());
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      expect(outcome!.borrowedFrom, isNull);
    });
  });

  test('a CONTACT for another key is reply_owed, not accepted', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit(contactFrame(scopeContactPayload(pubkey: scopeKey(0x11))));
      async.flushMicrotasks();
      expect(outcome, isA<ScopeLocalFailure>());
      expect((outcome! as ScopeLocalFailure).why, 'reply_owed');
      expect(radio.commands, [CommandCodes.getContactByKey]);
      expect(conn.isScopeLeaseActive, isFalse);
    });
  });

  test('SENT and the answer in the same transport chunk still answer', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      final start = clock.now();
      radio.emit(sentFrame(tag: [7, 7, 7, 7]));
      radio.emit(answerPush(tag: [7, 7, 7, 7], body: [0, 0, 0, 0]));
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      expect((outcome! as ScopeAnswered).receivedAt, start);
    });
  });

  test('an answer for another tag is ignored and the wait ends as no answer',
      () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      radio.emit(sentFrame(tag: [1, 1, 1, 1]));
      radio.emit(answerPush(tag: [2, 2, 2, 2]));
      async.elapse(const Duration(milliseconds: 6999));
      expect(outcome, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(outcome, isA<ScopeNoAnswer>());
      // The tag is cleared: a late answer is ignored.
      radio.emit(answerPush(tag: [1, 1, 1, 1]));
      async.flushMicrotasks();
      expect(conn.isScopeListenActive, isFalse);
    });
  });

  test('a flooded send is ScopeFlooded at once', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      var sentCalled = false;
      ask(async, conn, (o) => outcome = o, onSent: (_) => sentCalled = true);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      radio.emit(sentFrame(flood: true));
      async.flushMicrotasks();
      expect(outcome, isA<ScopeFlooded>());
      expect(sentCalled, isFalse);
      expect(conn.hasPendingAdminCommand, isFalse);
    });
  });

  test('a malformed SENT is malformed_sent and the borrow is restored', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final payload = scopeContactPayload(pubkey: key);
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit(contactFrame(payload));
      async.flushMicrotasks();
      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      radio.emit([ResponseCodes.sent, 0, 1, 2]);
      async.flushMicrotasks();
      expect(radio.writes.last, [CommandCodes.addUpdateContact, ...payload]);
      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(outcome, isA<ScopeLocalFailure>());
      expect((outcome! as ScopeLocalFailure).why, 'malformed_sent');
      expect(outcome!.restoreOwed, isFalse);
    });
  });

  test('a throwing write is write_failed', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final lease = grant(async, conn)!;
      radio.failWrites = true;
      ScopeRequestOutcome? outcome;
      lease
          .requestScopes(key, request,
              answerWait: null,
              notAfter: clock.now().add(const Duration(seconds: 30)))
          .then((o) => outcome = o);
      async.flushMicrotasks();
      expect(outcome, isA<ScopeLocalFailure>());
      expect((outcome! as ScopeLocalFailure).why, 'write_failed');
      expect(lease.active, isFalse);
    });
  });

  test('an ERR other than 2 is ScopeRadioError', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
      async.flushMicrotasks();
      expect(outcome, isA<ScopeRadioError>());
      expect((outcome! as ScopeRadioError).code, ErrorCodes.tableFull);
    });
  });

  group('stray replies during the answer wait', () {
    for (final stray in <String, List<List<int>>>{
      'a TX ERR': [
        [ResponseCodes.err, ErrorCodes.notFound]
      ],
      'a discovery ERR': [
        [ResponseCodes.err, ErrorCodes.tableFull]
      ],
      'a trace SENT': [
        sentFrame(tag: [5, 5, 5, 5])
      ],
      'a config OK and ERR': [
        [ResponseCodes.ok],
        [ResponseCodes.err, ErrorCodes.illegalArg]
      ],
      'poll replies (stats ERR, battery)': [
        [ResponseCodes.err, 1],
        [ResponseCodes.batteryVoltage, 0xA0, 0x0F]
      ],
    }.entries) {
      test('${stray.key} never fails the waiter', () {
        onScopeClock(ScopeRadio.new, (async, radio, conn) {
          ScopeRequestOutcome? outcome;
          ask(async, conn, (o) => outcome = o);
          radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
          async.flushMicrotasks();
          radio.emit(sentFrame());
          async.flushMicrotasks();
          expect(conn.isScopeListenActive, isTrue);
          for (final frame in stray.value) {
            radio.emit(frame);
          }
          async.elapse(const Duration(seconds: 1));
          expect(outcome, isNull);
          expect(conn.isScopeListenActive, isTrue);
          radio.emit(answerPush());
          async.flushMicrotasks();
          expect(outcome, isA<ScopeAnswered>());
        });
      });
    }
  });
}
