import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ============================================================================
// [TEAM CHAT - FORMATTING]: styled words in a message, kept as plain text
// markers so the files stay readable and older dashboards just show them:
//
//   **bold**   *italic*   __underline__   ~~strike~~   `code`   ```block```
//   [color=red]...[/color]   [font=serif]...[/font]   [size=large]...[/size]
//
// Also drawn: @mentions, #hashtags (a click opens that topic's thread) and
// web links (a click opens them). The composer shows the same styles as you
// type, with the markers faded ([ChatFormatController]).
// ============================================================================

class ChatFormat {
  ChatFormat._();

  /// Fonts on every Windows PC, by the name used in [font=...].
  static const Map<String, String> fonts = {
    'sans': 'Segoe UI',
    'serif': 'Georgia',
    'mono': 'Consolas',
    'rounded': 'Comic Sans MS',
    'script': 'Segoe Script',
    'narrow': 'Arial Narrow',
  };

  /// What each font is called in the menu.
  static const Map<String, String> fontLabels = {
    'sans': 'Sans (normal)',
    'serif': 'Serif',
    'mono': 'Monospace',
    'rounded': 'Rounded',
    'script': 'Script',
    'narrow': 'Narrow',
  };

  /// Colors by the name used in [color=...]; readable on light and dark.
  /// In the Color menu's order, eight to a row. Any other color is written
  /// [color=#rrggbb] (the menu's picker).
  static const Map<String, Color> colors = {
    'red': Color(0xFFE53935),
    'coral': Color(0xFFFF7043),
    'orange': Color(0xFFF57C00),
    'amber': Color(0xFFFFB300),
    'gold': Color(0xFFC9A227),
    'olive': Color(0xFF9E9D24),
    'lime': Color(0xFF7CB342),
    'green': Color(0xFF43A047),
    'emerald': Color(0xFF2E9E6A),
    'teal': Color(0xFF00897B),
    'cyan': Color(0xFF00ACC1),
    'sky': Color(0xFF039BE5),
    'blue': Color(0xFF1E88E5),
    'navy': Color(0xFF3949AB),
    'indigo': Color(0xFF5C6BC0),
    'violet': Color(0xFF7E57C2),
    'purple': Color(0xFF8E24AA),
    'fuchsia': Color(0xFFE040FB),
    'pink': Color(0xFFD81B60),
    'rose': Color(0xFFF06292),
    'maroon': Color(0xFFB04A4A),
    'brown': Color(0xFF8D6E63),
    'slate': Color(0xFF607D8B),
    'gray': Color(0xFF808080),
  };

  static const Map<String, double> sizes = {
    'small': 0.85,
    'large': 1.3,
    'huge': 1.7,
  };

  static Color? colorOf(String name) {
    final n = name.trim().toLowerCase();
    final named = colors[n];
    if (named != null) return named;
    final hex = RegExp(r'^#?([0-9a-f]{6})$').firstMatch(n);
    if (hex == null) return null;
    return Color(0xFF000000 | int.parse(hex.group(1)!, radix: 16));
  }

  static final List<_Rule> _rules = [
    _Rule(RegExp(r'```([\s\S]+?)```'), 3, 3, _Kind.codeBlock),
    _Rule(RegExp(r'`([^`\n]+)`'), 1, 1, _Kind.code),
    _Rule(RegExp(r'\[color=([#\w]+)\]([\s\S]+?)\[/color\]'), -1, 8, _Kind.color),
    _Rule(RegExp(r'\[font=(\w+)\]([\s\S]+?)\[/font\]'), -1, 7, _Kind.font),
    _Rule(RegExp(r'\[size=(\w+)\]([\s\S]+?)\[/size\]'), -1, 7, _Kind.size),
    _Rule(RegExp(r'\[fx=(\w+)\]([\s\S]+?)\[/fx\]'), -1, 5, _Kind.fx),
    _Rule(RegExp(r'\*\*(?=\S)([\s\S]+?)(?<=\S)\*\*'), 2, 2, _Kind.bold),
    _Rule(RegExp(r'__(?=\S)([\s\S]+?)(?<=\S)__'), 2, 2, _Kind.underline),
    _Rule(RegExp(r'~~(?=\S)([\s\S]+?)(?<=\S)~~'), 2, 2, _Kind.strike),
    _Rule(RegExp(r'(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=\S)\*(?![*\w])'), 1, 1,
        _Kind.italic),
    _Rule(RegExp(r'https?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?]'), 0, 0,
        _Kind.link),
    _Rule(RegExp(r'(?<![\w&#/])#([A-Za-z][\w-]{1,48})'), 0, 0, _Kind.hashtag),
    _Rule(RegExp(r'(?<![\w@])@([A-Za-z0-9._-]+)'), 0, 0, _Kind.mention),
  ];

