import 'package:flutter/material.dart';

import 'help_content.dart';

/// ============================================================================
///  THE HELP BOOK, ON SCREEN
/// ============================================================================
///  Opened over whatever you were doing and closed again without losing it, so
///  the answer arrives beside the question rather than in another window.
///
///  IT OPENS ON THE SEARCH BOX. Nobody opens help to browse a contents page;
///  they open it because a specific control did something they did not expect,
///  and the words they have are the words off that control. Typing starts
///  narrowing immediately, over the whole book - titles, sections, where each
///  feature lives, its keywords and its prose - so "RFQ", "RYG", "MSRP" and
///  "who installs it" all land somewhere useful. See [searchHelp].
///
///  A LIST AND A PAGE, not an accordion. The left is every topic that matches,
///  the right is the one being read, and moving between them never loses the
///  search - which is the whole shape of "I am not sure which of these three it
///  is".
///
///  NARROW WINDOWS GET ONE COLUMN. A laptop with the side pane out is not wide
///  enough for both, and a two-column layout squeezed into it is two columns of
///  ellipsis. Under the breakpoint the list becomes the page and picking a
///  topic pushes it, with the way back where a back button always is.
/// ============================================================================

/// Opens the help book. [initialQuery] seeds the search - a caller that knows
/// what somebody was looking at can hand the reader a head start.
Future<void> showHelpBook(BuildContext context, {String initialQuery = ''}) =>
    showDialog<void>(
      context: context,
      builder: (_) => HelpBookDialog(initialQuery: initialQuery),
    );

class HelpBookDialog extends StatelessWidget {
  final String initialQuery;

  const HelpBookDialog({super.key, this.initialQuery = ''});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      key: const ValueKey('help_book'),
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1180,
          maxHeight: size.height * 0.92,
        ),
        child: HelpBook(initialQuery: initialQuery),
      ),
    );
  }
}

/// The book itself, without the dialog around it — so a tab could host it.
class HelpBook extends StatefulWidget {
  final String initialQuery;

  const HelpBook({super.key, this.initialQuery = ''});

  @override
  State<HelpBook> createState() => _HelpBookState();
}

class _HelpBookState extends State<HelpBook> {
  late final TextEditingController _search = TextEditingController(
    text: widget.initialQuery,
  );
  final FocusNode _searchFocus = FocusNode();

  /// The topic being read. Held by TITLE rather than by index, because the
  /// list under it is re-ranked on every keystroke and an index would point at
  /// a different topic a letter later.
  String _reading = '';

  /// Whether the narrow layout is showing the page rather than the list.
  bool _onPage = false;

  @override
  void initState() {
    super.initState();
    // Straight into the box. Nobody opens help to browse a contents page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<HelpTopic> get _matches => searchHelp(_search.text);

  HelpTopic? get _current {
    final hits = _matches;
    if (hits.isEmpty) return null;
    for (final t in hits) {
      if (t.title == _reading) return t;
    }
    // The topic being read has dropped out of the results, which happens on
    // every keystroke that narrows past it. The best remaining hit is a better
    // answer than a blank page.
    return hits.first;
  }

  void _open(HelpTopic topic) => setState(() {
    _reading = topic.title;
    _onPage = true;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hits = _matches;
    final current = _current;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(
            children: [
              if (!wide && _onPage)
                IconButton(
                  key: const ValueKey('help_back'),
                  tooltip: 'Back to the list',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _onPage = false),
                ),
              Icon(Icons.help_outline, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Help', style: theme.textTheme.titleMedium),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  key: const ValueKey('help_search'),
                  controller: _search,
                  focusNode: _searchFocus,
                  // ESCAPE CLOSES THE BOOK, from inside the box. A dialog whose
                  // search field swallows Escape is a dialog somebody has to
                  // reach for the mouse to leave.
                  onChanged: (_) => setState(() => _onPage = false),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search every feature - "vendor", "RFQ", '
                        '"lead time", "who installs it"',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            key: const ValueKey('help_search_clear'),
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() {
                              _search.clear();
                              _onPage = false;
                            }),
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const ValueKey('help_close'),
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _search.text.trim().isEmpty
                  ? '${kHelpTopics.length} features across '
                        '${helpSections.length} parts of the app'
                  : hits.isEmpty
                  ? 'Nothing matches "${_search.text.trim()}". Every word has '
                        'to appear somewhere - try one of them on its own.'
                  : '${hits.length} '
                        '${hits.length == 1 ? 'feature' : 'features'} match '
                        '"${_search.text.trim()}"',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 320, child: _list(theme, hits, current)),
                    const VerticalDivider(width: 1),
                    Expanded(child: _page(theme, current)),
                  ],
                )
              : _onPage
              ? _page(theme, current)
              : _list(theme, hits, current),
        ),
      ],
    );
  }

  /// Everything that matches, under its section heading.
  ///
  /// GROUPED ONLY WHEN THERE IS NOTHING TYPED. A search is already an ordering
  /// - best first - and chopping it back into sections would put the second
  /// best answer three headings down.
  Widget _list(ThemeData theme, List<HelpTopic> hits, HelpTopic? current) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final grouped = _search.text.trim().isEmpty;

    final rows = <Widget>[];
    var section = '';
    for (final topic in hits) {
      if (grouped && topic.section != section) {
        section = topic.section;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              section.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: muted,
              ),
            ),
          ),
        );
      }
      final selected = current != null && current.title == topic.title;
      rows.add(
        ListTile(
          key: ValueKey('help_topic_${topic.title}'),
          dense: true,
          selected: selected,
          title: Text(topic.title),
          subtitle: grouped
              ? null
              // With something typed there are no headings, so each row has to
              // say where it belongs on its own.
              : Text(
                  topic.section,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
          onTap: () => _open(topic),
        ),
      );
    }

    return ListView(children: rows);
  }

  /// The topic being read.
  Widget _page(ThemeData theme, HelpTopic? topic) {
    if (topic == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing matches that.\n\n'
            'Every word you type has to appear somewhere in a feature, so a '
            'long phrase narrows fast. Try the word off the button you are '
            'looking at.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      key: ValueKey('help_page_${topic.title}'),
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            topic.section.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            topic.title,
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          // WHERE IT IS. The first thing somebody wants off a help page is how
          // to get to the thing, and a page that opens with three paragraphs
          // of rationale has buried it.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.my_location,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    topic.where,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // SELECTABLE, because half of what help is used for is pasting a
          // sentence of it into an email to somebody who asked.
          for (final paragraph in topic.body.split('\n\n'))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(
                paragraph,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
          if (topic.keywords.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final k in topic.keywords)
                  // A press searches it, which is how somebody gets from one
                  // topic to its neighbors without knowing what they are
                  // called.
                  ActionChip(
                    key: ValueKey('help_keyword_${topic.title}_$k'),
                    visualDensity: VisualDensity.compact,
                    label: Text(k),
                    onPressed: () => setState(() {
                      _search.text = k;
                      _onPage = false;
                    }),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The F1-and-a-question-mark button that opens the book.
///
/// ON THE TITLE BAR, beside the gear, because help is a property of the app
/// rather than of whichever tab is open - and a help button that moves with the
/// tab is one somebody hunts for.
class HelpButton extends StatelessWidget {
  const HelpButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('open_help'),
    // No color of its own: it takes the ink of the bar it is on, like every
    // other button up there. It used to be painted the accent beside the gear,
    // which made the two of them the loudest things in a row they are not the
    // most important part of.
    icon: const Icon(Icons.help_outline),
    tooltip: 'Help - every feature, searchable (F1)',
    onPressed: () => showHelpBook(context),
  );
}
