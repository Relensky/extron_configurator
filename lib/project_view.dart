import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_swap_dialogs.dart' show pickCatalogModel;
import 'building_project.dart';
import 'contrast.dart';
import 'cost_estimate.dart';
import 'live_text_field.dart';
import 'project_briefing_dialog.dart';
import 'project_estimate.dart';
import 'project_lifecycle_view.dart';
import 'project_notes_view.dart';
import 'project_plans_view.dart';
import 'project_pricing.dart';
import 'project_responsibility_view.dart';
import 'project_room_picker.dart';
import 'project_schedule.dart';
import 'project_spares_view.dart';
import 'project_swap.dart';
import 'project_todo_view.dart';
import 'project_timeline_view.dart';
import 'project_workbook.dart';
import 'workbook_export.dart' show exportProjectWorkbook;

/// ============================================================================
///  THE PROJECT TAB
/// ============================================================================
///  A building, quoted as one job. Three panes behind one header:
///
///    ROOMS   — which configs are on the job, what each one costs, and the
///              building total they add up to.
///    PARTS   — every part once, quantities merged across rooms, tagged to the
///              vendor that will quote it. The tagging happens here because
///              this is the only screen where the whole order is visible at
///              once: "who sells this" is a question about a part, not about
///              a room, and answering it nine times per part was the thing
///              this feature exists to stop.
///    VENDORS — the companies and the rules that tag parts to them.
///
///  THE HEADER IS ALWAYS THE TOTAL. Whichever pane is open, the figure at the
///  top is what the building costs, because that is the number somebody came
///  to this tab for and it should never require navigating to.
///
///  NOTHING HERE EDITS A ROOM. The project points at room files; it does not
///  own them. A price that is wrong is fixed on that room's own Cost tab, and
///  Refresh picks it up. That boundary is deliberate — a screen that could
///  edit nine rooms at once is a screen that can damage nine rooms at once,
///  and the rooms are the documents that took the work.
/// ============================================================================

/// Which pane is showing.
enum _ProjectPane {
  rooms('Rooms', Icons.meeting_room),
  // EQUIPMENT, not "core components". The list is every piece of kit the job
  // buys, once, with the quantities merged across rooms - and "equipment" is
  // what everybody standing in front of it calls that. The name it had was the
  // internal one for the merged-part key, which is not a thing anybody outside
  // this code has to know about. The workbook's sheet keeps its own name; it
  // has been going out to vendors under it.
  parts('Equipment', Icons.inventory_2),
  // The drawings the job is quoted against - next to the rooms because that
  // is what they are about, and before the money because they are what the
  // money was worked out from.
  plans('Plans', Icons.architecture),
  timeline('Timeline', Icons.event_available),
  // What the building already HAS and when it falls due - next to the
  // timeline, because both are the job read as a calendar: one for the work
  // being quoted, one for the work after it.
  lifecycle('Lifecycle', Icons.history_toggle_off),
  // Whose job each piece of scope is. After the money and the calendar,
  // because it is the document that gets agreed once the job is real.
  responsibility('Responsibility', Icons.handshake_outlined),
  vendors('Vendors', Icons.local_shipping),
  todo('To do', Icons.checklist),
  notes('Notes', Icons.sticky_note_2_outlined);

  final String label;
  final IconData icon;
  const _ProjectPane(this.label, this.icon);
}

/// Below this the header stops trying to fit everything side by side: the
/// identity fields stack and the buttons drop their labels.
///
/// Measured from what the fields need rather than picked off a device list.
/// The two short codes take 160 and 140, the gaps and the page padding take
/// another 56, and what is left has to hold two PROSE fields - the job's name
/// and who it is for - at a width where each is a field rather than a slot.
///
/// Public so the layout tests can ask which side of it they are on instead of
/// carrying a second copy of the number that drifts from this one.
const double kProjectHeaderCompactWidth = 1040;

/// How much weight a header action carries. The two exports are what the tab
/// is for and are drawn as such; the file actions are not.
enum _ActionEmphasis { plain, tonal, filled }

class ProjectView extends StatefulWidget {
  const ProjectView({super.key});

  @override
  State<ProjectView> createState() => _ProjectViewState();
}

class _ProjectViewState extends State<ProjectView> {
  _ProjectPane _pane = _ProjectPane.rooms;

  /// Master-list filter: '' for everything, otherwise a vendor id, or the
  /// sentinel below for the parts nothing claimed.
  String _vendorFilter = '';

  /// Not a vendor id: ids are always `vendor<n>`, so this can never be one
  /// by accident.
  static const String _untaggedFilter = '<untagged>';

  /// Same idea, for the parts nothing will drive.
  static const String _undrivenFilter = '<no-module>';

  /// Parts nothing anywhere has a price for. Reached by pressing the warning
  /// in the header, which is where somebody first learns they exist.
  static const String _unpricedFilter = '<unpriced>';

  /// Which room's spares the master list is narrowed to, '' for every room's.
  ///
  /// A second filter rather than another value of [_vendorFilter], because it
  /// is a narrowing of that one and not an alternative to it: "the spares" and
  /// "BSS 103's spares" are the same question asked at two depths, and a
  /// single filter could not hold both at once. It only means anything while
  /// the Spared chip is on, and is dropped the moment that chip goes off —
  /// see [_setVendorFilter].
  String _spareRoom = '';

  String _search = '';

