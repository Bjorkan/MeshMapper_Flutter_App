import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

import 'fake_companion_transport.dart';

/// The companion firmware answers CMD_SEND_CHANNEL_TXT_MSG and
/// CMD_SEND_CONTROL_DATA (discovery) with a bare OK or ERR, never with
/// RESP_CODE_SENT (examples/companion_radio/MyMesh.cpp). A TX send therefore
/// has to wait for its own OK, and both sends have to claim their reply so it
/// cannot complete some other command's OK waiter.
void main() {
  late FakeCompanionTransport transport;
  late MeshCoreConnection connection;

  setUp(() {
    transport = FakeCompanionTransport();
    connection = MeshCoreConnection(transport: transport);
  });

  tearDown(() {
    connection.dispose();
    transport.dispose();
  });

  Uint8List key(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

  ContactRecord contact() => ContactRecord.newRepeater(
      publicKey: key(9), name: 'R', lat: 1, lon: 2, nowSecs: 5);

  Future<void> sendTx() => connection.sendChannelTextMessage(0, 1, 0, 'MM:x');

  /// Resolves true once [future] completes, false while it is still pending.
  Future<bool> isDone(Future<void> future) async {
    var done = false;
    unawaited(future.then((_) => done = true, onError: (_) => done = true));
    await transport.settle();
    await transport.settle();
    return done;
  }

  List<String> captureLog() {
    final lines = <String>[];
    final originalDebugPrint = debugPrint;
    final originalEnabled = DebugLogger.isEnabled;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    DebugLogger.setEnabled(true);
    addTearDown(() {
      debugPrint = originalDebugPrint;
      DebugLogger.setEnabled(originalEnabled);
    });
    return lines;
  }

  test('a TX returns as soon as its own OK arrives, not after 3 s', () async {
    final lines = captureLog();
    final watch = Stopwatch()..start();
    final future = sendTx();
    await transport.settle();
    expect(transport.commandAt(0), CommandCodes.sendChannelTxtMsg);
    Timer(const Duration(milliseconds: 5),
        () => transport.emit([ResponseCodes.ok]));
    await future;
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(500));
    expect(lines.any((l) => l.contains('[CONN] OK claimed by TX send')),
        isTrue);
  });

  test('a TX ERR returns at once and is logged as a warning', () async {
    final lines = captureLog();
    final watch = Stopwatch()..start();
    final future = sendTx();
    await transport.settle();
    transport.emit([ResponseCodes.err, ErrorCodes.notFound]);
    await future;
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(500));
    expect(
        lines.any((l) =>
            l.contains('[CONN]') &&
            l.contains('TX send rejected by radio') &&
            l.contains('error code ${ErrorCodes.notFound}')),
        isTrue);
  });

  test('a TX with no reply returns after 3 s and releases its claim',
      () async {
    final watch = Stopwatch()..start();
    await sendTx();
    watch.stop();
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(2900));

    // The expired claim must not swallow the next command's OK.
    final add = connection.addContact(contact());
    await transport.settle();
    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('a TX OK goes to the TX and the admin OK to the admin', () async {
    final tx = sendTx();
    await transport.settle();
    final add = connection.addContact(contact());
    await transport.settle();
    expect(transport.commandAt(1), CommandCodes.addUpdateContact);

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(tx), isTrue);
    expect(await isDone(add), isFalse);

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  });

  test('a discovery OK never completes an admin waiter', () async {
    await connection.sendDiscoveryRequest();
    final add = connection.addContact(contact());
    await transport.settle();

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isFalse);

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  });

  test('a discovery ERR never fails an admin waiter', () async {
    await connection.sendDiscoveryRequest();
    final add = connection.addContact(contact());
    await transport.settle();

    transport.emit([ResponseCodes.err, ErrorCodes.tableFull]);
    expect(await isDone(add), isFalse);

    transport.emit([ResponseCodes.ok]);
    await add;
  });

  test('a discovery OK never completes a sign chunk', () async {
    await connection.sendDiscoveryRequest();
    final sign = connection
        .sign(Uint8List.fromList(List<int>.generate(32, (i) => i + 1)));
    await transport.settle();

    // The radio answers in command order: the discovery OK first.
    transport.emit([ResponseCodes.ok]);
    transport.emit([ResponseCodes.signStart, 0, 128, 0, 0, 0]);
    await transport.settle();
    expect(transport.commandAt(2), CommandCodes.signData);

    // The chunk is still waiting for its own OK.
    await transport.settle();
    expect(transport.writes.length, 3);

    transport.emit([ResponseCodes.ok]);
    await transport.settle();
    expect(transport.commandAt(3), CommandCodes.signFinish);
    transport.emit([ResponseCodes.signature, ...List<int>.filled(64, 0xAB)]);
    expect((await sign).length, 64);
  });

  test('replies are claimed oldest first across TX and discovery', () async {
    final lines = captureLog();
    await connection.sendDiscoveryRequest();
    final tx = sendTx();
    await transport.settle();

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(tx), isFalse);

    transport.emit([ResponseCodes.err, ErrorCodes.notFound]);
    expect(await isDone(tx), isTrue);
    expect(lines.any((l) => l.contains('TX send rejected by radio')), isTrue);
  });

  test('an unanswered discovery claim expires and stops claiming', () async {
    connection.ownReplyTimeout = const Duration(milliseconds: 20);
    await connection.sendDiscoveryRequest();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final add = connection.addContact(contact());
    await transport.settle();
    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  });

  test('a failed TX write leaves no claim behind', () async {
    transport.failWrites = true;
    await expectLater(sendTx(), throwsA(isA<StateError>()));
    transport.failWrites = false;

    final add = connection.addContact(contact());
    await transport.settle();
    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  });

  test('dispose releases a TX still waiting for its reply', () async {
    final tx = sendTx();
    await transport.settle();
    connection.dispose();
    expect(await isDone(tx), isTrue);
  });
}
