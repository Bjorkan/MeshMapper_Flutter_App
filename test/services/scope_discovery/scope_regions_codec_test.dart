import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_regions_codec.dart';

Uint8List reply(String names) => Uint8List.fromList(
    [0x10, 0x20, 0x30, 0x40, ...utf8.encode(names)]); // 4-byte repeater clock first

void main() {
  test('request is regions type with a zero-hop reply path', () {
    expect(buildRegionsRequest(), [0x01, 0x00]);
  });
  test('names keep case and order, * kept', () {
    expect(parseRegionsReply(reply('*,YOW,on')), ['*', 'YOW', 'on']);
  });
  test('clock only is a valid empty answer', () {
    expect(parseRegionsReply(reply('')), <String>[]);
  });
  test('shorter than the clock is no answer', () {
    expect(parseRegionsReply(Uint8List.fromList([1, 2, 3])), isNull);
  });
  test('a space fails the token rule, so the reply is malformed', () {
    expect(parseRegionsReply(reply('a, b')), isNull);
  });
  test('token rule: 30 bytes ok, 31 malformed', () {
    expect(parseRegionsReply(reply('A' * 30)), ['A' * 30]);
    expect(parseRegionsReply(reply('A' * 31)), isNull);
  });
  test('token rule: leading # malformed, inner # ok', () {
    expect(parseRegionsReply(reply('#yow')), isNull);
    expect(parseRegionsReply(reply('y#w')), ['y#w']);
  });
  test('token rule: * only valid alone', () {
    expect(parseRegionsReply(reply('*')), ['*']);
    expect(parseRegionsReply(reply('*PAH')), isNull);
  });
  test('token rule: - \$ digits and bytes >= A are valid', () {
    expect(parseRegionsReply(reply('ILM-MM,a\$1,Zürich')), ['ILM-MM', 'a\$1', 'Zürich']);
    expect(parseRegionsReply(reply('a.b')), isNull);
  });
  test('empty segment is malformed', () {
    expect(parseRegionsReply(reply('a,,b')), isNull);
    expect(parseRegionsReply(reply('a,')), isNull);
    expect(parseRegionsReply(reply(',a')), isNull);
  });
  test('any NUL is malformed', () {
    expect(parseRegionsReply(reply('a,b\u0000')), isNull);
  });
  test('invalid UTF-8 is malformed, never throws', () {
    final d = Uint8List.fromList([0, 0, 0, 0, 0x61, 0xFF, 0x2C, 0x62]);
    expect(parseRegionsReply(d), isNull);
  });
  test('33 names is fine, 34 is malformed', () {
    String n(int c) => List.generate(c, (i) => 'r$i').join(',');
    expect(parseRegionsReply(reply(n(33))), hasLength(33));
    expect(parseRegionsReply(reply(n(34))), isNull);
  });
}
