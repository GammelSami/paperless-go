import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_go/core/auth/auth_provider.dart';
import 'package:paperless_go/core/auth/secure_storage.dart';
import 'package:paperless_go/core/settings/start_screen.dart';

/// A keystore that cannot be read or written — what a backup restore or an
/// invalidated Android key looks like to flutter_secure_storage.
class _BrokenStorage extends SecureStorageService {
  @override
  Future<String?> getStartScreen() async =>
      throw PlatformException(code: 'keystore', message: 'decrypt failed');

  @override
  Future<void> saveStartScreen(String name) async =>
      throw PlatformException(code: 'keystore', message: 'encrypt failed');
}

void main() {
  group('StartScreen.parse', () {
    test('maps stored names to screens and anything else to Inbox', () {
      expect(StartScreen.parse('inbox'), StartScreen.inbox);
      expect(StartScreen.parse('library'), StartScreen.library);
      expect(StartScreen.parse(null), StartScreen.inbox);
      expect(StartScreen.parse(''), StartScreen.inbox);
      expect(StartScreen.parse('dashboard'), StartScreen.inbox);
    });

    test('every screen has a shell route and a label', () {
      for (final screen in StartScreen.values) {
        expect(screen.route, startsWith('/'));
        expect(screen.label, isNotEmpty);
      }
    });
  });

  group('startScreenProvider', () {
    late ProviderContainer container;

    ProviderContainer build(Map<String, String> stored) {
      FlutterSecureStorage.setMockInitialValues({...stored});
      final storage =
          SecureStorageService(storage: const FlutterSecureStorage());
      return ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
    }

    test('loads the stored choice', () async {
      container = build({'start_screen': 'inbox'});
      addTearDown(container.dispose);
      expect(
        await container.read(startScreenProvider.future),
        StartScreen.inbox,
      );
    });

    test('defaults to Inbox when nothing is stored', () async {
      container = build({});
      addTearDown(container.dispose);
      expect(
        await container.read(startScreenProvider.future),
        StartScreen.inbox,
      );
    });

    test('a storage read failure degrades to Inbox instead of erroring',
        () async {
      // The router awaits this; an error here would leave the app on a
      // blank screen with no route to login.
      container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(_BrokenStorage())],
      );
      addTearDown(container.dispose);
      expect(
        await container.read(startScreenProvider.future),
        StartScreen.inbox,
      );
      expect(container.read(startScreenProvider).hasError, isFalse);
    });

    test('a storage write failure reverts the choice and reports false',
        () async {
      // The failed write must restore the previously shown choice.
      container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(_BrokenStorage())],
      );
      addTearDown(container.dispose);
      await container.read(startScreenProvider.future);
      final saved = await container
          .read(startScreenProvider.notifier)
          .set(StartScreen.library);
      expect(saved, isFalse);
      expect(
        container.read(startScreenProvider).valueOrNull,
        StartScreen.inbox,
      );
    });

    test('set() updates state immediately and persists', () async {
      container = build({});
      addTearDown(container.dispose);
      await container.read(startScreenProvider.future);

      final saved = await container
          .read(startScreenProvider.notifier)
          .set(StartScreen.inbox);

      expect(saved, isTrue);
      expect(
        container.read(startScreenProvider).valueOrNull,
        StartScreen.inbox,
      );
      expect(
        await SecureStorageService(storage: const FlutterSecureStorage())
            .getStartScreen(),
        'inbox',
      );
    });
  });
}
