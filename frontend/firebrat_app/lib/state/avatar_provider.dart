import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/painting.dart' show FileImage;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/auth_service.dart';
import '../services/avatar_store.dart';
import 'library_providers.dart';
import 'on_device_conversion_providers.dart';

final avatarStoreProvider = Provider<AvatarStore>((ref) => AvatarStore());

/// The current account's profile photo (null = show the initial).
///
/// The photo always lives on this device, so guests and offline users get an
/// avatar too. Signed-in users on a Firebrat server in cloud mode also sync it
/// to that server (best effort: a failed upload never blocks the UI), and a
/// fresh install pulls it back down after sign-in.
class AvatarNotifier extends AsyncNotifier<File?> {
  String get _key => AuthService.instance.currentUser?.uid ?? 'guest';

  bool get _canSync =>
      AuthService.instance.currentUser != null &&
      ref.read(conversionModeProvider).mode == ConversionModePref.cloud &&
      ref.read(conversionModeProvider).cloudServerUrl.trim().isNotEmpty;

  @override
  Future<File?> build() async {
    final store = ref.read(avatarStoreProvider);
    final local = await store.load(_key);
    if (local != null || !_canSync) return local;
    try {
      final bytes = await ref.read(apiClientProvider).getAvatar();
      if (bytes != null) return await store.save(_key, bytes);
    } catch (_) {}
    return null;
  }

  /// Throws [FormatException] for a file that is not an image.
  Future<void> setFromBytes(Uint8List bytes) async {
    final saved = await ref.read(avatarStoreProvider).save(_key, bytes);
    // Evict the old decode of the same path so the drawer shows the new photo.
    await FileImage(saved).evict();
    state = AsyncData(saved);
    if (_canSync) {
      try {
        await ref.read(apiClientProvider).putAvatar(await saved.readAsBytes());
      } catch (_) {}
    }
  }

  Future<void> remove() async {
    await ref.read(avatarStoreProvider).remove(_key);
    state = const AsyncData(null);
    if (_canSync) {
      try {
        await ref.read(apiClientProvider).deleteAvatar();
      } catch (_) {}
    }
  }
}

final avatarProvider =
    AsyncNotifierProvider<AvatarNotifier, File?>(AvatarNotifier.new);
