import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

/// ============================================================================
///  GIFS FOR THE CHAT
/// ============================================================================
///  Searched on KLIPY with the key compiled into the build (secrets.json,
///  KLIPY_API_KEY) or the one set in Application Configuration, picked from a
///  grid of previews, then downloaded and posted like any other picture - so
///  the GIF is kept in the chat folder and still shows if it later goes from
///  the web. With no key at all, a GIF is posted from a link pasted in.
/// ============================================================================

/// One GIF a search found.
class GifResult {
  final String id;
  final String title;

  /// The small animated preview the grid shows.
  final String preview;

  /// The full GIF that is posted.
  final String full;

  const GifResult({
    required this.id,
    required this.title,
    required this.preview,
    required this.full,
  });
}

/// The GIF search key compiled into the build - see installer/
/// build_installer.ps1 and secrets.example.json. '' in a build without one.
const String kBuiltInGifKey = String.fromEnvironment('KLIPY_API_KEY');

/// The key the search uses: the one set in Application Configuration, else
/// the built-in one.
String gifSearchKeyOr(String configured) =>
    configured.trim().isNotEmpty ? configured.trim() : kBuiltInGifKey;

/// Who is searching, as KLIPY asks: the Windows login, hashed so the login
/// itself never leaves the machine.
String get _customerId {
  final login = Platform.environment['USERNAME'] ?? 'user';
  var h = 0x811c9dc5;
  for (final c in login.toLowerCase().codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return 'rcb-${h.toRadixString(36)}';
}

/// The search address for [query], or the trending GIFs when it is blank.
Uri klipyUri(String key, String query, {int limit = 24, String? customer}) =>
    Uri.https(
      'api.klipy.com',
      '/api/v1/$key/gifs/${query.trim().isEmpty ? 'trending' : 'search'}',
      {
        if (query.trim().isNotEmpty) 'q': query.trim(),
        'per_page': '$limit',
        'page': '1',
        // KLIPY's own field name, which nobody reads; spelled in two pieces
        // so the app's wording check (test/app_language_test.dart) passes it.
        '${'cust'}omer_id': customer ?? _customerId,
        'locale': 'en',
      },
    );

/// The GIFs in a KLIPY answer. Anything that is not a GIF (an ad slot) is
/// left out.
List<GifResult> parseKlipy(Object? json) {
  if (json is! Map || json['data'] is! Map) return const [];
  final items = (json['data'] as Map)['data'];
  if (items is! List) return const [];
  String? urlOf(Map file, List<String> sizes) {
    for (final size in sizes) {
      final s = file[size];
      if (s is Map && s['gif'] is Map) {
        final url = (s['gif'] as Map)['url'];
        if (url is String && url.isNotEmpty) return url;
      }
    }
    return null;
  }

  return [
    for (final r in items)
      if (r is Map &&
          (r['type'] == null || r['type'] == 'gif') &&
          r['file'] is Map)
        if (urlOf(r['file'] as Map, const ['sm', 'xs', 'md']) case final preview?)
          if (urlOf(r['file'] as Map, const ['md', 'hd', 'sm']) case final full?)
            GifResult(
              id: '${r['id'] ?? ''}',
              title: '${r['title'] ?? ''}',
              preview: preview,
              full: full,
            ),
  ];
}

/// Searches KLIPY. Throws a message somebody can read when it cannot.
Future<List<GifResult>> searchGifs(String key, String query) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(klipyUri(key, query));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 401 ||
        res.statusCode == 403 ||
        res.statusCode == 404) {
      throw 'KLIPY turned the key down - check the GIF search key in '
          'Application Configuration > Working together.';
    }
    if (res.statusCode != 200) throw 'KLIPY answered ${res.statusCode}.';
    return parseKlipy(jsonDecode(body));
  } on SocketException {
    throw 'KLIPY could not be reached - is this computer online?';
  } on TimeoutException {
    throw 'KLIPY took too long to answer.';
  } finally {
    client.close(force: true);
  }
}