  /// The spans for [text]. [showMarkers]: keep the markers, faded (the
  /// composer); otherwise they are left out and links can be clicked.
  /// [hideMarkers], with [showMarkers]: the markers are still in the text
  /// (they must be, to be sent) but drawn too small to see. [hideStray],
  /// without [showMarkers]: half-typed or half-deleted codes (`[/f`, a lone
  /// `**`) are left out - the preview of a message being written.
  static List<InlineSpan> spans(
    String text, {
    required TextStyle base,
    required ColorScheme scheme,
    bool showMarkers = false,
    bool hideMarkers = false,
    bool hideStray = false,
    void Function(String tag)? onHashtag,
    void Function(String url)? onLink,
    InlineSpan Function(String words, String effect, TextStyle style)? onEffect,
    InlineSpan Function(String emoji, TextStyle style)? onEmoji,
  }) {
    final ctx = _Ctx(scheme, showMarkers, onHashtag, onLink,
        base.fontSize ?? 14, hideMarkers,
        onEffect: onEffect, onEmoji: onEmoji, hideStray: hideStray);
    return _parse(text, base, ctx);
  }

  /// [TEAM CHAT - EFFECTS]: the iPhone-style text effects a
  /// `[fx=<name>]words[/fx]` code can carry, in the order the menu lists them,
  /// with what each does.
  static const Map<String, String> effects = {
    'big': 'Big - grows and stays big',
    'small': 'Small - shrinks and stays small',
    'shake': 'Shake - shakes side to side',
    'nod': 'Nod - nods up and down',
    'ripple': 'Ripple - a wave runs through the letters',
    'bloom': 'Bloom - swells and glows',
    'jitter': 'Jitter - the letters jitter',
    'explode': 'Explode - flies apart and comes back',
  };

  /// One emoji: a pictograph with any skin tone and variation selector, and
  /// any characters it is joined to (a family, a profession).
  static final RegExp emoji = RegExp(
      r'(?:\p{Extended_Pictographic}(?:\u{FE0F}|[\u{1F3FB}-\u{1F3FF}])?'
      r'(?:\u{200D}\p{Extended_Pictographic}(?:\u{FE0F}|[\u{1F3FB}-\u{1F3FF}])?)*)',
      unicode: true);

  /// Whether [text] is nothing but one to three emoji - shown large, the
  /// way Teams shows a message that is only an emoji.
  static bool isEmojiOnly(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    final found = emoji.allMatches(t).toList();
    if (found.isEmpty || found.length > 3) return false;
    return t.replaceAll(emoji, '').replaceAll(RegExp(r'\s'), '').isEmpty;
  }

