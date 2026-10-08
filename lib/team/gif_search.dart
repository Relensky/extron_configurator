import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// ============================================================================
// [TEAM CHAT - GIFS]: searching the web for a GIF to post.
//
// Tenor - what most apps used - was shut down by Google on 30 June 2026.
// Two services are left that a small app can use, and both want a free key:
//   - KLIPY (klipy.com/developers), Tenor's usual replacement;
//   - GIPHY (developers.giphy.com).
// The key goes in team_config.json beside the chat - "gifs": {"provider":
// "klipy", "apiKey": "..."} - so one person sets it up for the whole team,
// or into the build as --dart-define GIF_API_KEY / GIF_PROVIDER. Without one,
// the picker says how to add it and still takes a pasted GIF link.
// ============================================================================

class GifResult {
  /// Small, for the picker's grid.
  final String previewUrl;

  /// What is posted: medium size, so a chat full of them stays light.
  final String url;
  final int width;
  final int height;
  final String title;

  const GifResult({
    required this.previewUrl,
    required this.url,
    this.width = 0,
    this.height = 0,
    this.title = '',
  });
}

class GifSearchSettings {
  /// 'klipy' or 'giphy'.
  final String provider;
  final String apiKey;

  const GifSearchSettings({this.provider = 'klipy', this.apiKey = ''});

  static const String _buildKey = String.fromEnvironment('GIF_API_KEY');
  static const String _buildProvider =
      String.fromEnvironment('GIF_PROVIDER', defaultValue: 'klipy');

  bool get ready => apiKey.trim().isNotEmpty;

  String get providerLabel => provider == 'giphy' ? 'GIPHY' : 'KLIPY';

  /// The team's settings, else the build's.
  static GifSearchSettings from(Object? teamJson) {
    if (teamJson is Map) {
      final key = (teamJson['apiKey'] ?? '').toString().trim();
      if (key.isNotEmpty) {
        return GifSearchSettings(
            provider: _norm(teamJson['provider']), apiKey: key);
      }
    }
    return GifSearchSettings(provider: _norm(_buildProvider), apiKey: _buildKey);
  }

  /// Reads the "gifs" block of team_config.json in [teamFolder].
  static Future<GifSearchSettings> load(String teamFolder) async {
    try {
      final f = File('$teamFolder${Platform.pathSeparator}team_config.json');
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString());
        if (json is Map) return from(json['gifs']);
      }
    } catch (_) {}
    return from(null);
  }

  static String _norm(Object? p) =>
      (p ?? '').toString().trim().toLowerCase() == 'giphy' ? 'giphy' : 'klipy';
}

class GifSearch {
  GifSearch._();

  /// GIFs for [query], or what is trending for ''. Throws with a message
  /// to show when the service cannot be reached or refuses the key.
  static Future<List<GifResult>> search(
    GifSearchSettings settings,
    String query, {
    String user = '',
    http.Client? client,
  }) async {
    if (!settings.ready) return const [];
    final q = query.trim();
    final Uri uri;
    if (settings.provider == 'giphy') {
      uri = Uri.https('api.giphy.com',
          q.isEmpty ? '/v1/gifs/trending' : '/v1/gifs/search', {
        'api_key': settings.apiKey,
        if (q.isNotEmpty) 'q': q,
        'limit': '30',
        'rating': 'g',
      });
    } else {
      uri = Uri.https(
          'api.klipy.com',
          '/api/v1/${Uri.encodeComponent(settings.apiKey)}/gifs/'
              '${q.isEmpty ? 'trending' : 'search'}',
          {
            if (q.isNotEmpty) 'q': q,
            'per_page': '30',
            if (user.isNotEmpty) 'customer_id': user,
          });
    }
    final c = client ?? http.Client();
    try {
      final res = await c.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw StateError('${settings.providerLabel} did not accept the GIF '
            'key in team_config.json.');
      }
      if (res.statusCode != 200) {
        throw StateError('${settings.providerLabel} answered '
            '${res.statusCode}.');
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      return settings.provider == 'giphy' ? parseGiphy(json) : parseKlipy(json);
    } finally {
      if (client == null) c.close();
    }
  }

  static int _int(Object? v) =>
      v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

  /// GIPHY: data[].images.{fixed_width_downsampled | fixed_width, downsized}.
  static List<GifResult> parseGiphy(Object? json) {
    final out = <GifResult>[];
    final data = json is Map ? json['data'] : null;
    if (data is! List) return out;
    for (final item in data) {
      if (item is! Map || item['images'] is! Map) continue;
      final images = item['images'] as Map;
      Map? pick(List<String> names) {
        for (final n in names) {
          final v = images[n];
          if (v is Map && '${v['url'] ?? ''}'.startsWith('http')) return v;
        }
        return null;
      }

      final small = pick(['fixed_width_downsampled', 'fixed_width', 'downsized']);
      final full = pick(['downsized', 'fixed_width', 'original']);
      if (small == null || full == null) continue;
      out.add(GifResult(
        previewUrl: '${small['url']}',
        url: '${full['url']}',
        width: _int(full['width']),
        height: _int(full['height']),
        title: '${item['title'] ?? ''}',
      ));
    }
    return out;
  }

  /// KLIPY: data.data[].file.{xs, sm, md, hd}.gif {url, width, height}.
  static List<GifResult> parseKlipy(Object? json) {
    final out = <GifResult>[];
    Object? data = json is Map ? json['data'] : null;
    if (data is Map) data = data['data'];
    if (data is! List) return out;
    for (final item in data) {
      if (item is! Map) continue;
      final files = item['file'] ?? item['files'];
      if (files is! Map) continue;
      Map? pick(List<String> sizes) {
        for (final s in sizes) {
          final size = files[s];
          if (size is! Map) continue;
          final gif = size['gif'];
          if (gif is Map && '${gif['url'] ?? ''}'.startsWith('http')) {
            return gif;
          }
        }
        return null;
      }

      final small = pick(['sm', 'xs', 'md', 'hd']);
      final full = pick(['md', 'sm', 'hd']);
      if (small == null || full == null) continue;
      out.add(GifResult(
        previewUrl: '${small['url']}',
        url: '${full['url']}',
        width: _int(full['width']),
        height: _int(full['height']),
        title: '${item['title'] ?? ''}',
      ));
    }
    return out;
  }

  /// A GIF's own web address pasted into the search box, or null.
  static GifResult? fromLink(String text) {
    final t = text.trim();
    final uri = Uri.tryParse(t);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
      return null;
    }
    final path = uri.path.toLowerCase();
    if (!(path.endsWith('.gif') || path.endsWith('.webp'))) return null;
    return GifResult(previewUrl: t, url: t);
  }
}