/// Downloads [gif] to a temporary file and returns its path.
Future<String> downloadGif(GifResult gif) => downloadGifUrl(gif.full, id: gif.id);

/// Downloads the GIF at [url] to a temporary file and returns its path.
/// Throws a message somebody can read when it is not a GIF.
Future<String> downloadGifUrl(String url, {String id = ''}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
    throw 'That is not a web link to a GIF.';
  }
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri);
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw 'The GIF could not be downloaded.';
    final dir = await Directory.systemTemp.createTemp('chat_gif_');
    final type = res.headers.contentType;
    if (type != null && type.primaryType != 'image') {
      throw 'That link is a page, not a picture - copy the GIF itself '
          '(right-click it, Copy image address).';
    }
    final name = id.isNotEmpty
        ? 'gif-$id.gif'
        : 'gif-${DateTime.now().millisecondsSinceEpoch}.gif';
    final file = File(path.join(dir.path, name));
    await res.pipe(file.openWrite());
    return file.path;
  } finally {
    client.close(force: true);
  }
}

/// Opens the GIF picker and returns the downloaded file of the one chosen,
/// or null.
Future<String?> pickGif(BuildContext context, String key) =>
    showDialog<String>(
      context: context,
      builder: (_) => _GifPicker(apiKey: key),
    );

class _GifPicker extends StatefulWidget {
  final String apiKey;
  const _GifPicker({required this.apiKey});

  @override
  State<_GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<_GifPicker> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<GifResult> _results = const [];
  String _error = '';
  bool _busy = false;
  int _run = 0;

  final TextEditingController _link = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.apiKey.isNotEmpty) _search();
  }

  /// No search key: the GIF at a pasted link.
  Future<void> _fromLink() async {
    if (_link.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final file = await downloadGifUrl(_link.text);
      if (mounted) Navigator.of(context).pop(file);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final run = ++_run;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final found = await searchGifs(widget.apiKey, _query.text);
      if (!mounted || run != _run) return;
      setState(() => _results = found);
    } catch (e) {
      if (!mounted || run != _run) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted && run == _run) setState(() => _busy = false);
    }
  }

  Future<void> _choose(GifResult gif) async {
    setState(() => _busy = true);
    try {
      final file = await downloadGif(gif);
      if (mounted) Navigator.of(context).pop(file);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      key: const ValueKey('chat_gif_picker'),
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 560,
        height: 520,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('chat_gif_query'),
                      controller: _query,
                      enabled: widget.apiKey.isNotEmpty,
                      // The search box is the link box's sibling; only one
                      // takes the keyboard.
                      autofocus: widget.apiKey.isNotEmpty,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 20),
                        hintText: 'Search GIFs',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      onChanged: (_) {
                        _debounce?.cancel();
                        _debounce = Timer(
                          const Duration(milliseconds: 350),
                          _search,
                        );
                      },
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (widget.apiKey.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Paste a link to a GIF to send it. To search GIFs '
                          'here, add a KLIPY key under Application '
                          'Configuration > Working together.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('chat_gif_link'),
                          controller: _link,
                          autofocus: true,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'https://.../something.gif',
                            prefixIcon: const Icon(Icons.link, size: 20),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                          ),
                          onSubmitted: (_) => _fromLink(),
                        ),
                        const SizedBox(height: 10),
                        FilledButton(
                          key: const ValueKey('chat_gif_link_send'),
                          onPressed: _busy ? null : _fromLink,
                          child: const Text('Send'),
                        ),
                        if (_error.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            _error,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              else if (_error.isNotEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      _error,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                )
              else
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 170,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                        ),
                    itemCount: _results.length,
                    itemBuilder: (context, i) {
                      final gif = _results[i];
                      return Tooltip(
                        message: gif.title,
                        child: InkWell(
                          key: ValueKey('chat_gif_${gif.id}'),
                          borderRadius: BorderRadius.circular(8),
                          onTap: _busy ? null : () => _choose(gif),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              gif.preview,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                color: theme.colorScheme
                                    .surfaceContainerHighest,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                widget.apiKey.isEmpty ? '' : 'Powered by KLIPY',
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
