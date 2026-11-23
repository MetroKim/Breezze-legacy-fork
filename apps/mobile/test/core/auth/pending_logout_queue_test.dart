import 'package:breezze/core/auth/pending_logout_queue.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryPendingLogoutPersistence implements PendingLogoutPersistence {
  final values = <String, String>{};

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);

  @override
  Future<void> put(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test('offline revocations survive failure and are replayed independently', () async {
    final storage = _MemoryPendingLogoutPersistence();
    storage.values['breezze.refresh_token'] = 'active-session-not-for-replay';
    final queue = PendingLogoutQueue(storage);
    await queue.enqueue('offline-user-a');
    await queue.enqueue('offline-user-b');

    final delivered = <String>[];
    final successes = await queue.flush((token) async {
      if (token == 'offline-user-a') throw StateError('network disconnected');
      delivered.add(token);
    });
    expect(successes, 1);
    expect(delivered, ['offline-user-b']);
    expect(storage.values.values, contains('offline-user-a'));
    expect(storage.values.values, isNot(contains('offline-user-b')));
    expect(storage.values['breezze.refresh_token'], 'active-session-not-for-replay');

    expect(await queue.flush((token) async => delivered.add(token)), 1);
    expect(delivered, ['offline-user-b', 'offline-user-a']);
    expect(storage.values.keys.where((k) => k.startsWith(PendingLogoutQueue.prefix)), isEmpty);
  });
}
