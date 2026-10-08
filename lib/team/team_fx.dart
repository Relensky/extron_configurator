import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'team_host.dart';

// ============================================================================
// [TEAM KIT - EFFECTS]: life in the chat.
//
//   TeamTextEffect     the iPhone's text effects on words - Big, Small,
//                      Shake, Nod, Ripple, Bloom, Jitter, Explode - written
//                      as `[fx=shake]words[/fx]` (chat_format.dart). Played
//                      when the message appears; a click plays it again.
//   TeamAnimatedEmoji  emoji that move, the way Teams' do: Google's animated
//                      Noto Emoji (free to use, CC BY 4.0). Looked for on
//                      this PC, then in the team folder's `emoji` (the whole
//                      set, 512 px WebP, put there once), then on the
//                      internet when the share is missing or the app runs
//                      locally; kept on this PC once found. The plain emoji
//                      until then, and for one with no animation.
//
// Both can be turned off (chat menu > Effects): teamAnimateText and
// teamAnimateEmoji, kept in the host's settings.
// ============================================================================

bool get teamAnimateText => TeamHost.readSetting('chatAnimateText') != false;
bool get teamAnimateEmoji => TeamHost.readSetting('chatAnimateEmoji') != false;

/// The words of a `[fx=...]` code, animated.
class TeamTextEffect extends StatefulWidget {
  const TeamTextEffect({
    super.key,
    required this.text,
    required this.effect,
    required this.style,
    this.letterFrom = 0,
    this.letterCount,
  });

  final String text;

  /// Where [text] starts within the whole effect, and the whole effect's
  /// length, in letters: a phrase is laid out a word at a time (so it can
  /// wrap), and Ripple's wave still runs across all of it.
  final int letterFrom;
  final int? letterCount;

  /// One of ChatFormat.effects' names.
  final String effect;
  final TextStyle style;

  @override
  State<TeamTextEffect> createState() => _TeamTextEffectState();
}

class _TeamTextEffectState extends State<TeamTextEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: switch (widget.effect) {
      'big' || 'small' => const Duration(milliseconds: 900),
      'explode' => const Duration(milliseconds: 1600),
      'jitter' => const Duration(milliseconds: 1500),
      _ => const Duration(milliseconds: 1300),
    },
  );

  /// Each letter's own direction, for Jitter and Explode.
  late final List<Offset> _scatter = () {
    final r = Random(widget.text.hashCode);
    return [
      for (var i = 0; i < widget.text.length; i++)
        Offset(r.nextDouble() * 2 - 1, r.nextDouble() * 2 - 1),
    ];
  }();

  @override
  void initState() {
    super.initState();
    _t.forward();
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  void _replay() => _t.forward(from: 0);

  double get _size => widget.style.fontSize ?? 14;

  /// Big and Small end at a different size: the words keep it afterwards.
  double get _settledScale => switch (widget.effect) {
        'big' => 1.5,
        'small' => 0.72,
        _ => 1,
      };

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _replay,
        child: Tooltip(
          message: 'Click to play the effect again',
          waitDuration: const Duration(milliseconds: 800),
          child: AnimatedBuilder(
            animation: _t,
            builder: (context, _) {
              final t = _t.value;
              switch (widget.effect) {
                case 'big':
                case 'small':
                  // Overshoots, then settles at its new size.
                  final curve = Curves.elasticOut.transform(t);
                  final scale = 1 + (_settledScale - 1) * curve;
                  return Text(widget.text,
                      style: style.copyWith(fontSize: _size * scale));
                case 'shake':
                  final dx = sin(t * pi * 12) * 4 * (1 - t);
                  return Transform.translate(
                      offset: Offset(dx, 0), child: Text(widget.text, style: style));
                case 'nod':
                  final dy = sin(t * pi * 6) * 3.5 * (1 - t);
                  return Transform.translate(
                      offset: Offset(0, dy), child: Text(widget.text, style: style));
                case 'bloom':
                  final k = sin(t * pi);
                  final glow = (style.color ?? Colors.amber);
                  return Transform.scale(
                    scale: 1 + 0.25 * k,
                    child: Text(widget.text,
                        style: style.copyWith(shadows: [
                          Shadow(
                              color: glow.withValues(alpha: 0.7 * k),
                              blurRadius: 14 * k),
                        ])),
                  );
                default:
                  return _letters(style, t);
              }
            },
          ),
        ),
      ),
    );
  }

  /// Ripple, Jitter and Explode move each letter on its own.
  Widget _letters(TextStyle style, double t) {
    final chars = widget.text.characters.toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chars.length; i++)
          () {
            Offset o;
            double turn = 0;
            switch (widget.effect) {
              case 'ripple':
                // A wave from the first letter to the last.
                final at = widget.letterFrom + i;
                final of = widget.letterCount ?? chars.length;
                final local = (t * 1.6 - at / max(of, 1) * 0.6)
                    .clamp(0.0, 1.0);
                o = Offset(0, -sin(local * pi) * _size * 0.45);
              case 'jitter':
                final live = t < 1 ? 1.0 : 0.0;
                final s = _scatter[min(i, _scatter.length - 1)];
                final phase = sin((t * 30) + i * 1.7);
                o = Offset(s.dx * 1.8 * phase, s.dy * 1.8 * phase) * live;
              case 'explode':
                // Out for the first part, home again for the rest.
                final out = t < 0.35
                    ? Curves.easeOut.transform(t / 0.35)
                    : 1 - Curves.easeInOutBack.transform((t - 0.35) / 0.65);
                final s = _scatter[min(i, _scatter.length - 1)];
                o = Offset(s.dx * _size * 2.4, s.dy * _size * 1.8) * out;
                turn = s.dx * 1.2 * out;
              default:
                o = Offset.zero;
            }
            return Transform.translate(
              offset: o,
              child: Transform.rotate(
                  angle: turn, child: Text(chars[i], style: style)),
            );
          }(),
      ],
    );
  }
}

