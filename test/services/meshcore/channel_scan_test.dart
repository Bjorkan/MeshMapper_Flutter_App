import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/channel_service.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/crypto_service.dart';
import 'package:mesh_mapper/services/meshcore/packet_parser.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

import 'fake_companion_transport.dart';

/// One scripted answer to a CMD_GET_CHANNEL read.
sealed class _Answer {
  const _Answer();
}

class _Slot extends _Answer {
  final String name;
  final Uint8List key;
  const _Slot(this.name, this.key);
}

class _Err extends _Answer {
  final int code;
  const _Err(this.code);
}

class _Silent extends _Answer {
  const _Silent();
}

class _WriteFails extends _Answer {
  const _WriteFails();
}

/// A radio whose channel table is [slots]; reads past it answer
/// ERR_CODE_NOT_FOUND, as the firmware does past MAX_GROUP_CHANNELS.
/// [faults] lists, per slot index, answers given before the real one.
class _ChannelRadio extends FakeCompanionTransport {
  final List<_Slot> slots;
  final Map<int, List<_Answer>> faults;

  _ChannelRadio(this.slots, {Map<int, List<_Answer>>? faults})
      : faults = faults ?? {};

  final List<int> reads = [];

  List<Uint8List> get setChannelWrites =>
      writes.where((w) => w.first == CommandCodes.setChannel).toList();

  @override
  Future<void> write(Uint8List data) async {
    if (data.first != CommandCodes.getChannel) {
      await super.write(data);
      return;
    }
    final idx = data[1];
    reads.add(idx);
    final queued = faults[idx];
    final _Answer answer = (queued != null && queued.isNotEmpty)
        ? queued.removeAt(0)
        : idx < slots.length
            ? slots[idx]
            : const _Err(ErrorCodes.notFound);
    if (answer is _WriteFails) {
      throw StateError('GATT write failed');
    }
    await super.write(data);
    switch (answer) {
      case _Slot(:final name, :final key):
        final frame = BufferWriter();
        frame.writeByte(ResponseCodes.channelInfo);
        frame.writeByte(idx);
        frame.writeCString(name, 32);
        frame.writeBytes(key);
        emit(frame.toBytes());
      case _Err(:final code):
        emit([ResponseCodes.err, code]);
      case _Silent():
      case _WriteFails():
        break;
    }
  }
}

void main() {
  final wardrivingKey = CryptoService.deriveChannelKey('#wardriving');
  final emptyKey = Uint8List(16);
  final otherKey = Uint8List.fromList(List<int>.filled(16, 7));

  _Slot named(String name) => _Slot(name, otherKey);
  final empty = _Slot('', emptyKey);
  final wardriving = _Slot('#wardriving', wardrivingKey);

  /// Runs the scan on a fake clock so the 5 s read timeout and the retry
  /// delay cost no wall time.
  ({ChannelInfo? result, Object? error}) scan(_ChannelRadio radio) {
    ChannelInfo? result;
    Object? error;
    fakeAsync((async) {
      final connection = MeshCoreConnection(transport: radio);
      ChannelService.ensureWardrivingChannel(connection).then<void>(
          (value) => result = value,
          onError: (Object e) => error = e);
      async.elapse(const Duration(minutes: 2));
      connection.dispose();
    });
    radio.dispose();
    return (result: result, error: error);
  }

  test('a timeout at slot 3 is retried and the existing channel at 6 is found',
      () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      named('#local'),
      named('#ottawa'),
      named('#test'),
      named('#foo'),
      wardriving,
    ], faults: {
      3: [const _Silent()],
    });
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 6);
    expect(radio.setChannelWrites, isEmpty);
    expect(radio.reads.where((i) => i == 3).length, 2);
  });

  test('a non-2 ERR at slot 3 is retried, then the channel is found', () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      named('#local'),
      named('#ottawa'),
      wardriving,
    ], faults: {
      3: [const _Err(1)],
    });
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 4);
    expect(radio.setChannelWrites, isEmpty);
  });

  test('a write error at a slot is retried like any other failure', () {
    final radio = _ChannelRadio([named('Public'), empty, wardriving],
        faults: {
          2: [const _WriteFails()],
        });
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 2);
    expect(radio.setChannelWrites, isEmpty);
  });

  test('a slot failing twice fails setup and creates nothing', () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      named('#local'),
      named('#ottawa'),
      wardriving,
    ], faults: {
      3: [const _Silent(), const _Err(1)],
    });
    final out = scan(radio);
    expect(out.result, isNull);
    expect(out.error.toString(), contains('Please reconnect'));
    expect(out.error.toString(), isNot(contains('timed out')));
    expect(radio.setChannelWrites, isEmpty);
    expect(radio.reads.where((i) => i > 3), isEmpty);
  });

  test('ERR code 2 at slot 8 with no #wardriving creates in the first empty',
      () {
    final radio = _ChannelRadio([
      named('Public'),
      named('#a'),
      empty,
      named('#b'),
      empty,
      named('#c'),
      named('#d'),
      named('#e'),
    ]);
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 2);
    expect(out.result!.name, '#wardriving');
    expect(radio.reads.last, 8);
    expect(radio.setChannelWrites, hasLength(1));
    final write = radio.setChannelWrites.single;
    expect(write[1], 2);
  });

  test('a differently named channel with the #wardriving key is reused', () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      _Slot('Wardrive', wardrivingKey),
    ]);
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 2);
    expect(out.result!.name, 'Wardrive');
    expect(radio.setChannelWrites, isEmpty);
  });

  test('the typed command error still reads as before in logs', () {
    expect(const CommandErrorException(3).toString(),
        'Exception: Command error (code 3)');
  });
}