  /// One controller for the whole tab, so the scrollbar has something to drag
  /// and switching panes can put the view back at the top — landing halfway
  /// down a different list is disorienting.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _showPane(_ProjectPane pane) {
    setState(() => _pane = pane);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Switches the master list's filter, dropping the room narrowing with it.
  ///
  /// The room only qualifies the spares chip. Left set behind a switch to
  /// Vendor A it would be an invisible filter — a list quietly missing rows,
  /// with nothing on screen saying why.
  void _setVendorFilter(String value) => setState(() {
    _vendorFilter = value;
    if (value != kSparedFilter) _spareRoom = '';
  });

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(message),
        backgroundColor: error ? snackErrorFill(context) : null,
      ),
    );
  }

  // -------------------------------------------------------------------------
  //  FILE ACTIONS
  // -------------------------------------------------------------------------

  // NEW / OPEN / SAVE / CLOSE ARE NOT ON THIS TAB.
  //
  // They live in save_actions.dart, driven from the title bar's New menu, its
  // Open button and its Save, and from the banner's Close. This tab used to
  // offer its own four beside them, which meant two Saves on one screen — and
  // the one here could only ever write the job, while the one up there writes
  // whichever document the tab you are standing on belongs to.

  // -------------------------------------------------------------------------
  //  EXPORTS
  // -------------------------------------------------------------------------

  /// The tab's own Workbook button.
  ///
  /// Forwards to the shared flow rather than writing the file here: the
  /// toolbar can produce the same book from any tab now, and two writers would
  /// mean two file names and two chances for the sheets to drift.
  Future<void> _exportWorkbook(
    AppStateProvider provider,
    ProjectEstimate estimate,
  ) => exportProjectWorkbook(context, provider);

  /// One .xlsx per vendor, into a folder the user picks.
  ///
  /// A folder rather than a file, because the whole point is that these are
  /// several documents going to several companies. Writing them one at a time
  /// through six save dialogs would be the same work the feature is supposed
  /// to remove.
  Future<void> _exportRfqs(
    AppStateProvider provider,
    ProjectEstimate estimate,
  ) async {
    final packages = [
      for (final p in estimate.vendors)
        if (!p.isUntagged) p,
    ];
    if (packages.isEmpty) {
      _snack(
        estimate.master.isEmpty
            ? 'Nothing on the master list yet.'
            : 'No parts are tagged to a vendor yet - set up a vendor rule or '
                  'tag some parts, and each vendor gets a file.',
      );
      return;
    }

    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Where should the quote requests go?',
    );
    if (folder == null) return;

    final written = <String>[];
    final failed = <String>[];
    for (final package in packages) {
      final name = '${vendorRfqFileStem(provider.project, package)}.xlsx';
      try {
        await File(path.join(folder, name)).writeAsBytes(
          buildVendorRfqBytes(estimate: estimate, package: package),
        );
        written.add(name);
      } catch (e) {
        failed.add('$name - $e');
      }
    }

    if (!mounted) return;
    if (written.isEmpty) {
      _snack(
        'No quote requests were written: ${failed.join('; ')}',
        error: true,
      );
      return;
    }
    showSavedSnackBar(
      messenger: ScaffoldMessenger.of(context),
      theme: Theme.of(context),
      provider: provider,
      message: failed.isEmpty
          ? '${written.length} quote request'
                '${written.length == 1 ? '' : 's'} written'
          : '${written.length} written, ${failed.length} failed '
                '(${failed.first})',
      savedPath: folder,
      isFolder: true,
    );
  }

  // -------------------------------------------------------------------------
  //  BUILD
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final estimate = provider.priceProject();

    // ONE SCROLL REGION FOR THE WHOLE TAB.
    //
    // It used to be two: a header that scrolled inside itself when the window
    // was short, above a list that scrolled on its own. That put a scrollbar
    // inside a scrollbar — two thumbs on screen at once, neither of them
    // moving the thing you were looking at — and it meant the building total
    // at the foot of the room list could only be reached by scrolling the
    // inner one while the outer one sat still.
    //
    // Slivers rather than a Column in a SingleChildScrollView, so the rows are
    // still built lazily: a building with two hundred parts on its master list
    // should not lay out two hundred cards to show the first six.
    return Scrollbar(
      controller: _scroll,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(child: _header(context, provider, estimate)),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          ...switch (_pane) {
            _ProjectPane.rooms => roomsSlivers(context, estimate),
            _ProjectPane.parts => partsSlivers(
              context,
              estimate: estimate,
              vendorFilter: _vendorFilter,
              untaggedFilter: _untaggedFilter,
              undrivenFilter: _undrivenFilter,
              unpricedFilter: _unpricedFilter,
              spareRoom: _spareRoom,
              search: _search,
              onVendorFilter: _setVendorFilter,
              onSpareRoom: (id) => setState(() => _spareRoom = id),
              onSearch: (s) => setState(() => _search = s),
            ),
            _ProjectPane.plans => plansSlivers(context, estimate),
            _ProjectPane.timeline => timelineSlivers(context, estimate),
            _ProjectPane.lifecycle => lifecycleSlivers(context, estimate),
            _ProjectPane.responsibility =>
              responsibilitySlivers(context, estimate),
            _ProjectPane.vendors => vendorsSlivers(context, estimate),
            _ProjectPane.todo => todoSlivers(context, estimate),
            _ProjectPane.notes => notesSlivers(context, estimate),
          },
        ],
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AppStateProvider provider,
    ProjectEstimate estimate,
  ) {
    final theme = Theme.of(context);
    final warnings =
        estimate.failedRooms +
        estimate.unpricedParts +
        (estimate.mixedCurrency ? 1 : 0);
    final openTodos = provider.project.openTodos.length;

    // THE HEADER GIVES WAY BEFORE THE CONTROLS DO. On a window narrow enough
    // that the title strip and the buttons cannot both have their full size,
    // it is the TITLE that has to shrink: a project name is a field somebody
    // typed once and reads at a glance, and the buttons are the reason the
    // header exists at all. Before this the name kept its whole row and the
    // actions were squeezed until Quote requests sat half off the edge, which
    // is a button that cannot be pressed on a screen with plenty of room left
    // on it.
    return LayoutBuilder(builder: (context, box) {
    final compact = box.maxWidth < kProjectHeaderCompactWidth;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // THE TOP ROW IS WHAT YOU DO TO THE JOB, SPLIT BY WHICH WAY IT
          // FACES.
          //
          // New, Open, Save and Close are gone from here. They are file
          // actions, and file actions now live in one place - the title bar,
          // where New, Open and Save sit together on every other application
          // on the machine. Two Saves on one screen is one Save too many, and
          // the one that was here could only ever write the job while the one
          // up there writes whatever tab you are standing on.
          //
          // What is left is the two things you do TO the job (re-read it, ask
          // where it stands) on the LEFT, under the name they are about, and
          // the two things you get OUT of it on the right. Reading order:
          // check it, then send it.
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _action(
                    compact: compact,
                    buttonKey: const ValueKey('project_refresh'),
                    icon: Icons.refresh,
                    label: 'Refresh',
                    onPressed: () {
                      provider.refreshProjectRooms();
                      _snack('Re-read every room from disk.');
                    },
                  ),
                  // The same summary a project shows on the way in. Reachable
                  // on purpose: it is shown once on open and only when
                  // something is time-critical, and "what was that list again"
                  // is asked five minutes later.
                  _action(
                    compact: compact,
                    buttonKey: const ValueKey('project_briefing_button'),
                    icon: Icons.flag_outlined,
                    label: 'Where it stands',
                    onPressed: () =>
                        showProjectBriefing(context, provider, force: true),
                  ),
                ],
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _action(
                    compact: compact,
                    icon: Icons.table_view,
                    label: 'Workbook',
                    emphasis: _ActionEmphasis.tonal,
                    onPressed: () => _exportWorkbook(provider, estimate),
                  ),
                  _action(
                    compact: compact,
                    icon: Icons.send_outlined,
                    label: 'Quote requests',
                    emphasis: _ActionEmphasis.filled,
                    onPressed: () => _exportRfqs(provider, estimate),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          _identity(provider, compact: compact),
          const SizedBox(height: 10),
          // A Wrap rather than a Row: the strip is five items of text whose
          // width is whatever the figures happen to be, and a project total in
          // the millions on a laptop would otherwise push the last chip off
          // the edge under an overflow stripe.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // The number the tab exists for, at the size it deserves.
              _TotalChip(
                label: 'Project total',
                value: formatMoney(estimate.grandTotal, estimate.currency),
                emphasis: true,
              ),
              _TotalChip(
                label: 'Parts',
                value: formatMoney(estimate.partsTotal, estimate.currency),
              ),
              _TotalChip(
                label: 'Labor',
                value:
                    '${formatMoney(estimate.laborTotal, estimate.currency)}'
                    '  ·  ${trimNumber(estimate.laborHours)} hrs',
              ),
              _TotalChip(
                // Not just 'Rooms': the panes below are named Rooms too, and
                // one word meaning two things on one screen is a screen that
                // has to be read twice.
                label: 'Rooms priced',
                value:
                    '${estimate.costedRooms.length} of '
                    '${estimate.rooms.length}',
              ),
              if (warnings > 0)
                Tooltip(
                  message: estimate.unpricedParts > 0
                      ? '${_warningTooltip(estimate)}'
                          '\n\nClick to list the parts with no price.'
                      : _warningTooltip(estimate),
                  // AN ACTION, not a label. A count of things to check that
                  // cannot be pressed leaves somebody hunting through a parts
                  // list for the three rows it is talking about; pressing it
                  // shows exactly those rows.
                  child: ActionChip(
                    key: const ValueKey('project_warnings'),
                    avatar: Icon(
                      Icons.warning_amber,
                      size: 18,
                      color: foregroundOn(
                        theme.colorScheme,
                        theme.colorScheme.errorContainer,
                      ),
                    ),
                    label: Text(
                      '$warnings to check',
                      style: TextStyle(
                        color: foregroundOn(
                          theme.colorScheme,
                          theme.colorScheme.errorContainer,
                        ),
                      ),
                    ),
                    backgroundColor: theme.colorScheme.errorContainer,
                    onPressed: estimate.unpricedParts > 0
                        ? () => setState(() {
                              _pane = _ProjectPane.parts;
                              _vendorFilter = _unpricedFilter;
                              _search = '';
                            })
                        : null,
                  ),
                ),
              // The date the building has to be finished by, beside the money
              // rather than buried in the timeline pane — it is the one figure
              // on this tab that every other date is derived from, and a
              // deadline nobody can see from the top of the screen is a
              // deadline nobody sets.
              DeadlineChip(estimate: estimate),
              if (provider.projectDirty)
                Text(
                  'Unsaved',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: errorTextOn(theme.colorScheme, theme.cardColor),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // The pane switcher on its own line now that the file actions have
          // gone up to the top of the tab. Still a Wrap rather than a bare
          // button: it keeps its natural width instead of being stretched to
          // the header's, and a switcher that has grown an eighth pane drops
          // onto a second line on a narrow window rather than overflowing it.
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<_ProjectPane>(
                segments: [
                  for (final pane in _ProjectPane.values)
                    ButtonSegment(
                      value: pane,
                      icon: Icon(pane.icon, size: 18),
                      // The label goes when the window cannot hold all of
                      // them. Eight labelled segments are wider than a narrow
                      // window on their own, and a switcher that overflows is
                      // a pane nobody can reach — the icons are the same eight
                      // targets, in the same order, with the name on a
                      // tooltip.
                      tooltip: compact
                          ? (pane == _ProjectPane.todo && openTodos > 0
                              ? '${pane.label} ($openTodos open)'
                              : pane.label)
                          : null,
                      // The open count rides on the tab itself. A to-do list
                      // that has to be opened to find out whether it has
                      // anything on it is one nobody opens.
                      // Keyed: a pane's LABEL is not a unique thing to find
                      // by any more — 'Notes' is also a column on the room
                      // list — and a test that taps the wrong one of three
                      // matches is a test that fails for the wrong reason.
                      label: compact
                          ? null
                          : Text(
                              pane == _ProjectPane.todo && openTodos > 0
                                  ? '${pane.label} ($openTodos)'
                                  : pane.label,
                              key: ValueKey('project_pane_${pane.name}'),
                            ),
                    ),
                ],
                selected: {_pane},
                onSelectionChanged: (s) => _showPane(s.first),
                // With the labels gone the icon IS the pane, so the selected
                // one must keep it. The default swaps in a tick, which on a
                // labelled switcher marks the choice and on this one erases
                // the only thing naming it.
                showSelectedIcon: !compact,
              ),
            ],
          ),
        ],
      ),
    );
    });
  }

  /// One file or export action, labelled while there is room for the label.
  ///
  /// COMPACT IS ICON-ONLY, not a smaller label and not an overflow menu. Eight
  /// labelled buttons need most of a wide window; on a narrow one they wrapped
  /// onto a third line and pushed the last of them past the edge, which is how
  /// Quote requests became a button nobody could press. As icons all eight
  /// stay on one line, in the same order, in the same place — and the label
  /// they lose comes back as the tooltip, which is where the name of a control
  /// somebody uses twice a week belongs anyway.
  ///
  /// An overflow menu was the other option and is worse: it would hide exactly
  /// the two buttons this tab exists to produce, and hide them only on the
  /// small screens where hunting through a menu costs the most.
  Widget _action({
    required bool compact,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Key? buttonKey,
    _ActionEmphasis emphasis = _ActionEmphasis.plain,
  }) {
    final glyph = Icon(icon, size: 18);
    if (compact) {
      return switch (emphasis) {
        _ActionEmphasis.plain => IconButton(
          key: buttonKey,
          tooltip: label,
          onPressed: onPressed,
          icon: glyph,
        ),
        _ActionEmphasis.tonal => IconButton.filledTonal(
          key: buttonKey,
          tooltip: label,
          onPressed: onPressed,
          icon: glyph,
        ),
        _ActionEmphasis.filled => IconButton.filled(
          key: buttonKey,
          tooltip: label,
          onPressed: onPressed,
          icon: glyph,
        ),
      };
    }

    final text = Text(label);
    return switch (emphasis) {
      _ActionEmphasis.plain => TextButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: glyph,
        label: text,
      ),
      _ActionEmphasis.tonal => FilledButton.tonalIcon(
        key: buttonKey,
        onPressed: onPressed,
        icon: glyph,
        label: text,
      ),
      _ActionEmphasis.filled => FilledButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: glyph,
        label: text,
      ),
    };
  }

  /// The project's name, building and job number.
  ///
  /// Side by side while there is room, stacked when there is not: the name is
  /// the wide one and the other two are short codes, so a narrow window keeps
  /// a usable name field by giving the codes a line of their own rather than
  /// by shaving every field down to a few characters each.
  Widget _identity(AppStateProvider provider, {required bool compact}) {
    final name = LiveTextField(
      fieldId: 'project_name_${provider.currentProjectPath}',
      initial: provider.project.name,
      label: 'Project',
      hint: 'Bessey Hall AV refresh',
      onChanged: (v) => provider.setProjectField(name: v),
    );
    final building = LiveTextField(
      fieldId: 'project_bldg_${provider.currentProjectPath}',
      initial: provider.project.building,
      label: 'Building',
      onChanged: (v) => provider.setProjectField(building: v),
    );
    final job = LiveTextField(
      fieldId: 'project_job_${provider.currentProjectPath}',
      initial: provider.project.jobNumber,
      label: 'Job number',
      onChanged: (v) => provider.setProjectField(jobNumber: v),
    );
    // WHO THE JOB IS FOR, beside what it is called. It goes out on the
    // workbook's first sheet and on every quote request, and until it was here
    // the only way to set it was through the API - a field on a document
    // nobody could fill in.
    //
    // Second rather than last: it is prose like the name, and the two short
    // codes belong together at the end. Put last, a narrow window would strand
    // a full-width prose field underneath a row of two codes.
    final stakeholder = LiveTextField(
      fieldId: 'project_stakeholder_${provider.currentProjectPath}',
      initial: provider.project.stakeholder,
      label: 'Stakeholder',
      hint: 'Physics department',
      onChanged: (v) => provider.setProjectField(stakeholder: v),
    );

    if (!compact) {
      return Row(
        children: [
          // The name gets the larger share: it is the longest of the four and
          // the one every other screen refers back to.
          Expanded(flex: 3, child: name),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: stakeholder),
          const SizedBox(width: 8),
          SizedBox(width: 160, child: building),
          const SizedBox(width: 8),
          SizedBox(width: 140, child: job),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        name,
        const SizedBox(height: 8),
        stakeholder,
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: building),
            const SizedBox(width: 8),
            Expanded(child: job),
          ],
        ),
      ],
    );
  }

  String _warningTooltip(ProjectEstimate estimate) => [
    if (estimate.failedRooms > 0)
      '${estimate.failedRooms} room(s) could not be read - the total is short.',
    if (estimate.unpricedParts > 0)
      '${estimate.unpricedParts} part(s) have no price anywhere.',
    if (estimate.undrivenDevices > 0)
      '${estimate.undrivenDevices} device(s) have no control module - quoted, '
          'but they will not commission as they stand.',
    if (estimate.mixedCurrency)
      'Rooms are quoted in different currencies and are being added anyway.',
  ].join('\n');
}

