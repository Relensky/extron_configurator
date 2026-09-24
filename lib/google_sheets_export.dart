import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_logger.dart';
import 'secret_store.dart';

/// ============================================================================
///  A WORKBOOK, STRAIGHT INTO GOOGLE SHEETS
/// ============================================================================
///  Google Drive converts an uploaded .xlsx into a native Google Sheet when the
///  upload asks for the spreadsheet type, so the workbook this app already
///  writes becomes a Sheet with its tabs, formatting and formulas intact - no
///  second exporter to keep in step with the first.
///
///  Signing in is Google's own "installed app" flow: the browser opens on
///  Google's sign-in page, the answer comes back to a one-shot listener on
///  127.0.0.1, and only the `drive.file` permission is asked for - this app
///  can see the files it created and nothing else in anybody's Drive. The
///  refresh token is kept in the OS keystore (never in app_config.json), so
///  the browser is only needed the first time.
///
///  It needs an OAuth client of type "Desktop app" from a Google Cloud project
///  (App Config > Google Sheets). Without one, [GoogleSheetsUploader] is not
///  used and the export falls back to saving the .xlsx and opening Google
///  Sheets, whose Open > Upload takes the file as it is.
/// ============================================================================

const kGoogleRefreshTokenKey = 'google_sheets_refresh_token';
const kGoogleDriveFileScope = 'https://www.googleapis.com/auth/drive.file';
const kXlsxMime =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const kGoogleSheetMime = 'application/vnd.google-apps.spreadsheet';

/// Where Google Sheets' own import is, for the no-client fallback.
final Uri kGoogleSheetsHome = Uri.parse('https://docs.google.com/spreadsheets/');

class GoogleSheetsResult {
  final String id;
  final String url;
  const GoogleSheetsResult(this.id, this.url);
}

class GoogleSheetsException implements Exception {
  final String message;
  const GoogleSheetsException(this.message);
  @override
  String toString() => message;
}

/// Opens a URL in the browser. Swappable for tests.
typedef UrlOpener = Future<bool> Function(Uri uri);

Future<bool> _openInBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

class GoogleSheetsUploader {
  final String clientId;
  final String clientSecret;
  final SecretStore secrets;
  final UrlOpener openUrl;
  final HttpClient Function() httpClient;

  GoogleSheetsUploader({
    required this.clientId,
    required this.clientSecret,
    required this.secrets,
    UrlOpener? openUrl,
    HttpClient Function()? httpClient,
  })  : openUrl = openUrl ?? _openInBrowser,
        httpClient = httpClient ?? HttpClient.new;

  bool get configured => clientId.trim().isNotEmpty;

  /// Uploads [xlsx] as a new Google Sheet called [title]. Signs in first when
  /// there is no stored refresh token (or it has been revoked).
  Future<GoogleSheetsResult> upload(Uint8List xlsx, String title) async {
    if (!configured) {
      throw const GoogleSheetsException(
        'No Google client is set up - add one under App Config > Google '
        'Sheets.',
      );
    }
    var token = await _accessTokenFromRefresh();
    token ??= await _signIn();
    return _uploadWith(token, xlsx, title);
  }

  /// Forgets the stored sign-in, so the next upload asks again.
  Future<void> signOut() => secrets.delete(kGoogleRefreshTokenKey);

  // --- signing in ----------------------------------------------------------

  Future<String?> _accessTokenFromRefresh() async {
    final refresh = await secrets.read(kGoogleRefreshTokenKey);
    if (refresh == null || refresh.isEmpty) return null;
    try {
      final json = await _postForm(Uri.parse('https://oauth2.googleapis.com/token'), {
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      });
      return json['access_token']?.toString();
    } catch (e) {
      // Revoked, expired or the client changed: sign in again.
      AppLogger.logInfo('Google sign-in needs renewing: $e');
      await secrets.delete(kGoogleRefreshTokenKey);
      return null;
    }
  }

  Future<String> _signIn() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final verifier = _randomString(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomString(24);

    final auth = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': kGoogleDriveFileScope,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'access_type': 'offline',
      'prompt': 'consent',
    });

    try {
      if (!await openUrl(auth)) {
        throw const GoogleSheetsException(
          'The browser could not be opened for the Google sign-in.',
        );
      }
      final code = await _awaitCode(server, state)
          .timeout(const Duration(minutes: 5), onTimeout: () {
        throw const GoogleSheetsException(
          'The Google sign-in was not finished within five minutes.',
        );
      });
      final json = await _postForm(Uri.parse('https://oauth2.googleapis.com/token'), {
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
      });
      final refresh = json['refresh_token']?.toString() ?? '';
      if (refresh.isNotEmpty) {
        await secrets.write(kGoogleRefreshTokenKey, refresh);
      }
      final access = json['access_token']?.toString() ?? '';
      if (access.isEmpty) {
        throw const GoogleSheetsException('Google did not return a token.');
      }
      return access;
    } finally {
      await server.close(force: true);
    }
  }

  Future<String> _awaitCode(HttpServer server, String state) async {
    await for (final request in server) {
      final q = request.uri.queryParameters;
      final ok = q['state'] == state && (q['code'] ?? '').isNotEmpty;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body style="font-family:sans-serif;padding:2em">'
            '<h2>${ok ? 'Signed in to Google' : 'Google sign-in failed'}</h2>'
            '<p>You can close this tab and go back to the Room Config '
            'Builder.</p></body></html>');
      await request.response.close();
      if (q['error'] != null) {
        throw GoogleSheetsException('Google sign-in: ${q['error']}');
      }
      if (ok) return q['code']!;
    }
    throw const GoogleSheetsException('The Google sign-in was interrupted.');
  }

  // --- the upload ----------------------------------------------------------

  Future<GoogleSheetsResult> _uploadWith(
    String token,
    Uint8List xlsx,
    String title,
  ) async {
    final boundary = 'rcb${_randomString(20)}';
    final meta = jsonEncode({'name': title, 'mimeType': kGoogleSheetMime});
    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$meta\r\n'
          '--$boundary\r\n'
          'Content-Type: $kXlsxMime\r\n\r\n'))
      ..add(xlsx)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));

    final uri = Uri.parse(
      'https://www.googleapis.com/upload/drive/v3/files'
      '?uploadType=multipart&fields=id,webViewLink',
    );
    final client = httpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set(HttpHeaders.contentTypeHeader,
            'multipart/related; boundary=$boundary');
      final bytes = body.takeBytes();
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw GoogleSheetsException(
          'Google Drive refused the upload (${res.statusCode}): '
          '${_errorText(text)}',
        );
      }
      final json = jsonDecode(text) as Map;
      final id = json['id']?.toString() ?? '';
      final link = json['webViewLink']?.toString() ??
          'https://docs.google.com/spreadsheets/d/$id/edit';
      return GoogleSheetsResult(id, link);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _postForm(
    Uri uri,
    Map<String, String> form,
  ) async {
    final client = httpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.write(Uri(queryParameters: form).query);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw GoogleSheetsException(
          'Google sign-in failed (${res.statusCode}): ${_errorText(text)}',
        );
      }
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    } finally {
      client.close();
    }
  }

  static String _errorText(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        if (e is Map) return '${e['message'] ?? e}';
        return '${j['error_description'] ?? e ?? body}';
      }
    } catch (_) {}
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  static String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)])
        .join();
  }
}