  /// [text] without its markers - for a notification or a preview.
  static String plain(String text) {
    var t = text;
    for (var i = 0; i < 4; i++) {
      final before = t;
      t = t
          .replaceAllMapped(RegExp(r'```([\s\S]+?)```'), (m) => m[1]!)
          .replaceAllMapped(
              RegExp(r'\[(color|font|size|fx)=[#\w]+\]([\s\S]+?)\[/\1\]'),
              (m) => m[2]!)
          .replaceAllMapped(RegExp(r'\*\*(\S[\s\S]*?)\*\*'), (m) => m[1]!)
          .replaceAllMapped(RegExp(r'__(\S[\s\S]*?)__'), (m) => m[1]!)
          .replaceAllMapped(RegExp(r'~~(\S[\s\S]*?)~~'), (m) => m[1]!)
          .replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m[1]!)
          .replaceAllMapped(
              RegExp(r'(?<![*\w])\*([^*\s][^*\n]*?)\*(?![*\w])'), (m) => m[1]!);
      if (t == before) break;
    }
    return t;
  }

  static List<InlineSpan> _parse(String s, TextStyle style, _Ctx ctx) {
    final out = <InlineSpan>[];
    var pos = 0;
    while (pos < s.length) {
      RegExpMatch? best;
      _Rule? bestRule;
      for (final rule in _rules) {
        final m = rule.re.allMatches(s, pos).firstOrNull;
        if (m == null) continue;
        if (best == null || m.start < best.start) {
          best = m;
          bestRule = rule;
        }
      }
      if (best == null || bestRule == null) {
        out.addAll(_plainSpans(s.substring(pos), style, ctx));
        break;
      }
      if (best.start > pos) {
        out.addAll(_plainSpans(s.substring(pos, best.start), style, ctx));
      }
      out.addAll(_apply(best, bestRule, style, ctx));
      pos = best.end;
    }
    return out;
  }

  /// Marker-shaped pieces with no partner yet: `**` just put in by a
  /// formatting button, a half-typed `[color=re`, a lone `[/size]`.
  static final RegExp _strayMarker = RegExp(
      r'\[/?(?:color|font|size|fx)(?:=[#\w]*)?\]?|\*+|_{2,}|~{2,}|`+');

  /// Plain words. With the markers hidden ([_Ctx.hideMarkers], the message
  /// box only) any marker-shaped piece in them is hidden as well - before
  /// they only vanished once both halves were there, so applying a style
  /// showed its codes until the words were typed between them.
  static List<InlineSpan> _plainSpans(String s, TextStyle style, _Ctx ctx) {
    if (ctx.hideStray && !ctx.markers) {
      // Whole stray codes, and what is left of one being typed or deleted
      // at the end ("[/f", "[co").
      s = s
          .replaceAll(_strayMarker, '')
          .replaceFirst(RegExp(r'\[/?[a-z]{0,5}$'), '');
    }
    // [TEAM CHAT - EMOJI]: in a message (not the box being typed in) each
    // emoji can be drawn by the app - animated, the way Teams does.
    final onEmoji = ctx.onEmoji;
    if (!ctx.markers && onEmoji != null && s.isNotEmpty) {
      final out = <InlineSpan>[];
      var at = 0;
      for (final m in emoji.allMatches(s)) {
        if (m.start > at) {
          out.add(TextSpan(text: s.substring(at, m.start), style: style));
        }
        out.add(onEmoji(m[0]!, style));
        at = m.end;
      }
      if (at < s.length) out.add(TextSpan(text: s.substring(at), style: style));
      return out;
    }
    if (!(ctx.markers && ctx.hideMarkers) || s.isEmpty) {
      return [TextSpan(text: s, style: style)];
    }
    final hidden = style.copyWith(
        color: Colors.transparent,
        fontSize: 0.01,
        letterSpacing: 0,
        decoration: TextDecoration.none,
        backgroundColor: Colors.transparent);
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in _strayMarker.allMatches(s)) {
      if (m.start > at) {
        out.add(TextSpan(text: s.substring(at, m.start), style: style));
      }
      out.add(TextSpan(text: m[0], style: hidden));
      at = m.end;
    }
    if (at < s.length) out.add(TextSpan(text: s.substring(at), style: style));
    return out;
  }

  static List<InlineSpan> _apply(
      RegExpMatch m, _Rule rule, TextStyle style, _Ctx ctx) {
    final whole = m[0]!;
    final scheme = ctx.scheme;
    // Whole-match kinds: drawn as they are, markers and all.
    switch (rule.kind) {
      case _Kind.link:
        return [
          TextSpan(
            text: whole,
            style: style.copyWith(
                color: scheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: scheme.primary),
            recognizer: ctx.markers || ctx.onLink == null
                ? null
                : (TapGestureRecognizer()..onTap = () => ctx.onLink!(whole)),
            mouseCursor: ctx.onLink == null || ctx.markers
                ? null
                : SystemMouseCursors.click,
          )
        ];
      case _Kind.hashtag:
        return [
          TextSpan(
            text: whole,
            style: style.copyWith(
                color: scheme.primary, fontWeight: FontWeight.w600),
            recognizer: ctx.markers || ctx.onHashtag == null
                ? null
                : (TapGestureRecognizer()
                  ..onTap = () => ctx.onHashtag!(m[1]!)),
            mouseCursor: ctx.onHashtag == null || ctx.markers
                ? null
                : SystemMouseCursors.click,
          )
        ];
      case _Kind.mention:
        return [
          TextSpan(
            text: whole,
            style: style.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
                backgroundColor: scheme.primary.withValues(alpha: 0.10)),
          )
        ];
      default:
        break;
    }

    final int open =
        rule.open >= 0 ? rule.open : whole.indexOf(']') + 1;
    final int close = rule.close;
    final inner = whole.substring(open, whole.length - close);
    final faded = style.copyWith(
        color: ctx.hideMarkers
            ? Colors.transparent
            : (style.color ?? scheme.onSurface).withValues(alpha: 0.35),
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
        fontFamily: 'Consolas',
        // Hidden: a hair's width, so the styled words close up.
        fontSize: ctx.hideMarkers ? 0.01 : ctx.baseSize * 0.85,
        letterSpacing: ctx.hideMarkers ? 0 : null,
        decoration: TextDecoration.none,
        backgroundColor: Colors.transparent);

    TextStyle next;
    bool recurse = true;
    switch (rule.kind) {
      case _Kind.bold:
        next = style.copyWith(fontWeight: FontWeight.w700);
      case _Kind.italic:
        next = style.copyWith(fontStyle: FontStyle.italic);
      case _Kind.underline:
        next = style.copyWith(
            decoration: TextDecoration.combine(
                [if (style.decoration != null) style.decoration!, TextDecoration.underline]));
      case _Kind.strike:
        next = style.copyWith(
            decoration: TextDecoration.combine(
                [if (style.decoration != null) style.decoration!, TextDecoration.lineThrough]));
      case _Kind.code:
      case _Kind.codeBlock:
        recurse = false;
        next = style.copyWith(
          fontFamily: 'Consolas',
          fontSize: (style.fontSize ?? ctx.baseSize) * 0.95,
          backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
        );
      case _Kind.color:
        next = style.copyWith(color: colorOf(m[1]!) ?? style.color);
      case _Kind.font:
        final f = fonts[m[1]!.toLowerCase()];
        next = f == null ? style : style.copyWith(fontFamily: f);
      case _Kind.size:
        final k = sizes[m[1]!.toLowerCase()] ?? 1.0;
        next = style.copyWith(fontSize: ctx.baseSize * k);
      case _Kind.fx:
        // [TEAM CHAT - EFFECTS]: a message hands the words to the app to
        // animate; the box being typed in shows them as they are.
        final onEffect = ctx.onEffect;
        if (!ctx.markers && onEffect != null) {
          return [onEffect(plain(inner), m[1]!.toLowerCase(), style)];
        }
        next = style;
      default:
        next = style;
    }
    return [
      if (ctx.markers) TextSpan(text: whole.substring(0, open), style: faded),
      ...(recurse
          ? _parse(inner, next, ctx)
          : [TextSpan(text: inner, style: next)]),
      if (ctx.markers)
        TextSpan(text: whole.substring(whole.length - close), style: faded),
    ];
  }
}