//// Puts a price on a part from the parts list, either way.
///
/// Two buttons rather than a checkbox, because they are two different
/// decisions and the wrong one is not obviously wrong afterwards:
///
///   * SAVE TO CATALOG is for a part that simply had no price on file. It is a
///     fact about the product; every room and every future job gets it.
///   * PRICE ON THIS JOB is for a figure that was negotiated. The catalog goes
///     on saying list price and this job says what was agreed.
///
/// The rooms it would touch are named before either button is pressed, because
/// "this writes nine files" is not something to discover afterwards.
Future<void> showPartPriceDialog(
  BuildContext context,
  AppStateProvider provider,
  MasterPartLine line,
  String currency,
) async {
  final rooms = roomsCarrying(provider, line);
  final controller = TextEditingController(
    text: line.unpriced ? '' : trimNumber(line.unitPrice),
  );
  final messenger = ScaffoldMessenger.of(context);

  final answer = await showDialog<String>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          final price = double.tryParse(controller.text.trim()) ?? 0;
          final valid = price > 0;
          final hasModel = line.model.trim().isNotEmpty;

          return AlertDialog(
            key: const ValueKey('part_price_dialog'),
            title: Text(
              line.model.trim().isEmpty ? line.description : line.model.trim(),
            ),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.description, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('part_price_field'),
                    controller: controller,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Unit price',
                      prefixText: currency,
                      border: const OutlineInputBorder(),
                      helperText:
                          '${trimNumber(line.qty)} on this job, across '
                          '${rooms.length} room${rooms.length == 1 ? '' : 's'}',
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    rooms.isEmpty
                        ? 'No room on this project carries this part.'
                        : 'Pricing it on this job writes '
                            '${rooms.length == 1 ? 'one room' : '${rooms.length} rooms'}: '
                            '${rooms.join(', ')}.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (!hasModel) ...[
                    const SizedBox(height: 8),
                    Text(
                      'This part has no model, so the catalog has nothing to '
                      'file a price under - only the job price is available.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: errorTextOn(theme.colorScheme,
                            theme.dialogTheme.backgroundColor ??
                                theme.colorScheme.surface),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('price_this_job'),
                onPressed: valid && rooms.isNotEmpty
                    ? () => Navigator.pop(ctx, 'job')
                    : null,
                child: const Text('Price on this job only'),
              ),
              FilledButton(
                key: const ValueKey('price_to_catalog'),
                onPressed:
                    valid && hasModel ? () => Navigator.pop(ctx, 'catalog') : null,
                child: const Text('Save to catalog'),
              ),
            ],
          );
        },
      );
    },
  );

  final price = double.tryParse(controller.text.trim()) ?? 0;
  controller.dispose();
  if (answer == null || answer == 'cancel' || price <= 0) return;

  if (answer == 'catalog') {
    final saved =
        await priceInCatalog(provider: provider, line: line, price: price);
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          saved.startsWith('Error')
              ? saved
              : '${line.model} priced at ${formatMoney(price, currency)} in '
                  'the catalog. Every room prices from it.',
        ),
        backgroundColor:
            saved.startsWith('Error') ? snackErrorFillOn(messenger) : null,
      ),
    );
    return;
  }

  final result =
      await priceAcrossProject(provider: provider, line: line, price: price);
  final parts = [
    if (result.roomsWritten > 0)
      '${result.roomsWritten} room'
          '${result.roomsWritten == 1 ? '' : 's'} written',
    if (result.openRoomChanged)
      'the open room changed on screen - save it to keep the price',
    if (result.failures.isNotEmpty)
      '${result.failures.length} could not be written: '
          '${result.failures.join('; ')}',
  ];
  showTimedSnackBar(
    messenger,
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(
        '${line.description} priced at ${formatMoney(price, currency)} on this '
        'job - ${parts.join('; ')}.',
      ),
      backgroundColor:
          result.failures.isEmpty ? null : snackErrorFillOn(messenger),
    ),
  );
}

// A labelled figure in the header strip.
class _TotalChip extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasis;

  const _TotalChip({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // THE PROJECT TOTAL IS PAINTED ON THE USER'S ACCENT, so its ink cannot be
    // the page's ink.
    //
    // The emphasis chip fills with primaryContainer — which in the Classic
    // theme is derived from a colour somebody picks out of a wheel. The label
    // and the figure were being drawn in the text theme's default colour,
    // which is chosen for the PAGE behind them, not for this fill: pick a dark
    // accent and the one number the tab exists for went dark-on-dark. Measured
    // against the fill it is actually going on, so a dark accent gets white
    // and a light one gets black, with the scheme's own pairing preferred
    // whenever it genuinely reads.
    final fill = emphasis
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final ink = readableOn(
      fill,
      prefer: [
        emphasis ? scheme.onPrimaryContainer : scheme.onSurface,
        scheme.onSurface,
      ],
    );
    // The label is the quiet half, so it is allowed to be dimmer — but only as
    // far as its own contrast holds. Faded to 70% and re-measured rather than
    // assumed: 70% of an ink that only just cleared the threshold does not.
    final labelInk = readableOn(
      fill,
      prefer: [Color.alphaBlend(ink.withValues(alpha: 0.75), fill), ink],
      minRatio: kContrastLarge,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelSmall?.copyWith(
            color: labelInk,
          )),
          Text(
            value,
            style:
                (emphasis
                        ? theme.textTheme.titleLarge
                        : theme.textTheme.titleMedium)
                    ?.copyWith(fontWeight: FontWeight.bold, color: ink),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  ROOMS
// ---------------------------------------------------------------------------

/// The Rooms pane, as slivers for the tab's one scroll view.
List<Widget> roomsSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.read<AppStateProvider>();
  final theme = Theme.of(context);

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: () async {
                final picked = await FilePicker.pickFiles(
                  dialogTitle: 'Add room configs to the project',
                  type: FileType.custom,
                  allowedExtensions: const ['json'],
                  allowMultiple: true,
                );
                if (picked == null) return;
                final problems = <String>[];
                var added = 0;
                for (final f in picked.files) {
                  if (f.path == null) continue;
                  final error = provider.addRoomToProject(f.path!);
                  if (error.isEmpty) {
                    added++;
                  } else {
                    problems.add(error);
                  }
                }
                if (!context.mounted) return;
                showTimedSnackBar(
                  ScaffoldMessenger.of(context),
                  SnackBar(
                    duration: const Duration(seconds: 5),
                    content: Text(
                      problems.isEmpty
                          ? '$added room${added == 1 ? '' : 's'} added.'
                          : '$added added. ${problems.join(' ')}',
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add rooms…'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () {
                final error = provider.addCurrentRoomToProject();
                if (!context.mounted) return;
                showTimedSnackBar(
                  ScaffoldMessenger.of(context),
                  SnackBar(
                    duration: const Duration(seconds: 5),
                    content: Text(
                      error.isEmpty ? 'Added the open room.' : error,
                    ),
                    backgroundColor: error.isEmpty
                        ? null
                        : errorTextOn(Theme.of(context).colorScheme,
                            Theme.of(context).cardColor),
                  ),
                );
              },
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('Add the open room'),
            ),
            // Expanded, not a Spacer: the sentence is longer than the space
            // left beside two buttons on a laptop, and an unconstrained Text
            // simply runs off the edge.
            Expanded(
              child: Text(
                'Rooms are references. Fix a price on the room’s own Cost '
                'tab, then Refresh.',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    if (estimate.rooms.isEmpty)
      const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No rooms on this project yet.\n\n'
              'Add the config.json files for the rooms in this building and '
              'they will be priced together.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else ...[
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.separated(
          itemCount: estimate.rooms.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, index) => _RoomRow(
            room: estimate.rooms[index],
            currency: estimate.currency,
            isFirst: index == 0,
            isLast: index == estimate.rooms.length - 1,
          ),
        ),
      ),
      // Its own sliver rather than the last row of the list, so it is exactly
      // as tall as its contents and can never end up scrolling inside the
      // scroll it already sits in.
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverToBoxAdapter(child: _BuildingTotals(estimate: estimate)),
      ),
    ],
  ];
}

class _RoomRow extends StatefulWidget {
  final ProjectRoomCost room;
  final String currency;
  final bool isFirst;
  final bool isLast;

  const _RoomRow({
    required this.room,
    required this.currency,
    required this.isFirst,
    required this.isLast,
  });

  @override
  State<_RoomRow> createState() => _RoomRowState();
}

class _RoomRowState extends State<_RoomRow> {
  /// Whether the pointer is over the room's name.
  ///
  /// Stateful for one underline. A name that opens the room when you click it
  /// has to LOOK like it does — the whole reason this had to be asked for is
  /// that a row of plain text says nothing about being a way in — and a hover
  /// underline is the one affordance that costs no space on a row already
  /// carrying a checkbox, three figures and four buttons.
  bool _hoveringName = false;

  /// Makes this the room the editor is working on.
  ///
  /// Goes through the SAME prompt the picker in the title bar does: switching
  /// rooms reads the next room off disk, so anything unsaved in the one being
  /// left goes with it. Two doors into one action must not have two different
  /// answers to that question.
  Future<void> _open(AppStateProvider provider) async {
    if (!await confirmLeavingRoom(context, provider)) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final error = await provider.openProjectRoomRef(widget.room.ref);
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(
          error.isEmpty
              ? '${widget.room.name} is now the open room.'
              : error,
        ),
        backgroundColor: error.isEmpty ? null : snackErrorFillOn(messenger),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final currency = widget.currency;
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final e = room.estimate;
    final dimmed = !room.ref.included;
    final isOpen = provider.openProjectRoom?.id == room.ref.id;
    final unsaved = isOpen && provider.roomHasUnsavedChanges;

    // The card's fill changes with the row's state — primaryContainer when it
    // is the open room, errorContainer when it could not be read — so the ink
    // on it has to be chosen against THAT, not against the page. Painting
    // colorScheme.primary on primaryContainer measured 1.2:1 on this app's
    // dark theme, which is text you cannot see at all.
    final fill = room.ok
        ? (isOpen
              ? theme.colorScheme.primaryContainer
              : dimmed
              ? theme.colorScheme.surfaceContainerLow
              : theme.colorScheme.surface)
        : theme.colorScheme.errorContainer;
    final ink = foregroundOn(theme.colorScheme, fill);
    final quiet = readableOn(
      fill,
      prefer: [theme.colorScheme.onSurfaceVariant, ink],
    );
    final alarm = errorOn(theme.colorScheme, fill);

    return Card(
      margin: EdgeInsets.zero,
      color: fill,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Tooltip(
              message: room.ref.included
                  ? 'Counted in the project total'
                  : 'Kept on the job but out of the total - an alternate, or '
                        'a later phase',
              child: Checkbox(
                value: room.ref.included,
                onChanged: (v) => provider.updateProjectRoom(
                  room.ref.id,
                  included: v ?? true,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: _NameTarget(
                enabled: !isOpen,
                hovering: _hoveringName,
                onHover: (v) => setState(() => _hoveringName = v),
                onTap: () => _open(provider),
                tooltip: isOpen
                    ? 'This is the room the editor is working on'
                    : 'Open ${room.name} in the editor',
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: ink,
                      // Struck through when the room is off the total, and
                      // underlined while the pointer is over it — the two
                      // never coincide, because the open room is not a way in
                      // to itself.
                      decoration: dimmed
                          ? TextDecoration.lineThrough
                          : (_hoveringName && !isOpen
                              ? TextDecoration.underline
                              : null),
                      decorationColor: ink,
                    ),
                  ),
                  Text(
                    room.ok ? room.ref.configPath : room.room.error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: room.ok ? quiet : alarm,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // The room in the editor is priced from MEMORY, so its row
                  // can be ahead of its own file. Saying so is the price of
                  // that: a total nobody can reconcile with the folder is a
                  // total nobody trusts.
                  if (isOpen)
                    Row(
                      children: [
                        Icon(Icons.edit_note, size: 13, color: ink),
                        const SizedBox(width: 4),
                        // Expanded, because the unsaved wording is half a
                        // sentence longer than the plain one and the column it
                        // sits in is whatever the figures beside it leave over.
                        Expanded(
                          child: Text(
                            unsaved
                                ? 'Open in the editor - counted with its '
                                      'unsaved changes'
                                : 'Open in the editor',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: unsaved ? alarm : ink,
                              fontWeight: unsaved ? FontWeight.w600 : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              ),
            ),
            if (e != null) ...[
              _cell(
                context,
                'Equipment',
                formatMoney(e.equipmentTotal, currency),
                ink: ink,
                quiet: quiet,
              ),
              _cell(
                context,
                'Labor',
                formatMoney(e.laborTotal, currency),
                ink: ink,
                quiet: quiet,
              ),
              _cell(
                context,
                'Room total',
                formatMoney(e.grandTotal, currency),
                ink: ink,
                quiet: quiet,
                bold: true,
              ),
            ] else
              const Expanded(flex: 3, child: SizedBox()),
            // WHAT IS TRUE ABOUT THIS ROOM that no other column asks — the
            // asbestos above the grid, the wall it shares with the studio.
            //
            // Editable here rather than read-only, because the moment somebody
            // wants to write one is while they are looking at the room list;
            // sending them to the Notes pane to type it is how it ends up in
            // an email instead. The same field, either way — the Notes pane
            // and this column write to the same place.
            //
            // One line, because a row is a row. The full text is in the
            // tooltip and on the Notes pane, which is where a long one belongs.
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Notes',
                    style: theme.textTheme.labelSmall?.copyWith(color: quiet),
                  ),
                  Tooltip(
                    message: room.ref.notes.trim().isEmpty
                        ? 'Anything true of this room that the other columns '
                              'do not say. Goes out beside it on the workbook.'
                        : room.ref.notes,
                    child: LiveTextField(
                      key: ValueKey('room_row_notes_${room.ref.id}'),
                      fieldId: 'room_row_notes_${room.ref.id}',
                      initial: room.ref.notes,
                      hint: 'e.g. asbestos above the grid, contact '
                          'facilities',
                      onChanged: (v) =>
                          provider.updateProjectRoom(room.ref.id, notes: v),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            // WHAT IS ODD ABOUT THIS ROOM. Bigger than the buttons beside it
            // on purpose: it is the one thing on the row that is not always
            // there, and at 18 pixels in the quiet ink it read as decoration.
            //
            // Pressing it COPIES. What it lists is the answer to "why is this
            // room's total short", and that question is nearly always being
            // asked by somebody who is not in front of the app: a tooltip can
            // only be read, and a list that has to be retyped into a message
            // is one that arrives shortened.
            if (e != null && _roomFlags(room).isNotEmpty)
              IconButton(
                key: ValueKey('room_row_flags_${room.ref.id}'),
                tooltip:
                    '${_roomFlags(room).join('\n')}'
                    '\n\nClick to copy',
                icon: Icon(Icons.info_outline, size: 24, color: quiet),
                onPressed: () => _copyFlags(room),
              ),
            IconButton(
              tooltip: 'Move up',
              icon: const Icon(Icons.arrow_upward, size: 18),
              onPressed: widget.isFirst
                  ? null
                  : () => provider.moveProjectRoom(room.ref.id, -1),
            ),
            IconButton(
              tooltip: 'Move down',
              icon: const Icon(Icons.arrow_downward, size: 18),
              onPressed: widget.isLast
                  ? null
                  : () => provider.moveProjectRoom(room.ref.id, 1),
            ),
            IconButton(
              tooltip: 'Remove from the project (the room file is untouched)',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => provider.removeRoomFromProject(room.ref.id),
            ),
          ],
        ),
      ),
    );
  }

  /// Puts the room's flags on the clipboard, named so the paste stands alone.
  ///
  /// The room's code leads, because a bare list of "3 line(s) have no price"
  /// pasted into a message is a fact with no subject.
  Future<void> _copyFlags(ProjectRoomCost room) async {
    final messenger = ScaffoldMessenger.of(context);
    final flags = _roomFlags(room);
    await Clipboard.setData(
      ClipboardData(
        text: [
          room.codeName,
          for (final f in flags) '- $f',
        ].join('\n'),
      ),
    );
    if (!mounted) return;
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text('Copied what is flagged on ${room.codeName}'),
      ),
    );
  }

  static List<String> _roomFlags(ProjectRoomCost room) {
    final e = room.estimate!;
    return [
      if (room.room.isEmpty) 'Nothing drawn in this room yet.',
      if (e.unpricedLines > 0)
        '${e.unpricedLines} line(s) have no price - this room\'s total is '
            'short.',
      if (e.unratedLabor > 0)
        '${e.unratedLabor} labor line(s) have no rate on the rate card.',
      if (e.estimatedLines > 0)
        '${e.estimatedLines} line(s) priced off the base-cost card - '
            'budgetary, not quoted.',
      if (e.otherTierLines > 0)
        '${e.otherTierLines} line(s) could only be priced at the other '
            'pricing tier.',
      if (e.excludedLines > 0)
        '${e.excludedLines} line(s) are drawn but deliberately not bought.',
    ];
  }

  /// One figure on the row, with the ink the ROW measured for its own fill.
  ///
  /// The colours are passed in rather than read off the theme because this
  /// cell is painted on four different backgrounds — the page, a dimmed
  /// surface, the accent when the room is open, and the error fill when it
  /// could not be read. Taking the text theme's default meant the open room's
  /// figures were drawn in a colour chosen for the PAGE: on a dark accent,
  /// dark on dark, and the numbers on the row somebody is working in were the
  /// ones that disappeared.
  Widget _cell(
    BuildContext context,
    String label,
    String value, {
    required Color ink,
    required Color quiet,
    bool bold = false,
  }) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: quiet)),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: bold ? FontWeight.bold : null,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// The room's name and path, as the way into that room.
///
/// Its own widget so the row above stays readable, and so the "is this even
/// clickable" question has exactly one answer: when [enabled], the pointer
/// turns into a hand, the region takes a hover highlight and a ripple, and the
/// name underlines. When it is not — because this is already the open room —
/// none of that happens and the tooltip says why rather than leaving somebody
/// clicking at a row that does nothing.
class _NameTarget extends StatelessWidget {
  final bool enabled;
  final bool hovering;
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;
  final String tooltip;
  final Widget child;

  const _NameTarget({
    required this.enabled,
    required this.hovering,
    required this.onHover,
    required this.onTap,
    required this.tooltip,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Padded on the right so the ripple does not run under the figures beside
    // it, and given a radius so it reads as its own target rather than as the
    // whole card lighting up.
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      child: child,
    );
    if (!enabled) {
      return Tooltip(message: tooltip, child: body);
    }
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        onHover: onHover,
        child: body,
      ),
    );
  }
}

