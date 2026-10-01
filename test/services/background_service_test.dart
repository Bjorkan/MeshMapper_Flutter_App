import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/background_service.dart';

void main() {
  group('BackgroundServiceManager.waitUntilStopped', () {
    test('returns at once when the service is already gone', () async {
      var calls = 0;
      final elapsed = await BackgroundServiceManager.waitUntilStopped(
        isRunning: () async {
          calls++;
          return false;
        },
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 200),
      );
      expect(elapsed, isNotNull);
      expect(calls, 1);
    });

    test('keeps polling until the service reports stopped', () async {
      var calls = 0;
      final elapsed = await BackgroundServiceManager.waitUntilStopped(
        isRunning: () async => ++calls < 3,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 2),
      );
      expect(elapsed, isNotNull);
      expect(calls, 3);
    });

    test('gives up at the bound and returns null', () async {
      final elapsed = await BackgroundServiceManager.waitUntilStopped(
        isRunning: () async => true,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 40),
      );
      expect(elapsed, isNull);
    });

    test('a throwing check counts as still running', () async {
      var calls = 0;
      final elapsed = await BackgroundServiceManager.waitUntilStopped(
        isRunning: () async {
          calls++;
          if (calls == 1) throw StateError('channel');
          return false;
        },
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 1),
      );
      expect(elapsed, isNotNull);
      expect(calls, 2);
    });
  });
}