enum _Kind {
  fx,
  codeBlock,
  code,
  color,
  font,
  size,
  bold,
  underline,
  strike,
  italic,
  link,
  hashtag,
  mention,
}

class _Rule {
  final RegExp re;

  /// Marker lengths before and after the words; -1: up to the first `]`.
  final int open;
  final int close;
  final _Kind kind;
  const _Rule(this.re, this.open, this.close, this.kind);
}

class _Ctx {
  final ColorScheme scheme;
  final bool markers;
  final void Function(String tag)? onHashtag;
  final void Function(String url)? onLink;
  final double baseSize;
  final bool hideMarkers;
  final InlineSpan Function(String words, String effect, TextStyle style)?
      onEffect;
  final InlineSpan Function(String emoji, TextStyle style)? onEmoji;
  final bool hideStray;
  const _Ctx(this.scheme, this.markers, this.onHashtag, this.onLink,
      this.baseSize, this.hideMarkers,
      {this.onEffect, this.onEmoji, this.hideStray = false});
}

/// The message box: shows the formatting as it is typed, with the markers
/// faded, so what goes out is what you see.
class ChatFormatController extends TextEditingController {
  ChatFormatController({super.text});

  /// [TEAM CHAT - FORMATTING]: draw only the styled words, the markers
  /// ([color=red], **) shrunk out of sight. Shared by every message box and
  /// remembered (window_memory.json, set by the chat).
  static final ValueNotifier<bool> hideMarkers = ValueNotifier(false);

  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    // While an IME is composing, keep its underline: plain text.
    if (text.isEmpty ||
        (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final base = style ?? DefaultTextStyle.of(context).style;
    return TextSpan(
      style: base,
      children: ChatFormat.spans(text,
          base: base,
          scheme: Theme.of(context).colorScheme,
          showMarkers: true,
          hideMarkers: hideMarkers.value),
    );
  }

  /// [TEAM CHAT - FORMATTING]: what a style button does. The buttons used
  /// to only ever add codes, so switching words from one style to another
  /// stacked the new style on the old - underline and strikethrough lines
  /// stayed on words meant to be bold. Now:
  ///   - the style already round the selection (just outside it, or as its
  ///     first and last characters) comes OFF;
  ///   - a colour, font or size already round it is SWAPPED for the new one
  ///     (or comes off, pressed again with the same value);
  ///   - otherwise it goes on, as [wrap].
  void toggle(String open, String close) {
    final v = value;
    final t = v.text;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: t.length);
    final start = sel.start, end = sel.end;

    void set(String text, int s, int e) => value = TextEditingValue(
          text: text,
          selection: s == e
              ? TextSelection.collapsed(offset: s)
              : TextSelection(baseOffset: s, extentOffset: e),
        );

    // A tag: [color=red] ... [/color] - swapped or taken off.
    final tag =
        RegExp(r'^\[(color|font|size|fx)=([^\]]*)\]$').firstMatch(open);
    if (tag != null) {
      final name = tag[1]!;
      final before = RegExp(r'\[' '$name' r'=([^\]]*)\]$')
          .firstMatch(t.substring(0, start));
      final closeTag = '[/$name]';
      if (before != null && t.startsWith(closeTag, end)) {
        final same = before[1]!.toLowerCase() == tag[2]!.toLowerCase();
        final head = t.substring(0, before.start);
        final words = t.substring(start, end);
        final tail = t.substring(end + closeTag.length);
        if (same) {
          set('$head$words$tail', head.length, head.length + words.length);
        } else {
          final o = '[$name=${tag[2]}]';
          set('$head$o$words$closeTag$tail', head.length + o.length,
              head.length + o.length + words.length);
        }
        return;
      }
      // Inside a longer run of the same kind - the cursor still in the
      // nodding words when Explode is picked for the next one. Nesting the
      // new code in the old cannot be read back (a [/fx] closes the first
      // [fx=..] it meets), so the old one is split round the selection:
      // [fx=nod]hello [/fx][fx=explode]world[/fx], one effect per part.
      final opens = RegExp(r'\[' '$name' r'=([^\]]*)\]')
          .allMatches(t.substring(0, start))
          .toList();
      if (opens.isNotEmpty) {
        final outer = opens.last;
        final closeAt = t.indexOf(closeTag, end);
        if (!t.substring(outer.end, start).contains(closeTag) &&
            closeAt >= 0 &&
            !t.substring(end, closeAt).contains('[$name=')) {
          final old = outer[1]!;
          String part(String words) =>
              words.isEmpty ? '' : '[$name=$old]$words$closeTag';
          final head = t.substring(0, outer.start) +
              part(t.substring(outer.end, start));
          final words = t.substring(start, end);
          final tail = part(t.substring(end, closeAt)) +
              t.substring(closeAt + closeTag.length);
          // Pressed again with the same value: those words come out of it.
          final o = old.toLowerCase() == tag[2]!.toLowerCase()
              ? ''
              : '[$name=${tag[2]}]';
          final c = o.isEmpty ? '' : closeTag;
          set('$head$o$words$c$tail', head.length + o.length,
              head.length + o.length + words.length);
          return;
        }
      }
      wrap(open, close);
      return;
    }

    // A run of marker characters: how many of [c] sit right before / after.
    int runBefore(String c, int at) {
      var n = 0;
      while (at - n - 1 >= 0 && t[at - n - 1] == c) {
        n++;
      }
      return n;
    }

    int runAfter(String c, int at) {
      var n = 0;
      while (at + n < t.length && t[at + n] == c) {
        n++;
      }
      return n;
    }

    final c = open[0];
    final sameChars = open.split('').every((x) => x == c) && open == close;
    if (sameChars) {
      final k = runBefore(c, start), m = runAfter(c, end);
      // '*' is italic, '**' bold, '***' both: italic is on when the run is
      // odd, bold when it is 2 or more - for the other marker kinds the run
      // must be at least the marker's length.
      final len = open.length;
      final on = c == '*'
          ? (len == 1 ? k == m && k.isOdd : k == m && k >= 2)
          : k == m && k >= len;
      if (on) {
        set(t.substring(0, start - len) + t.substring(start, end) +
                t.substring(end + len),
            start - len, end - len);
        return;
      }
    }
    // The selection carries the markers itself: **words** selected whole.
    final picked = t.substring(start, end);
    if (picked.length >= open.length + close.length &&
        picked.startsWith(open) &&
        picked.endsWith(close)) {
      final inner =
          picked.substring(open.length, picked.length - close.length);
      set(t.replaceRange(start, end, inner), start, start + inner.length);
      return;
    }
    wrap(open, close);
  }