class _BuildingTotals extends StatelessWidget {
  final ProjectEstimate estimate;
  const _BuildingTotals({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget line(String label, double value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: bold
                  ? theme.textTheme.titleSmall
                  : theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            formatMoney(value, estimate.currency),
            style:
                (bold ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium)
                    ?.copyWith(fontWeight: bold ? FontWeight.bold : null),
          ),
        ],
      ),
    );

    return Card(
      margin: const EdgeInsets.only(top: 10),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Building total', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            line('Equipment', estimate.equipmentTotal),
            line('Rack hardware', estimate.hardwareTotal),
            line('Cabling', estimate.cablingTotal),
            line('Other items', estimate.extrasTotal),
            const Divider(),
            line('Parts subtotal', estimate.partsTotal),
            line(
              'Labor (${trimNumber(estimate.laborHours)} hrs)',
              estimate.laborTotal,
            ),
            line('Fees', estimate.feeTotal),
            line('Tax', estimate.taxTotal),
            const Divider(),
            line('Project total', estimate.grandTotal, bold: true),
            if (estimate.mixedCurrency)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Rooms on this project are quoted in different currencies. '
                  'The figures above add them as though they were the same '
                  'one - fix the room currencies before relying on any of it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: errorOn(
                      theme.colorScheme,
                      theme.colorScheme.surfaceContainerHigh,
                    ),
                  ),
                ),
              ),
            // Fees and tax are per-room percentages, and a reader who assumes
            // otherwise will try to check the total with a calculator and
            // conclude the app is wrong.
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Fees and tax are each room’s own, applied at that '
                'room’s rates and then added - not a project-wide '
                'percentage.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  CORE COMPONENTS
// ---------------------------------------------------------------------------

/// Master-list filters that are not a vendor id. Ids are always `vendor<n>`,
/// so these can never collide with one by accident.
///
/// Public because the filter is a piece of state on the tab and these are two
/// of the values it takes — the header's warning chip already reaches for the
/// unpriced one the same way.
const String kSparedFilter = '<spared>';
const String kNoSpareFilter = '<no-spare>';

/// Parts held below the share of them the job says it wants spared — see
/// [BuildingProject.spareTargetPercent]. Only ever offered on a job that has
/// set a target: with no policy there is nothing to fall short of.
const String kBelowSpareTargetFilter = '<spare-short>';

