import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LibraryLayout { list, smallCards, largeCards }

class LibraryLayoutNotifier extends Notifier<LibraryLayout> {
  static const preferenceKey = 'library.layout';
  bool _selected = false;

  @override
  LibraryLayout build() {
    _load();
    return LibraryLayout.smallCards;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted || _selected) return;
    final saved = prefs.getString(preferenceKey);
    state =
        LibraryLayout.values.where((v) => v.name == saved).firstOrNull ??
        LibraryLayout.smallCards;
  }

  Future<void> select(LibraryLayout layout) async {
    _selected = true;
    state = layout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferenceKey, layout.name);
  }
}

final libraryLayoutProvider =
    NotifierProvider<LibraryLayoutNotifier, LibraryLayout>(
      LibraryLayoutNotifier.new,
    );