  /// Puts [open]/[close] round the selection (or round nothing, with the
  /// cursor between them), keeping the words selected.
  void wrap(String open, String close) {
    final v = value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    final picked = v.text.substring(sel.start, sel.end);
    value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, '$open$picked$close'),
      selection: picked.isEmpty
          ? TextSelection.collapsed(offset: sel.start + open.length)
          : TextSelection(
              baseOffset: sel.start + open.length,
              extentOffset: sel.start + open.length + picked.length),
    );
  }
}

/// [TEAM CHAT - FORMATTING]: erasing with the codes hidden. They are still
/// in the text (they must be, to be sent), drawn too small to see - so a
/// backspace used to take one invisible character of a "[/fx]" at a time,
/// seeming to do nothing and leaving half a code behind. With
/// [ChatFormatController.hideMarkers] on:
///   - Backspace or Delete next to a hidden code steps over it and takes the
///     next letter you can see;
///   - a style left with no words in it ("[fx=nod][/fx]", "****") goes, so
///     erasing a styled word takes its codes with it;
///   - what is left of a code a selection cut through goes too, and so does
///     the partner of a code that lost its other half.
/// With the codes showing it does nothing: they are being edited by hand.
class ChatCodeEraser extends TextInputFormatter {
  ChatCodeEraser();