/// The core components list, as slivers for the tab's one scroll view.
List<Widget> partsSlivers(
  BuildContext context, {
  required ProjectEstimate estimate,
  required String vendorFilter,
  required String untaggedFilter,
  required String undrivenFilter,
  required String unpricedFilter,
  required String search,
  required ValueChanged<String> onVendorFilter,
  required ValueChanged<String> onSearch,
  String spareRoom = '',
  ValueChanged<String>? onSpareRoom,
}) {
  final theme = Theme.of(context);
  final needle = search.trim().toLowerCase();
  // Only ever a narrowing of the spares list — see [_ProjectViewState].
  final sparesOnly = vendorFilter == kSparedFilter;
  final room = sparesOnly ? spareRoom : '';

  // WHAT EACH PART IS SHORT BY, built once for the whole list rather than per
  // row: every row asks, and working it out on the row would walk the master
  // list once per row while somebody drags the scrollbar.
  //
  // Empty on a job with no target, which is what makes the flag mean
  // something — a warning on every row is a warning on none.
  final shortBy = {
    for (final c in estimate.partsBelowSpareTarget) c.line.key: c.shortfall,
  };

  bool matchesVendor(MasterPartLine line) {
    if (vendorFilter.isEmpty) return true;
    if (vendorFilter == untaggedFilter) return line.vendor == null;
    // Not a vendor at all — the other question this list gets asked. It shares
    // the one filter because only one of these is usefully on at a time, and
    // two rows of chips would be two rows to read.
    if (vendorFilter == undrivenFilter) return line.hasControlGap;
    if (vendorFilter == unpricedFilter) return line.unpriced;
    if (vendorFilter == kSparedFilter) {
      return room.isEmpty
          ? line.hasSpares
          : (line.spareByRoom[room] ?? 0) > 0;
    }
    // Equipment only, for the same reason the report's list is: nobody wants
    // to be asked about a spare blanking plate.
    if (vendorFilter == kNoSpareFilter) {
      return line.kind == MasterPartKind.equipment && !line.hasSpares;
    }
    // Short of the job's own rule, which is a different and much shorter list
    // than "has no spare": a job that holds ten per cent does not want to be
    // told about the part it has one spare of out of four.
    if (vendorFilter == kBelowSpareTargetFilter) {
      return shortBy.containsKey(line.key);
    }
    return line.vendor?.id == vendorFilter;
  }

  bool matchesSearch(MasterPartLine line) {
    if (needle.isEmpty) return true;
    return '${line.description} ${line.model} ${line.partNumber} '
            '${line.manufacturer} ${line.category}'
        .toLowerCase()
        .contains(needle);
  }

  Widget filterChip(String label, String value, {bool warn = false}) {
    final selected = vendorFilter == value;

    return FilterChip(
      label: Text(
        label,
        // ONLY WHILE IT IS UNSELECTED does this chip paint a fill of its own.
        // Pressed, it drops the error fill and takes the theme's - so a label
        // coloured for the error fill would be carried onto one it was never
        // measured against (3.7:1 on a light Classic blue). The selected
        // colours are the theme's own, and legible_theme.dart is what makes
        // that a promise rather than a hope.
        style: warn && !selected
            ? TextStyle(
                color: foregroundOn(
                  theme.colorScheme,
                  theme.colorScheme.errorContainer,
                ),
              )
            : null,
      ),
      selected: selected,
      onSelected: (_) => onVendorFilter(value),
      backgroundColor: warn ? theme.colorScheme.errorContainer : null,
    );
  }

  final lines = [
    for (final l in estimate.master)
      if (matchesVendor(l) && matchesSearch(l)) l,
  ];

  // ISOLATED SPARES ARE ORDERED BY SPARE, not by the master list's own order.
  // The master list is grouped so a vendor can read it; a spares list is read
  // to find the big asks, and a part with six spares on it has no business
  // sitting below one with a single spare because of what category it is in.
  if (sparesOnly) {
    double spareOf(MasterPartLine l) =>
        room.isEmpty ? l.spareQty : (l.spareByRoom[room] ?? 0);
    lines.sort((a, b) {
      final byQty = spareOf(b).compareTo(spareOf(a));
      return byQty != 0
          ? byQty
          : a.description.toLowerCase().compareTo(b.description.toLowerCase());
    });
  }

  // Built once for the whole list rather than per row — see [_PartRow].
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.name};

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(
          children: [
            SizedBox(
              width: 260,
              child: LiveTextField(
                fieldId: 'project_part_search',
                initial: search,
                label: 'Search parts',
                hint: 'model, part number, maker',
                onChanged: onSearch,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  filterChip('All (${estimate.master.length})', ''),
                  for (final p in estimate.vendors)
                    if (!p.isUntagged)
                      filterChip('${p.name} (${p.lines.length})', p.vendor!.id),
                  if (estimate.untaggedParts > 0)
                    filterChip(
                      'Untagged (${estimate.untaggedParts})',
                      untaggedFilter,
                      warn: true,
                    ),
                  if (estimate.master.any((l) => l.hasControlGap))
                    filterChip(
                      'No control module (${estimate.master.where((l) => l.hasControlGap).length})',
                      undrivenFilter,
                      warn: true,
                    ),
                  if (estimate.unpricedParts > 0)
                    filterChip(
                      'No price (${estimate.unpricedParts})',
                      unpricedFilter,
                      warn: true,
                    ),
                  // Both halves of the spares question, because they are two
                  // different jobs: checking what was asked for, and deciding
                  // about what was not. The second is the one nothing else in
                  // the app would ever raise.
                  //
                  // ALWAYS OFFERED, even on a job with no spares on it. This
                  // is the way in to the section where a spare is ADDED, and a
                  // chip that appeared only once somebody had already added
                  // one would be a door that opens from the inside.
                  filterChip(
                    estimate.sparedParts.isEmpty
                        ? 'Spares'
                        : 'Spares (${estimate.sparedParts.length})',
                    kSparedFilter,
                  ),
                  if (estimate.partsWithoutSpares.isNotEmpty)
                    filterChip(
                      'No spare (${estimate.partsWithoutSpares.length})',
                      kNoSpareFilter,
                    ),
                  // The job's own rule, and the only spares chip that is a
                  // FAULT rather than a question: these are parts the job has
                  // already said it wants more of.
                  if (shortBy.isNotEmpty)
                    filterChip(
                      'Below ${trimNumber(estimate.spareTargetPercent)}% '
                      'target (${shortBy.length})',
                      kBelowSpareTargetFilter,
                      warn: true,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    // THE SPARES SECTION, only while the spares are what is on screen. It is
    // where a spare is added, scoped to a room or to the building, and moved
    // between the two — see project_spares_view.dart.
    if (sparesOnly) ...spareSectionSlivers(context, estimate),
    // And the room filter under it, for reading the parts list itself as one
    // room's shelf list.
    if (sparesOnly)
      SliverToBoxAdapter(
        child: _SparesPanel(
          estimate: estimate,
          selectedRoom: room,
          onRoom: onSpareRoom ?? (_) {},
        ),
      ),
    if (estimate.master.isEmpty)
      const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nothing to order yet.\n\n'
              'The master list is built from the rooms on this project - '
              'add rooms that have equipment on them.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else ...[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _PartsHeaderRow(theme: theme),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverList.builder(
          itemCount: lines.length,
          itemBuilder: (context, index) => _PartRow(
            line: lines[index],
            estimate: estimate,
            roomNames: roomNames,
            spareRoom: room,
            sparesOnly: sparesOnly,
            shortfall: shortBy[lines[index].key] ?? 0,
            askingAboutSpares:
                vendorFilter == kNoSpareFilter ||
                vendorFilter == kBelowSpareTargetFilter,
          ),
        ),
      ),
    ],
  ];
}

/// The spares, isolated: what the job is buying for the shelf, what it costs,
/// and which room asked for each of it.
///
/// ONLY ON SCREEN WHILE THE SPARED FILTER IS ON. It is a summary of a subset,
/// and a summary of a subset shown above the whole list is a summary that gets
/// read as the job's own figures.
///
/// The room chips are the point of the panel rather than decoration on it. A
/// master list merges rooms together on purpose — that is the entire reason it
/// exists — and the merge is what makes a spare impossible to account for
/// afterwards: "eleven, four of them spare" can be neither approved nor
/// trimmed until somebody knows whose four they are. Pressing a room narrows
/// the list under the panel to that room's spares, and every row then counts
/// and prices that room's share rather than the job's.
class _SparesPanel extends StatelessWidget {
  final ProjectEstimate estimate;

  /// The room the list is narrowed to, '' for every room's spares.
  final String selectedRoom;
  final ValueChanged<String> onRoom;

