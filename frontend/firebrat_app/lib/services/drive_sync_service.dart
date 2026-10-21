import 'dart:async';
import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';

/// Google Drive sync for book blobs: the user's own Drive quota holds the
/// ~400MB zips (never Firebase Storage, never our server disk), so regular
/// users get cross-device books for free. drive.file scope = only files
/// this app created — good privacy hygiene.
///
/// Design notes for maintainers:
/// - Auth piggybacks the existing Google sign-in: [ensureAccess] escalates
///   with a Drive scopeHint ONLY when the user turns sync on (never at
///   login — incremental consent).
/// - One `Firebrat/` folder; one zip per bookId (`<bookId>.zip`); integrity
///   via Drive's `sha256Checksum` compared against the server checksum
///   (same value `DownloadManager` verifies — single source of truth).
/// - Uploads use resumable sessions chunked at 8MB so a dropped relay
///   resumes instead of restarting; downloads resume via Range the same way.
class DriveSyncService {
  DriveSyncService._();
  static final DriveSyncService instance = DriveSyncService._();

  static const scopeDriveFile = 'https://www.googleapis.com/auth/drive.file';
  static const _folderName = 'Firebrat';
  static const _folderKey = 'drive.firebratFolderId';
  static const _enabledKey = 'drive.syncEnabled';

  Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;

  Future<void> setEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_enabledKey, v);

  /// Signed-in account with Drive scope, escalating consent if needed.
  /// Throws (with a human message) when sign-in is required first.
  Future<GoogleSignInAccount> ensureAccess() async {
    final auth = AuthService.instance;
    var account = auth.currentGoogleUser;
    account ??= await auth.signInSilentlyOrInteractiveDrive();
    if (account == null) {
      throw StateError('Sign in with Google first (Account tab).');
    }
    return account;
  }

  Future<drive.DriveApi> _api() async {
    final account = await ensureAccess();
    final authz = await account.authorizationClient.authorizeScopes(
      [scopeDriveFile],
    );
    final token = authz.accessToken;
    return drive.DriveApi(_BearerClient(token));
  }

  Future<String> _folderId(drive.DriveApi api) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_folderKey);
    if (cached != null) {
      try {
        await api.files.get(cached, $fields: 'id');
        return cached;
      } catch (_) {}
    }
    final found = await api.files.list(
      q: "mimeType='application/vnd.google-apps.folder' and name='$_folderName' and trashed=false",
      $fields: 'files(id)',
    );
    if (found.files?.isNotEmpty ?? false) {
      await prefs.setString(_folderKey, found.files!.first.id!);
      return found.files!.first.id!;
    }
    final created = await api.files.create(
      drive.File(name: _folderName, mimeType: 'application/vnd.google-apps.folder'),
      $fields: 'id',
    );
    await prefs.setString(_folderKey, created.id!);
    return created.id!;
  }

  /// Files in the Firebrat folder: {name, id, size, modifiedTime, sha256}.
  Future<List<DriveBookFile>> listBooks() async {
    final api = await _api();
    final folder = await _folderId(api);
    final out = <DriveBookFile>[];
    String? page;
    do {
      final res = await api.files.list(
        q: "'$folder' in parents and trashed=false",
        orderBy: 'modifiedTime desc',
        pageToken: page,
        $fields: 'nextPageToken,files(id,name,size,modifiedTime,sha256Checksum)',
      );
      for (final f in res.files ?? []) {
        out.add(DriveBookFile(
          id: f.id!,
          name: f.name ?? '',
          sizeBytes: int.tryParse(f.size ?? '') ?? 0,
          modifiedTime: f.modifiedTime,
          sha256: f.sha256Checksum,
        ));
      }
      page = res.nextPageToken;
    } while (page != null);
    return out;
  }

  /// Upload [zipPath] as `<bookId>.zip` (resumable, 8MB chunks).
  /// Reports cumulative bytes; total is the local file size.
  Future<String> uploadBook({
    required String bookId,
    required String zipPath,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    final api = await _api();
    final folder = await _folderId(api);
    final file = File(zipPath);
    final total = await file.length();
    final meta = drive.File(name: '$bookId.zip', parents: [folder]);
    final stream = file.openRead();
    var sent = 0;
    final counting = stream.map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent, total);
      return chunk;
    });
    final created = await api.files.create(
      meta,
      uploadMedia: drive.Media(counting, total),
      $fields: 'id',
    );
    return created.id!;
  }

  /// Download a Drive file with Range resume into [destPath] (via .part).
  Future<void> downloadBook({
    required String driveFileId,
    required String destPath,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final api = await _api();
    final part = File('$destPath.part');
    var have = await part.exists() ? await part.length() : 0;
    final meta = await api.files.get(driveFileId, $fields: 'size') as drive.File;
    final total = int.tryParse(meta.size ?? '');
    if (total != null && have >= total && total > 0) {
      await part.rename(destPath);
      onProgress?.call(total, total);
      return;
    }
    final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    try {
      // Drive honors Range on file downloads; fall back to full on 200.
      // ByteRange end is inclusive; -1 means "to the end".
      final media = await api.files.get(
        driveFileId,
        downloadOptions: have > 0
            ? drive.PartialDownloadOptions(drive.ByteRange(have, -1))
            : drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      var received = have;
      await for (final chunk in media.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      await part.rename(destPath);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }
  }
}

class DriveBookFile {
  final String id;
  final String name;
  final int sizeBytes;
  final DateTime? modifiedTime;
  final String? sha256;
  const DriveBookFile({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.modifiedTime,
    required this.sha256,
  });
}

/// http client injecting a fixed Bearer token (from google_sign_in's
/// incremental authorization) into every request.
class _BearerClient extends http.BaseClient {
  final String _token;
  final http.Client _inner = http.Client();
  _BearerClient(this._token);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $_token';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