  /// Every code in [text], paired or not: [fx=nod], [/color], **, __, ~~.
  static final RegExp _code = RegExp(
      r'\[/?(?:color|font|size|fx)(?:=[^\]\[]*)?\]|\*+|_{2,}|~{2,}');

  /// A style with nothing between its codes: an emptied [tag][/tag], bold
  /// (****), bold italic (******), underline (____) or strike (~~~~). An
  /// emptied italic is "**", which cannot be told from bold's own code, so
  /// it is left.
  static final RegExp _empty = RegExp(
      r'\[(color|font|size|fx)=[^\]\[]*\]\[/\1\]'
      r'|(?<!\*)(?:\*{6}|\*{4})(?!\*)|(?<!_)_{4}(?!_)|(?<!~)~{4}(?!~)');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (!ChatFormatController.hideMarkers.value) return newValue;
    final was = oldValue.text, now = newValue.text;
    if (now.length >= was.length) return newValue;

    // The span taken out: the common start, then the common end.
    var start = 0;
    while (start < now.length && was[start] == now[start]) {
      start++;
    }
    var endWas = was.length, endNow = now.length;
    while (endNow > start &&
        endWas > start &&
        was[endWas - 1] == now[endNow - 1]) {
      endWas--;
      endNow--;
    }
    if (endNow != start) return newValue; // a replace, not an erase