/// [TEAM KIT - EMOJI]: an emoji that moves - Google's animated Noto Emoji -
/// at [size], or the emoji as text when there is no animation for it.
class TeamAnimatedEmoji extends StatefulWidget {
  const TeamAnimatedEmoji(this.emoji,
      {super.key, required this.size, this.style});

  final String emoji;
  final double size;

  /// The text it stands in for - so the plain emoji matches it.
  final TextStyle? style;

  @override
  State<TeamAnimatedEmoji> createState() => _TeamAnimatedEmojiState();
}

class _TeamAnimatedEmojiState extends State<TeamAnimatedEmoji> {
  File? _file;

  @override
  void initState() {
    super.initState();
    final cached = TeamEmojiStore.known(widget.emoji);
    if (cached != null) {
      _file = cached;
    } else {
      TeamEmojiStore.fetch(widget.emoji).then((f) {
        if (mounted && f != null) setState(() => _file = f);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final plain = Text(widget.emoji,
        style: (widget.style ?? const TextStyle())
            .copyWith(fontSize: widget.size * 0.82, height: 1.1));
    if (file == null) return plain;
    return Semantics(
      label: widget.emoji,
      child: Image.file(
        file,
        width: widget.size,
        height: widget.size,
        gaplessPlayback: true,
        // Decoded small: the file is 512 px, drawn at ~20-44.
        cacheWidth: (widget.size * 2.5).round(),
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => plain,
      ),
    );
  }
}

/// Where animated emoji are kept on this PC, and how they are fetched.
class TeamEmojiStore {
  TeamEmojiStore._();

  /// The animation for an emoji (animated WebP - half the size of the
  /// GIF, and only 512 px is offered): its code points in hex joined by '_', without the
  /// FE0F variation selector, as the Noto set names them.
  static String codeOf(String emoji) => emoji.runes
      .where((r) => r != 0xFE0F)
      .map((r) => r.toRadixString(16))
      .join('_');

  static Uri urlOf(String emoji) => Uri.parse(
      'https://fonts.gstatic.com/s/e/notoemoji/latest/${codeOf(emoji)}/512.webp');

  static Directory get folder => Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}cts_team_emoji');

  /// [TEAM KIT - EMOJI]: the team folder's copy of the whole set -
  /// `<team folder>\emoji\<code>.webp`, put there once - set when the chat
  /// joins its folder. Read before the internet, so the share serves them.
  static String sharedFolder = '';

  static final Map<String, File> _ready = {};
  static final Map<String, Future<File?>> _fetching = {};
  static DateTime? _offlineUntil;

  /// The kept GIF, when it is already known to be on disk.
  static File? known(String emoji) => _ready[codeOf(emoji)];

  /// The GIF on disk, fetched the first time. Null when there is none (no
  /// animation for this emoji, no network, or under a test).
  static Future<File?> fetch(String emoji) {
    final code = codeOf(emoji);
    return _fetching[code] ??= () async {
      if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
      final sep = Platform.pathSeparator;
      final file = File('${folder.path}$sep$code.webp');
      final none = File('${folder.path}$sep$code.none');
      try {
        if (await file.exists() && await file.length() > 0) {
          return _ready[code] = file;
        }
        // Asked before and there was nothing: not asked again for a week.
        if (await none.exists() &&
            DateTime.now().difference(await none.lastModified()) <
                const Duration(days: 7)) {
          return null;
        }
      } catch (_) {}
      // The team folder's copy, brought to this PC.
      if (sharedFolder.isNotEmpty) {
        try {
          final shared = File('$sharedFolder$sep$code.webp');
          if (await shared.exists()) {
            await folder.create(recursive: true);
            final temp = File('${file.path}.part');
            await shared.copy(temp.path);
            await temp.rename(file.path);
            return _ready[code] = file;
          }
        } catch (_) {
          // The share is out of reach: the internet instead.
        }
      }
      if (_offlineUntil != null && DateTime.now().isBefore(_offlineUntil!)) {
        return null;
      }
      try {
        final res =
            await http.get(urlOf(emoji)).timeout(const Duration(seconds: 8));
        await folder.create(recursive: true);
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          final temp = File('${file.path}.part');
          await temp.writeAsBytes(res.bodyBytes, flush: true);
          await temp.rename(file.path);
          return _ready[code] = file;
        }
        if (res.statusCode == 404) await none.writeAsString('');
      } on SocketException {
        _offlineUntil = DateTime.now().add(const Duration(minutes: 5));
      } on TimeoutException {
        _offlineUntil = DateTime.now().add(const Duration(minutes: 5));
      } catch (e) {
        TeamHost.log('[TEAM] emoji $code not fetched: $e');
      }
      return null;
    }();
  }
}