  const _SparesPanel({
    required this.estimate,
    required this.selectedRoom,
    required this.onRoom,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currency = estimate.currency;
    final byRoom = estimate.sparesByRoom;
    final muted = theme.colorScheme.onSurfaceVariant;

    // What is on screen right now, which is not always the job's own figure:
    // with a room selected these are that room's spares, and a panel that went
    // on showing the job total beside a filtered list would be inviting
    // somebody to read the wrong number off it.
    final shown = selectedRoom.isEmpty
        ? null
        : byRoom.where((r) => r.roomId == selectedRoom).firstOrNull;
    final units = shown?.units ?? estimate.spareUnits;
    final cash = shown?.cost ?? estimate.sparesTotal;
    final parts = shown?.parts ?? estimate.sparedParts.length;

    Widget roomChip(String label, String value, {String? tooltip}) {
      final picked = selectedRoom == value;
      final chip = FilterChip(
        key: ValueKey('spare_room_$value'),
        label: Text(label),
        selected: picked,
        onSelected: (_) => onRoom(picked ? '' : value),
      );
      return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        key: const ValueKey('project_spares_panel'),
        margin: EdgeInsets.zero,
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.5,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.inventory_outlined,
                    size: 16,
                    // The accent, measured against what this panel actually
                    // paints — see [spareSectionFill]. Plain tertiary is
                    // 2.2:1 here on a light Classic theme with the blue
                    // accent, and 1.3:1 with cyan.
                    color: accentTextOn(
                      theme.colorScheme,
                      spareSectionFill(theme),
                      minRatio: kContrastLarge,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      shown == null
                          ? 'Spares on this job'
                          : 'Spares for ${shown.name}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    '${trimNumber(units)} '
                    '${units == 1 ? 'unit' : 'units'} across '
                    '$parts ${parts == 1 ? 'part' : 'parts'}  ·  '
                    '${formatMoney(cash, currency)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: accentTextOn(
                        theme.colorScheme,
                        spareSectionFill(theme),
                      ),
                    ),
                  ),
                ],
              ),
              if (byRoom.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Nothing on this job is spared. Spares are asked for on a '
                    'room’s Cost page, and every one of them shows up here.',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'ASKED FOR BY',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: muted,
                    ),
                  ),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    roomChip(
                      'Every room (${trimNumber(estimate.spareUnits)})',
                      '',
                      tooltip: 'Every spare on the job, whoever asked for it',
                    ),
                    for (final r in byRoom)
                      roomChip(
                        '${r.name} (${trimNumber(r.units)})',
                        r.roomId,
                        tooltip:
                            '${trimNumber(r.units)} spare '
                            '${r.units == 1 ? 'unit' : 'units'} across '
                            '${r.parts} ${r.parts == 1 ? 'part' : 'parts'}'
                            '  ·  ${formatMoney(r.cost, currency)}',
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PartsHeaderRow extends StatelessWidget {
  final ThemeData theme;
  const _PartsHeaderRow({required this.theme});

  @override
  Widget build(BuildContext context) {
    Text label(String text, TextAlign align) => Text(
      text,
      textAlign: align,
      style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold),
    );

    Widget h(String text, int flex, {TextAlign align = TextAlign.left}) =>
        Expanded(flex: flex, child: label(text, align));

    Widget fixed(String text, double width) =>
        SizedBox(width: width, child: label(text, TextAlign.right));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          h('Part', 5),
          h('Qty', 1, align: TextAlign.right),
          h('Unit', 2, align: TextAlign.right),
          h('Extended', 2, align: TextAlign.right),
          // The gap the row has in front of its vendor cell. Without it every
          // heading from here rightwards sat eight pixels left of the column
          // it names.
          const SizedBox(width: 8),
          h('Vendor', 3),
          // When it has to be bought, beside who buys it — the two halves of
          // placing one order, and the reason the lead time lives on this list
          // rather than on a screen of its own. Fixed widths rather than flex,
          // to line up with [_ScheduleCells], which cannot flex: a date is a
          // fixed amount of text and a column that shrinks below it would
          // ellipsize the one thing the column is for.
          fixed('Lead time', 84),
          const SizedBox(width: 8),
          fixed('Order by', 132),
          const SizedBox(width: 40),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _PartRow extends StatelessWidget {
  final MasterPartLine line;
  final ProjectEstimate estimate;

  /// Room id -> name, built ONCE for the whole list and handed down.
  ///
  /// This row used to build it itself, which on a job with forty rooms and two
  /// hundred parts meant assembling the same forty-entry map two hundred times
  /// per scroll — per rebuild, in a list whose whole point is that it builds
  /// rows lazily while somebody drags the scrollbar.
  final Map<String, String> roomNames;

  /// The room whose spares the list is narrowed to, '' for all of them.
  /// Only ever set while [sparesOnly] is.
  final String spareRoom;

  /// True while the list is isolating spares, which changes what this row is
  /// being read for: not "what is being bought" but "what is going on a shelf,
  /// and for whom".
  final bool sparesOnly;

  /// Units this part would need to meet the job's spares target, 0 when it
  /// meets it or when the job has set no target.
  final double shortfall;

  /// True while the list is answering a question ABOUT SPARES — the parts with
  /// none, or the ones below the target. What it changes is that the row
  /// offers the fix: this is the list somebody is looking at when they decide
  /// to spare something, and the only reason to open it is to act on it.
  final bool askingAboutSpares;

  const _PartRow({
    required this.line,
    required this.estimate,
    required this.roomNames,
    this.spareRoom = '',
    this.sparesOnly = false,
    this.shortfall = 0,
    this.askingAboutSpares = false,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    final currency = estimate.currency;

    final rooms = [
      for (final id in line.roomIdsByQty())
        '${roomNames[id] ?? id} ×${trimNumber(line.qtyByRoom[id] ?? 0)}',
    ].join(', ');

    final subtitle = [
      if (line.manufacturer.isNotEmpty) line.manufacturer,
      if (line.model.isNotEmpty) line.model,
      if (line.partNumber.isNotEmpty) 'PN ${line.partNumber}',
      kMasterPartKindLabels[line.kind]!,
    ].join('  ·  ');

    // WHO ASKED FOR THE SPARES. Named rather than totalled, for the same
    // reason the undriven list below is: "4 spare" is a figure to go and
    // investigate, "BSS 103 x3, ENG 210 x1" is an answer. Shown on every
    // spared row rather than only while the list is filtered, because the
    // question follows the spare wherever it is read.
    final sparedBy = [
      for (final id in line.spareRoomIdsByQty())
        '${roomNames[id] ?? id} ×${trimNumber(line.spareByRoom[id] ?? 0)}',
    ].join(', ');

    // With a room selected the row counts and prices THAT room's spares. A row
    // that went on showing the job's eleven under a list titled 'Spares for
    // BSS 103' would be the one number nobody could check.
    final roomSpare = spareRoom.isEmpty
        ? line.spareQty
        : (line.spareByRoom[spareRoom] ?? 0);

    // Which rooms still have no driver for this product. Named rather than
    // counted: "3 undriven" is something to go and investigate, a list of
    // rooms is something to work through.
    final undriven = [
      for (final e in line.undrivenByRoom.entries)
        '${roomNames[e.key] ?? e.key} ×${e.value}',
    ].join(', ');

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.description, style: theme.textTheme.bodyMedium),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    rooms,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (line.hasSpares)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.inventory_outlined,
                            size: 13,
                            color: accentTextOn(
                              theme.colorScheme,
                              theme.cardColor,
                              minRatio: kContrastLarge,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Spare for $sparedBy',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: accentTextOn(
                                  theme.colorScheme,
                                  theme.cardColor,
                                ),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // What the shelf units cost, next to who wanted
                          // them - the two halves of deciding whether a spare
                          // stays on the quote. Only while the spares are what
                          // is being read: on the full master list it is a
                          // third money figure on a row that already has two.
                          if (sparesOnly && !line.unpriced) ...[
                            const SizedBox(width: 6),
                            Text(
                              formatMoney(
                                roomSpare * line.unitPrice,
                                currency,
                              ),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: accentTextOn(
                                  theme.colorScheme,
                                  theme.cardColor,
                                ),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  // SHORT OF THE JOB'S OWN RULE, and the way to fix it. The
                  // percentage table on the spares section says the same thing
                  // about the whole job; this says it on the row somebody is
                  // already reading, which is where the decision to buy one
                  // more actually gets made.
                  if (shortfall > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.inventory_outlined,
                            size: 13,
                            color: errorTextOn(
                              theme.colorScheme,
                              theme.cardColor,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${trimNumber(shortfall)} short of the '
                              '${trimNumber(estimate.spareTargetPercent)}% '
                              'spares target',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: errorTextOn(
                                  theme.colorScheme,
                                  theme.cardColor,
                                ),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _AddSpareButton(
                            estimate: estimate,
                            line: line,
                            qty: shortfall,
                            label: 'Add ${trimNumber(shortfall)}',
                          ),
                        ],
                      ),
                    )
                  // NOTHING SPARED, while that is the question being asked.
                  // The list of parts with no spare used to be a list to read
                  // and then go and do something about somewhere else, which
                  // is why it was read and then ignored.
                  else if (askingAboutSpares && !line.hasSpares)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.inventory_outlined,
                            size: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Nothing spared of this',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _AddSpareButton(
                            estimate: estimate,
                            line: line,
                            qty: 1,
                            label: 'Add a spare',
                          ),
                        ],
                      ),
                    ),
                  if (line.hasControlGap)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.memory,
                            size: 13,
                            color: errorTextOn(theme.colorScheme, theme.cardColor),
                          ),
                          const SizedBox(width: 4),
                          // Both halves flex. The note used to be flexible
                          // beside a fixed-width button, which on a narrow
                          // window left the text a negative width and put an
                          // overflow stripe across the row — the button is the
                          // wider of the two and had to be allowed to shrink
                          // as well.
                          Flexible(
                            flex: 3,
                            child: Text(
                              'No control module - $undriven',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: errorTextOn(theme.colorScheme, theme.cardColor),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // The fix, next to the complaint. Some of these rows
                          // are a driver waiting to be written and some are a
                          // passive splitter that will never have one, and the
                          // second kind is why this list gets scrolled past —
                          // so the way to retire it is on the row that is
                          // wrong, not three tabs away.
                          if (line.model.trim().isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              flex: 2,
                              child: _NeverNeedsModuleButton(
                                model: line.model,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    trimNumber(line.qty),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  // Tagged under the count rather than in a column of its own:
                  // a spare is part of the quantity being bought, and on most
                  // jobs most rows have none — a whole column would be blank
                  // on nine rows in ten and cost every row the width to say
                  // nothing.
                  if (line.hasSpares)
                    Tooltip(
                      message: spareRoom.isEmpty
                          ? '${trimNumber(line.spareQty)} of these are spares '
                              'for the shelf.\n'
                              '${trimNumber(line.drawnQty)} go into rooms.'
                          : '${roomNames[spareRoom] ?? spareRoom} asked for '
                              '${trimNumber(roomSpare)} of these as spares.\n'
                              '${trimNumber(line.spareQty)} spare on the job '
                              'in total, out of ${trimNumber(line.qty)} '
                              'bought.',
                      child: Text(
                        '${trimNumber(roomSpare)} spare',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: accentTextOn(
                            theme.colorScheme,
                            theme.cardColor,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Tooltip(
                message: line.unpriced
                    ? 'Nothing on this job has a price for this part. Click '
                        'to set one - in the catalog, or on this job only.'
                    : line.priceVaries
                        ? 'Rooms on this job hold different prices for this '
                            'part - one of them has a negotiated override.\n'
                            'Click to set one price for the job.'
                        : 'Click to change the price',
                child: InkWell(
                  key: ValueKey('part_price_${line.key}'),
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => showPartPriceDialog(
                    context,
                    provider,
                    line,
                    currency,
                  ),
                  child: Text(
                  line.unpriced
                      ? 'not priced'
                      : line.priceVaries
                      ? '${formatMoney(line.unitPrice, currency)}-'
                            '${formatMoney(line.maxUnitPrice, currency)}'
                      : formatMoney(line.unitPrice, currency),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    // "not priced" is small red text on a card, and the
                    // scheme's own error red clears the 4.5:1 minimum by a
                    // whisker on some accents — passing, and still hard to
                    // read. legibleTone keeps the red and lightens it until it
                    // clears the AAA bar instead.
                    color: line.unpriced
                        ? errorTextOn(theme.colorScheme, theme.cardColor)
                        : null,
                    fontWeight: line.unpriced ? FontWeight.w600 : null,
                    fontStyle: line.priceVaries ? FontStyle.italic : null,
                    decoration:
                        line.unpriced ? TextDecoration.underline : null,
                    decorationColor:
                        errorTextOn(theme.colorScheme, theme.cardColor),
                  ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                formatMoney(line.total, currency),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: _VendorPicker(line: line, estimate: estimate),
            ),
            _ScheduleCells(line: line, provider: provider),
            SizedBox(
              width: 40,
              child: line.tagSource == VendorTagSource.pinned
                  ? IconButton(
                      tooltip:
                          'Clear the pin - let the vendor rules decide '
                          'again',
                      icon: const Icon(Icons.push_pin, size: 18),
                      onPressed: () => provider.pinProjectPart(
                        line.key,
                        '',
                        partName: line.description,
                      ),
                    )
                  : Tooltip(
                      message: kVendorTagSourceLabels[line.tagSource] ?? '',
                      child: Icon(
                        line.tagSource == VendorTagSource.none
                            ? Icons.help_outline
                            : Icons.rule,
                        size: 18,
                        color: line.tagSource == VendorTagSource.none
                            ? errorTextOn(theme.colorScheme, theme.cardColor)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
            SizedBox(
              width: 40,
              // Only equipment can be swapped: a length of cable and a
              // blanking plate are not products with connectors to remap, and
              // the estimate prices them from their own tables anyway.
              child: line.kind == MasterPartKind.equipment
                  ? IconButton(
                      key: ValueKey('project_swap_${line.key}'),
                      tooltip: 'Swap this product in every room that has it',
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      onPressed: () =>
                          swapPartAcrossProject(context, provider, line),
                    )
                  : const SizedBox(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Spares this part from the list that is asking about it.
///
/// Opens the same dialog the spares section does, with the part already picked
/// and the quantity already typed — so a row flagged as two short is fixed
/// with one press and one confirmation, rather than by finding the part again
/// in a list of two hundred.
class _AddSpareButton extends StatelessWidget {
  final ProjectEstimate estimate;
  final MasterPartLine line;
  final double qty;
  final String label;

  const _AddSpareButton({
    required this.estimate,
    required this.line,
    required this.qty,
    required this.label,
  });

  @override
  Widget build(BuildContext context) => TextButton(
    key: ValueKey('part_add_spare_${line.key}'),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: Theme.of(context).textTheme.bodySmall,
    ),
    onPressed: () => showAddSpareDialog(
      context,
      estimate,
      partKey: line.key,
      qty: qty,
    ),
    child: Text(label),
  );
}

/// The lead time and the order-by date, on the part row.
///
/// Two cells and one target: pressing either opens the same editor, because
/// "six weeks" and "has to be here by the 3rd" are one thing somebody learns in
/// one phone call and would otherwise be two separate clicks to record.
///
/// The order-by cell is DERIVED and never typed — it is the delivery date minus
/// the lead time, worked out on the spot (see project_schedule.dart), so
/// moving the job's deadline moves every one of these without anybody editing
/// a row.
class _ScheduleCells extends StatelessWidget {
  final MasterPartLine line;
  final AppStateProvider provider;

  const _ScheduleCells({required this.line, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final part = schedulePart(line: line, project: provider.project);
    final color = orderStatusColor(context, part.status);
    final orderBy = part.orderBy;

    // What the cell says when there is no date, spelled as the thing that is
    // missing rather than as a dash — a blank tells somebody nothing about
    // which of the two facts to go and find.
    final String orderText;
    // BOUGHT BEATS DUE. Once a part is on order the order-by date is history,
    // and showing it would read as something still to do.
    if (part.status == OrderStatus.received) {
      orderText = 'received';
    } else if (part.isBought) {
      orderText = part.order?.expectedOn == null
          ? 'on order'
          : 'due ${formatScheduleDate(part.order!.expectedOn!)}';
    } else if (orderBy != null) {
      orderText = formatScheduleDate(orderBy);
    } else if (part.status == OrderStatus.noDeadline) {
      orderText = 'no deadline';
    } else {
      orderText = 'set lead time';
    }

    void edit() => showPartScheduleDialog(context, provider, line);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 84,
          child: Tooltip(
            message: part.leadDays == null
                ? 'Nobody has recorded how long this takes to arrive.\n'
                    'Click to set it.'
                : part.leadFromCatalog
                // Worth distinguishing: a date worked back from what the
                // catalog remembers is a different kind of promise from one
                // worked back from what a vendor quoted last week.
                ? 'Takes ${formatLeadTime(part.leadDays)} to arrive, from the '
                      'catalog.\nClick to set a figure for this job.'
                : 'Takes ${formatLeadTime(part.leadDays)} to arrive.\n'
                      'Click to change it.',
            child: InkWell(
              key: ValueKey('part_lead_${line.key}'),
              borderRadius: BorderRadius.circular(4),
              onTap: edit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  formatLeadTime(part.leadDays),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: part.leadDays == null
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                    fontStyle:
                        part.leadDays == null ? FontStyle.italic : null,
                    decoration: part.leadDays == null
                        ? TextDecoration.underline
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 132,
          child: Tooltip(
            message: orderBy == null
                ? 'Needs a lead time and a delivery date before this can be '
                    'worked out.'
                : '${kOrderStatusLabels[part.status]}'
                    ' - ${formatDayGap(part.daysUntilOrder ?? 0)}.\n'
                    'On site by ${formatScheduleDate(part.needBy!)}'
                    '${part.needByIsOwn ? ' (ahead of the job)' : ''}.',
            child: InkWell(
              key: ValueKey('part_orderby_${line.key}'),
              borderRadius: BorderRadius.circular(4),
              onTap: edit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (part.needsAttention) ...[
                          Icon(
                            orderStatusIcon(part.status),
                            size: 13,
                            color: color,
                          ),
                          const SizedBox(width: 3),
                        ],
                        Flexible(
                          child: Text(
                            orderText,
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: orderBy == null
                                  ? theme.colorScheme.onSurfaceVariant
                                  : color,
                              fontWeight: part.needsAttention
                                  ? FontWeight.w600
                                  : null,
                              fontStyle:
                                  orderBy == null ? FontStyle.italic : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (part.isBought)
                      Text(
                        part.status == OrderStatus.received
                            ? 'arrived'
                            : part.order?.poNumber.trim().isNotEmpty == true
                            ? 'PO ${part.order!.poNumber.trim()}'
                            : 'ordered',
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: color,
                        ),
                      )
                    else if (orderBy != null)
                      Text(
                        formatDayGap(part.daysUntilOrder ?? 0),
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: color,
                        ),
                      ),
                    // WHY the date is what it is, under the date itself. Both
                    // of these live here rather than in columns of their own:
                    // each is blank on most rows, and a column that says
                    // nothing on ninety rows in a hundred costs every row the
                    // width anyway.
                    if (part.needByIsOwn && part.needBy != null)
                      Text(
                        'on site ${formatScheduleDate(part.needBy!)}',
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    // The phase it rides, when the job has split into them —
                    // otherwise two parts with the same lead time and
                    // different order dates look like an error.
                    else if (part.track != null)
                      Text(
                        part.track!.name,
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Swapping one product for another in every room that has it.
///
/// Two dialogs on purpose. The first picks the replacement — a catalog search,
/// the same one the Signal Flow tab uses. The second shows what that would
/// actually DO: how many boxes in how many rooms, how many runs carry across,
/// how many get dropped, and whether the control blocks are about to lose
/// their module.
///
/// Nothing is written between them. A bulk edit across nine files that a
/// person cannot preview is a bulk edit nobody should press, and "how many
/// cables am I about to lose" is not a question the app should make somebody
/// find out by trying it.
Future<void> swapPartAcrossProject(
  BuildContext context,
  AppStateProvider provider,
  MasterPartLine line,
) async {
  if (line.model.trim().isEmpty) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      const SnackBar(
        duration: Duration(seconds: 5),
        content: Text(
          'This line has no model on it, so there is nothing to match in the '
          'other rooms. Set a model on the device first.',
        ),
      ),
    );
    return;
  }

  final template = await pickCatalogModel(
    context,
    provider,
    title: 'Swap ${line.model} across the project',
    actionLabel: 'Continue',
    currentModel: line.model,
    note:
        'Every box on this product, in every room on the project, becomes the '
        'one you pick. You will see exactly what changes before anything is '
        'written.',
  );
  if (template == null || !context.mounted) return;

  if (template.model.trim().toLowerCase() == line.model.trim().toLowerCase()) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      const SnackBar(
        duration: Duration(seconds: 4),
        content: Text('That is the product it already is.'),
      ),
    );
    return;
  }

  final plan = provider.planProjectModelSwap(line.model, template);
  if (!context.mounted) return;

  if (plan.isEmpty) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          plan.failedRooms.isEmpty
              ? 'No room on this project has a ${line.model} on its drawing.'
              : 'Nothing to swap - and ${plan.failedRooms.length} room(s) '
                    'could not be read, so they were not checked.',
        ),
      ),
    );
    return;
  }

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => _SwapPreviewDialog(plan: plan),
  );
  if (go != true || !context.mounted) return;

  final result = provider.applyProjectModelSwap(plan);
  if (!context.mounted) return;

  final rooms = result.disk.rooms + (result.openRoomBoxes > 0 ? 1 : 0);
  final boxes = result.disk.boxes + result.openRoomBoxes;
  final parts = <String>[
    '$boxes box(es) swapped to ${template.model} across $rooms room(s)',
    if (result.disk.dropped > 0) '${result.disk.dropped} run(s) dropped',
    if (result.openRoomDirty)
      'the open room changed in memory - save it to keep the change',
    if (result.disk.failures.isNotEmpty)
      '${result.disk.failures.length} room(s) failed: '
          '${result.disk.failures.first}',
  ];
  showTimedSnackBar(
    ScaffoldMessenger.of(context),
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(parts.join('  ·  ')),
      backgroundColor: result.disk.failures.isEmpty ? null : snackErrorFill(context),
    ),
  );
}

/// What the swap is about to do, room by room, before it does it.
class _SwapPreviewDialog extends StatelessWidget {
  final ProjectSwapPlan plan;
  const _SwapPreviewDialog({required this.plan});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.dialogTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerHigh;

    Widget warning(IconData icon, String text, {bool severe = false}) =>
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 18,
                color: severe
                    ? errorTextOn(theme.colorScheme, theme.cardColor)
                    // tertiary is 2.1:1 on the light themes — invisible for
                    // something whose whole job is to be noticed.
                    : readableOn(
                        surface,
                        prefer: [
                          theme.colorScheme.tertiary,
                          theme.colorScheme.onSurfaceVariant,
                        ],
                        minRatio: kContrastLarge,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: severe
                        ? errorTextOn(theme.colorScheme, theme.cardColor)
                        : null,
                  ),
                ),
              ),
            ],
          ),
        );

    return AlertDialog(
      title: Text('Swap ${plan.fromModel} → ${plan.to.model}'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plan.boxes} box(es) in ${plan.affectedRooms.length} room(s).',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final room in plan.affectedRooms)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                room.isOpenRoom
                                    ? '${room.roomName}  (open)'
                                    : room.roomName,
                                style: theme.textTheme.bodyMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              [
                                '${room.boxes} box'
                                    '${room.boxes == 1 ? '' : 'es'}',
                                '${room.carried} run'
                                    '${room.carried == 1 ? '' : 's'} kept',
                                if (room.dropped > 0) '${room.dropped} DROPPED',
                                if (room.blocks > 0)
                                  '${room.blocks} control block'
                                      '${room.blocks == 1 ? '' : 's'}',
                              ].join('  ·  '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: room.dropped > 0
                                    ? errorTextOn(theme.colorScheme, theme.cardColor)
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(),
            if (plan.dropped > 0)
              warning(
                Icons.link_off,
                '${plan.dropped} drawn run(s) land on connectors the '
                '${plan.to.model} does not have. They will be REMOVED - draw '
                'them again on the Signal Flow tab of those rooms afterwards.',
                severe: true,
              ),
            if (plan.losesModule)
              warning(
                Icons.memory,
                'No Python module claims ${plan.to.model}, so the module is '
                'cleared on all ${plan.blocks} control block(s). Those devices '
                'will show as having no control module until a driver is '
                'picked - which is what you want them to say.',
              ),
            if (plan.newModule.isNotEmpty && plan.blocks > 0)
              warning(
                Icons.check_circle_outline,
                '${plan.blocks} control block(s) move to ${plan.newModule}. IP '
                'addresses, ports and control ids are kept.',
              ),
            if (plan.anyRackHeightChanged)
              warning(
                Icons.view_day,
                'The new product is a different rack height. Boxes keep the U '
                'they start at, so check the elevations.',
              ),
            if (plan.failedRooms.isNotEmpty)
              warning(
                Icons.error_outline,
                '${plan.failedRooms.length} room(s) could not be read and were '
                'not checked: '
                '${plan.failedRooms.map((r) => r.roomName).join(', ')}. They '
                'keep the old product.',
                severe: true,
              ),
            warning(
              Icons.save,
              'This writes to the room files directly. There is no '
              'project-wide undo - a room\'s own Undo only covers the room '
              'open in the editor.',
              severe: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('project_swap_apply'),
          onPressed: () => Navigator.pop(context, true),
          child: Text('Swap ${plan.boxes} box(es)'),
        ),
      ],
    );
  }
}

/// "Never needs one" — retiring a control-gap row by telling the CATALOG that
/// the product has no control interface at all.
///
/// A confirm step, short but real, because this is the only control on the
/// master list that reaches outside the project: it is written to
/// av_devices.json and every room in every job stops asking about that product
/// from then on. The rest of this tab edits the project; this edits the price
/// list everyone shares.
///
/// The reverse is deliberately NOT here. Once a product is marked, it stops
/// appearing on this list at all, so there would be no row to un-mark it from —
/// the tick on the Catalog tab is where that lives, and the confirm text says
/// so rather than leaving somebody hunting.
class _NeverNeedsModuleButton extends StatefulWidget {
  final String model;
  const _NeverNeedsModuleButton({required this.model});

  @override
  State<_NeverNeedsModuleButton> createState() =>
      _NeverNeedsModuleButtonState();
}

class _NeverNeedsModuleButtonState extends State<_NeverNeedsModuleButton> {
  /// True while the catalog is being written, so a second press cannot start a
  /// second write of the same file.
  bool _busy = false;

  Future<void> _mark() async {
    final provider = context.read<AppStateProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${widget.model} never needs a module?'),
        content: Text(
          'For a product nothing can drive anywhere - a passive splitter, a '
          'plate, a USB capture stick.\n\n'
          'This is saved to the CATALOG, not to this project. Every room in '
          'every job that draws a ${widget.model} stops reporting it as '
          'waiting for a control module.\n\n'
          'If instead this particular box just is not yours to drive - an '
          'owner-furnished display, the building’s switch - leave this alone '
          'and mark that box on the room’s own Cost tab.\n\n'
          'To undo it later, untick "Never in the room config" on the Catalog '
          'tab.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('never_needs_module_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save to catalog'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    final result = await provider.setModelNeverControlled(widget.model, true);
    if (!mounted) return;
    setState(() => _busy = false);

    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(result.message),
        backgroundColor: result.ok ? null : snackErrorFill(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message:
          'Nothing can drive a ${widget.model} anywhere - record that on '
          'the catalog entry',
      child: TextButton(
        key: ValueKey('never_needs_module_${widget.model}'),
        onPressed: _busy ? null : _mark,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: theme.textTheme.bodySmall,
        ),
        child: const Text(
          'Never needs one',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// The per-part vendor override.
class _VendorPicker extends StatelessWidget {
  final MasterPartLine line;
  final ProjectEstimate estimate;

  const _VendorPicker({required this.line, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    final vendors = estimate.project.vendors;

    if (vendors.isEmpty) {
      return Text(
        'No vendors yet',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        isDense: true,
        isExpanded: true,
        value: line.vendor?.id ?? '',
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(
              'Untagged',
              style: TextStyle(
                color: errorTextOn(theme.colorScheme, theme.cardColor),
              ),
            ),
          ),
          for (final v in vendors)
            DropdownMenuItem(value: v.id, child: Text(v.name)),
        ],
        onChanged: (id) {
          // Choosing the vendor the rules already picked clears the pin
          // instead of freezing it. Otherwise a glance down the column and a
          // few confirming clicks would quietly pin half the list, and the
          // next rule change would skip every part somebody had "agreed" with.
          final chosen = id ?? '';
          provider.pinProjectPart(
            line.key,
            chosen == _ruleOnly(line) ? '' : chosen,
            partName: line.description,
          );
        },
      ),
    );
  }

  /// What the RULES alone would tag this part with, ignoring any pin — needed
  /// to tell "the user agreed with the rule" from "the user overrode it".
  String _ruleOnly(MasterPartLine line) {
    for (final v in estimate.project.vendors) {
      if (v.quotesManufacturer(line.manufacturer)) return v.id;
    }
    for (final v in estimate.project.vendors) {
      if (v.quotesCategory(line.category)) return v.id;
    }
    return '';
  }
}

// ---------------------------------------------------------------------------
//  VENDORS
// ---------------------------------------------------------------------------

/// The Vendors pane, as slivers for the tab's one scroll view.
List<Widget> vendorsSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.read<AppStateProvider>();
  final theme = Theme.of(context);
  final vendors = estimate.project.vendors;
  final conflicts = estimate.project.vendorConflicts;
  // Against the card's own error fill. The theme's title colour is chosen for
  // a surface, and onErrorContainer is only the scheme's PREFERENCE — it fails
  // WCAG on 45 of this app's 180 theme/accent combinations.
  final conflictInk =
      foregroundOn(theme.colorScheme, theme.colorScheme.errorContainer);

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: () => provider.addProjectVendor(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add vendor'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'A part is tagged by the FIRST vendor whose rules claim it. '
                'Manufacturer rules are checked before category rules, so '
                'Extron beats “AV Reseller for Speakers” for an '
                'Extron speaker. Order matters in the list below - drag a '
                'vendor up by its handle to give it priority. Open one to '
                'edit its rules.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    if (conflicts.isNotEmpty)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Overlapping rules',
                    // Against the card's own fill. The theme's title colour is
                    // chosen for a surface, and on an error container it is
                    // the wrong side of readable.
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: conflictInk,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final c in conflicts)
                    Text(
                      '${c.kind} "${c.rule}" is claimed by '
                      '${c.vendors.map((v) => v.name).join(' and ')}. '
                      '${c.vendors.first.name} wins.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: conflictInk,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    if (vendors.isEmpty)
      const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No vendors yet.\n\n'
              'Add one per company you send quote requests to, and give it '
              'the manufacturers or the categories it sells.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        // REORDERABLE, because the order is a rule rather than a preference:
        // it decides which vendor wins when two claim the same manufacturer.
        // Nudging a vendor five places with an arrow button is five presses
        // and five re-reads of the list; dragging it is one gesture that shows
        // the answer while you are making it.
        sliver: SliverReorderableList(
          itemCount: vendors.length,
          onReorderItem: provider.reorderProjectVendor,
          itemBuilder: (context, index) => _VendorCard(
            // Keyed by the VENDOR, not the row. The list needs it to animate a
            // drag, and the card's own open/closed state has to travel with
            // the vendor rather than stay behind on the position it left.
            key: ValueKey(vendors[index].id),
            index: index,
            vendor: vendors[index],
            package: estimate.packageFor(vendors[index].id),
            currency: estimate.currency,
            isFirst: index == 0,
            isLast: index == vendors.length - 1,
          ),
        ),
      ),
  ];
}

/// One vendor: its name, and — once opened — the rules that tag parts to it.
///
/// CLOSED BY DEFAULT, showing the name and nothing else.
///
/// A vendor's card is two text fields, two rule editors and a notes box, and a
/// job with six vendors was six of those stacked down a page. The thing that
/// screen is actually FOR is the ORDER — which vendor claims a part first —
/// and the order was the one thing you could not see, because two vendors
/// never fitted on screen together. Collapsed, the whole list is one screen and
/// the priority is readable at a glance; the rules are one press away for the
/// one vendor being edited.
class _VendorCard extends StatefulWidget {
  final int index;
  final ProjectVendor vendor;
  final VendorPackage? package;
  final String currency;
  final bool isFirst;
  final bool isLast;

  const _VendorCard({
    super.key,
    required this.index,
    required this.vendor,
    required this.package,
    required this.currency,
    required this.isFirst,
    required this.isLast,
  });

  @override
  State<_VendorCard> createState() => _VendorCardState();
}

class _VendorCardState extends State<_VendorCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    final facets = provider.catalogFacets;
    final vendor = widget.vendor;
    final package = widget.package;
    final currency = widget.currency;
    final isFirst = widget.isFirst;
    final isLast = widget.isLast;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // THE ROW THAT IS ALWAYS THERE. Everything below it is behind the
            // toggle.
            Row(
              children: [
                ReorderableDragStartListener(
                  key: ValueKey('vendor_drag_${vendor.id}'),
                  index: widget.index,
                  child: Tooltip(
                    message: 'Drag to change which vendor claims a part first',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                // The position, because it IS the rule. A list whose order
                // decides the answer should say what the order is rather than
                // leave it to be counted.
                SizedBox(
                  width: 26,
                  child: Text(
                    '${widget.index + 1}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    key: ValueKey('vendor_toggle_${vendor.id}'),
                    onTap: () => setState(() => _open = !_open),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            _open ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              vendor.name.trim().isEmpty
                                  ? '(unnamed vendor)'
                                  : vendor.name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // A closed card still has to say what the vendor CLAIMS -
                // otherwise the collapsed list is a list of names and the
                // priority order is unreadable for a different reason.
                if (!_open) ...[
                  Flexible(
                    child: Text(
                      [
                        ...vendor.manufacturers,
                        ...vendor.categories,
                      ].take(4).join(', '),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (package != null)
                  Chip(
                    label: Text(
                      '${package.lines.length} lines  ·  '
                      '${formatMoney(package.total, currency)}',
                    ),
                  ),
                // Kept beside the handle rather than replaced by it: a drag is
                // the fast way and not the only way, and these are the two
                // that work from a keyboard.
                IconButton(
                  tooltip: 'Higher priority',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: isFirst
                      ? null
                      : () => provider.moveProjectVendor(vendor.id, -1),
                ),
                IconButton(
                  tooltip: 'Lower priority',
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: isLast
                      ? null
                      : () => provider.moveProjectVendor(vendor.id, 1),
                ),
                IconButton(
                  tooltip: 'Remove this vendor and every tag pointing at it',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => provider.removeProjectVendor(vendor.id),
                ),
              ],
            ),
            if (!_open) const SizedBox.shrink() else ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: LiveTextField(
                    fieldId: 'vendor_name_${vendor.id}',
                    initial: vendor.name,
                    label: 'Vendor',
                    onChanged: (v) =>
                        provider.updateProjectVendor(vendor.copyWith(name: v)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: LiveTextField(
                    fieldId: 'vendor_contact_${vendor.id}',
                    initial: vendor.contact,
                    label: 'Contact',
                    hint: 'who the RFQ goes to',
                    onChanged: (v) => provider.updateProjectVendor(
                      vendor.copyWith(contact: v),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _RuleEditor(
              label: 'Manufacturers',
              hint: 'Extron',
              helper: 'Every part by these makers goes to this vendor.',
              values: vendor.manufacturers,
              suggestions: facets.manufacturers,
              onChanged: (v) => provider.updateProjectVendor(
                vendor.copyWith(manufacturers: v),
              ),
            ),
            const SizedBox(height: 8),
            _RuleEditor(
              label: 'Categories',
              hint: 'Camera',
              helper:
                  'Matches finer categories too - "Camera" claims '
                  '"Camera - PTZ". Checked after the manufacturer rules.',
              values: vendor.categories,
              suggestions: facets.categories,
              onChanged: (v) =>
                  provider.updateProjectVendor(vendor.copyWith(categories: v)),
            ),
            const SizedBox(height: 8),
            LiveTextField(
              fieldId: 'vendor_notes_${vendor.id}',
              initial: vendor.notes,
              label: 'Notes on the quote request',
              maxLines: 2,
              onChanged: (v) =>
                  provider.updateProjectVendor(vendor.copyWith(notes: v)),
            ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A list of rule strings as removable chips, with an autocomplete to add one.
///
/// The autocomplete draws on the catalog rather than being free text with a
/// hint, because a rule is matched EXACTLY: "Extron Electronics" typed into a
/// catalog that says "Extron" is a rule that silently matches nothing, and
/// nothing about the screen would say so.
class _RuleEditor extends StatefulWidget {
  final String label;
  final String hint;
  final String helper;
  final List<String> values;
  final List<String> suggestions;
  final ValueChanged<List<String>> onChanged;

  const _RuleEditor({
    required this.label,
    required this.hint,
    required this.helper,
    required this.values,
    required this.suggestions,
    required this.onChanged,
  });

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

/// ADDING RULES IS A RUN, NOT A SINGLE ACT. Nobody gives a vendor one
/// category; they give it six, one after another, off a list they are reading.
///
/// So the box has to survive its own success. Three things used to go wrong the
/// moment a value was added, all of them because adding one rebuilds the whole
/// tab underneath it:
///
///   * The field was rebuilt from scratch. It sits in a Wrap AFTER the chips,
///     so adding one moved it a position along and Flutter matched it to the
///     chip that had taken its place — new controller, new focus node, cleared
///     text, closed list. Its state is owned here now, and the box is keyed.
///   * The focus went with it, so the next value meant reaching for the mouse.
///     Focus is put straight back.
///   * The new chip pushed the box down a row, and on a card near the bottom
///     of a long list of vendors that is a box that has left the screen. It is
///     scrolled back into view after every add.
class _RuleEditorState extends State<_RuleEditor> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// What the field itself is, for scrolling it back into view — the widget
  /// tree above it is rebuilt on every add, so a context captured in build
  /// would be a context that has gone.
  final GlobalKey _fieldKey = GlobalKey();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Takes one value, then puts the box back where it was, ready for the next.
  void _add(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    if (widget.values.any((v) => v.toLowerCase() == trimmed.toLowerCase())) {
      _controller.clear();
      return;
    }
    widget.onChanged([...widget.values, trimmed]);
    _controller.clear();
    // After the frame the new chip lands in: the box has moved by then, and
    // scrolling to where it used to be would scroll to the wrong place.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      final box = _fieldKey.currentContext;
      if (box != null) {
        Scrollable.ensureVisible(
          box,
          alignment: 0.5,
          duration: const Duration(milliseconds: 150),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unused = [
      for (final s in widget.suggestions)
        if (!widget.values.any((v) => v.toLowerCase() == s.toLowerCase())) s,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          widget.helper,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final v in widget.values)
              InputChip(
                key: ValueKey('rule_chip_${widget.label}_$v'),
                label: Text(v),
                onDeleted: () => widget.onChanged([
                  for (final x in widget.values)
                    if (x != v) x,
                ]),
              ),
            SizedBox(
              // Keyed so it is matched to itself rather than to whichever chip
              // has taken its place in the Wrap.
              key: ValueKey('rule_add_${widget.label}'),
              width: 220,
              child: RawAutocomplete<String>(
                textEditingController: _controller,
                focusNode: _focus,
                optionsBuilder: (value) {
                  final needle = value.text.trim().toLowerCase();
                  if (needle.isEmpty) return const Iterable<String>.empty();
                  return unused.where((s) => s.toLowerCase().contains(needle));
                },
                onSelected: _add,
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 240,
                        maxWidth: 220,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: options.length,
                        itemBuilder: (context, i) {
                          final option = options.elementAt(i);
                          return InkWell(
                            onTap: () => onSelected(option),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Text(option),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) =>
                        TextField(
                          key: _fieldKey,
                          controller: controller,
                          focusNode: focusNode,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'add, e.g. ${widget.hint}',
                            border: const OutlineInputBorder(),
                          ),
                          onSubmitted: _add,
                        ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