    var text = now;
    var caret = start;

    // Only code characters went (a backspace into a hidden code): put them
    // back and take the nearest letter you can see instead.
    final codes = [for (final m in _code.allMatches(was)) (m.start, m.end)];
    bool inCode(int i) => codes.any((c) => i >= c.$1 && i < c.$2);
    var onlyCode = true;
    for (var i = start; i < endWas; i++) {
      if (!inCode(i)) {
        onlyCode = false;
        break;
      }
    }
    if (onlyCode && endWas - start == 1) {
      final backspace = oldValue.selection.isCollapsed &&
          oldValue.selection.baseOffset == endWas;
      if (backspace) {
        var i = start - 1;
        while (i >= 0 && inCode(i)) {
          i--;
        }
        if (i < 0) return oldValue; // nothing to take but codes
        text = was.substring(0, i) + was.substring(i + 1);
        // The caret stays after the codes it was after, one letter less.
        caret = oldValue.selection.baseOffset - 1;
      } else {
        var i = endWas;
        while (i < was.length && inCode(i)) {
          i++;
        }
        if (i >= was.length) return oldValue;
        text = was.substring(0, i) + was.substring(i + 1);
        caret = start;
      }
    }

    final tidied = tidy(text, caret);
    return TextEditingValue(
      text: tidied.$1,
      selection: TextSelection.collapsed(offset: tidied.$2),
    );
  }

  /// [text] with empty styles, cut codes and lone halves taken out, and
  /// [caret] moved to match.
  static (String, int) tidy(String text, int caret) {
    String drop(String t, int a, int b) {
      if (caret > a) caret -= (caret < b ? caret - a : b - a);
      return t.substring(0, a) + t.substring(b);
    }

    var t = text;
    // A piece of a [code] a selection cut through: "[/f", "fx=nod]".
    for (;;) {
      final cut = RegExp(
              r'\[/?(?:c(?:o(?:l(?:or?)?)?)?|f(?:o(?:nt?)?|x)?|s(?:i(?:ze?)?)?)'
              r'(?:=[^\]\[\s]*)?(?=[^\]a-z=]|$)'
              r'|(?<=^|[^\[a-z/])/?(?:color|font|size|fx)(?:=[^\]\[\s]*)?\]')
          .firstMatch(t);
      if (cut == null) break;
      t = drop(t, cut.start, cut.end);
    }
    for (;;) {
      final m = _empty.firstMatch(t);
      if (m == null) break;
      t = drop(t, m.start, m.end);
    }
    // A code whose partner is gone: an [fx=..] with no [/fx] after it, or
    // a [/fx] with none open.
    for (;;) {
      final open = <String, List<RegExpMatch>>{};
      RegExpMatch? lone;
      for (final m in RegExp(r'\[(/?)(color|font|size|fx)(?:=[^\]\[]*)?\]')
          .allMatches(t)) {
        final kind = m[2]!;
        if (m[1]!.isEmpty) {
          (open[kind] ??= []).add(m);
        } else if ((open[kind] ?? const []).isNotEmpty) {
          open[kind]!.removeLast();
        } else {
          lone = m;
          break;
        }
      }
      lone ??= open.values.expand((l) => l).firstOrNull;
      if (lone == null) break;
      t = drop(t, lone.start, lone.end);
    }
    return (t, caret.clamp(0, t.length));
  }
}
