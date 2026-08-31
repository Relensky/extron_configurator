import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui show lerpDouble;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart'
    show PricingTier, kPricingTierLabels, kPricingTierShort;
import 'av_flow_swap_dialogs.dart' show pickCatalogModel;
import 'building_project.dart';
import 'color_wheel_picker.dart';
import 'contrast.dart';
import 'control_gaps.dart' show ControlGap;
import 'cost_estimate.dart';
import 'live_text_field.dart';
import 'manual_room_lines.dart';
import 'name_colors.dart';
import 'part_sort.dart';
import 'pinned_grid.dart' show gridMetric;
import 'project_briefing_dialog.dart';
import 'project_deliveries_view.dart';
import 'online_copy_dialog.dart';
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
import 'vendor_rfq_view.dart';
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
  // WHAT HAPPENED AFTER THE ORDER WENT IN - the purchase orders it went out
  // on, what has landed, and where that kit is now. Straight after the
  // timeline because it is the other half of the same story: the timeline
  // says when each part has to be bought, this says what turned up.
  deliveries('Deliveries', Icons.inventory),
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

/// The palette offered when a colour is assigned by hand.
///
/// The same twelve the derived colours come out of, so an assigned colour and
/// a derived one belong to one set rather than looking like two systems on one
/// page. Any other colour is one press further on, through the wheel.
const List<Color> kVendorPalette = kNameTintWheel;

/// Assigns [vendor] a colour, or takes it back to the derived one.
///
/// A dialog rather than an inline row of swatches: the vendor list is a list
/// of ORDERS in priority order, and twelve swatches on every row would bury
/// the one thing that list is read for.
Future<void> showVendorColorDialog(
  BuildContext context,
  ProjectVendor vendor,
) async {
  final provider = context.read<AppStateProvider>();
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        // Re-read the vendor every rebuild: the swatch that reads as chosen
        // has to be the one the project actually holds.
        final current = provider.project.vendors
                .where((v) => v.id == vendor.id)
                .firstOrNull ??
            vendor;
        final assigned = current.color;
        final shown = projectVendorColor(current);

        return AlertDialog(
          key: const ValueKey('vendor_color_dialog'),
          title: Text(
            current.name.trim().isEmpty
                ? 'Colour for this vendor'
                : 'Colour for ${current.name}',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Every part this vendor is quoting is marked in this colour '
                  'on the equipment list, so one order can be read down the '
                  'page at a glance.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in kVendorPalette)
                      ColorSwatchButton(
                        key: ValueKey(
                          'vendor_color_${vendor.id}_'
                          '${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}',
                        ),
                        color: c,
                        selected: shown.toARGB32() == c.toARGB32(),
                        onTap: () => setLocal(
                          () => provider.updateProjectVendor(
                            current.copyWith(color: c.toARGB32()),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('vendor_color_custom'),
                      icon: const Icon(Icons.colorize, size: 16),
                      label: const Text('Any other colour'),
                      onPressed: () async {
                        final picked = await showColorWheelDialog(
                          ctx,
                          initial: shown,
                          title: 'Colour for ${current.name}',
                        );
                        if (picked == null) return;
                        setLocal(
                          () => provider.updateProjectVendor(
                            current.copyWith(color: picked.toARGB32()),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    // Back to the colour the name gives it. Disabled while
                    // nothing has been assigned, so the button says whether
                    // this vendor's colour was chosen or derived.
                    TextButton.icon(
                      key: const ValueKey('vendor_color_auto'),
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('Automatic'),
                      onPressed: assigned == null
                          ? null
                          : () => setLocal(
                              () => provider.updateProjectVendor(
                                current.copyWith(clearColor: true),
                              ),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              key: const ValueKey('vendor_color_done'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
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
///
/// IT IS A WIDTH IN TYPE, NOT IN PIXELS. Everything it measures - two prose
/// fields, nine labelled panes - is text, so the threshold is put through
/// [gridMetric] at the point of use: on a display at 150% the labels are half
/// again as wide and the window that could hold them is half again as wide
/// too. Before that, a 1400-pixel window at 150% counted as roomy and the pane
/// rail laid out nine full labels in the space of six.
const double kProjectHeaderCompactWidth = 1040;

/// Whether every pane label still fits on ONE LINE across [available] pixels.
///
/// WHY THIS IS MEASURED RATHER THAN READ OFF A WINDOW WIDTH. A
/// [SegmentedButton] hands every segment the width of the WIDEST one and then
/// clamps that to its own width divided by the number of segments. So the
/// moment the longest label needs more than its ninth of the row, every
/// segment is squeezed to a ninth and the long ones - 'Responsibility' first -
/// wrap onto a second line inside a button. A fixed threshold cannot catch
/// that: the label set changes when the to-do count appears, the type is the
/// theme's rather than a number, and at 130% text a 1200-pixel window holds
/// what a 900-pixel one holds at 100%.
///
/// Measuring the widest label settles the whole question, because that is the
/// one the layout sizes every other segment from: if it fits, they all do.
///
/// THE ARITHMETIC IS MATERIAL'S OWN, not an estimate with slack in it. A
/// segment carrying an icon is built exactly as `TextButton.icon` is - see
/// `segmented_button.dart` - so its natural width is the button's padding,
/// then the icon, then the gap, then the unwrapped label. Both the padding and
/// the gap shrink as the app's text grows, and guessing either would drop the
/// labels on a window that could have held them.
bool _paneLabelsFit(BuildContext context, double available, int openTodos) {
  // Nothing to go on - before the first layout, or a pane with no width. Keep
  // the labels; the next frame has a real number.
  if (available <= 0) return true;

  final theme = Theme.of(context);
  final style = theme.textTheme.labelLarge ?? const TextStyle(fontSize: 14);
  final scaler = MediaQuery.textScalerOf(context);

  double widest = 0;
  for (final pane in _ProjectPane.values) {
    final painter = TextPainter(
      text: TextSpan(text: _paneLabel(pane, openTodos), style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    widest = math.max(widest, painter.width);
  }

  // How far up the type scale the app is, as Material measures it: the size a
  // 14pt label actually paints at, over 14.
  final textScale = scaler.scale(style.fontSize ?? 14) / (style.fontSize ?? 14);
  // 12 before the icon and 16 after the label at 1x, lerping to 4 either side
  // by 2x - the two geometries `TextButton.icon` is padded between.
  final padding = textScale <= 1
      ? 28.0
      : textScale < 2
          ? ui.lerpDouble(28, 8, textScale - 1)!
          : 8.0;
  // The gap between the icon and the word, which closes the same way.
  final gap = ui.lerpDouble(8, 4, math.min(1, math.max(0, textScale - 1)))!;

  final segment = widest + gridMetric(context, 18) + padding + gap;
  return segment * _ProjectPane.values.length <= available;
}

/// The word on a pane's segment — with the open count on the to-do one, which
/// is part of the label and therefore part of what has to fit.
String _paneLabel(_ProjectPane pane, int openTodos) =>
    pane == _ProjectPane.todo && openTodos > 0
        ? '${pane.label} ($openTodos)'
        : pane.label;

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

  // -------------------------------------------------------------------------
  //  HOW THE PARTS LIST IS BEING READ
  // -------------------------------------------------------------------------
  //  Both of these are ways of LOOKING at the master list rather than facts
  //  about the job, so both live here and neither is written to the file. A
  //  project that reopened sorted by price, with four rows still ticked from
  //  last Tuesday, would be handing the next reader a different document.

  /// Which column the list is ordered by, and which way - see [PartSortKey].
  PartSortKey _partSort = PartSortKey.natural;
  bool _partSortAscending = true;

  /// The parts ticked for a bulk edit, by [MasterPartLine.key].
  final Set<String> _selectedParts = <String>{};

  /// Sorts by the column that was pressed, or unsorts when it was already
  /// pointing down - see [nextPartSort].
  void _sortParts(PartSortKey pressed) => setState(() {
    final next = nextPartSort(
      current: _partSort,
      ascending: _partSortAscending,
      pressed: pressed,
    );
    _partSort = next.key;
    _partSortAscending = next.ascending;
  });

  /// Ticks or unticks one part.
  void _toggleSelectedPart(String key) => setState(() {
    if (!_selectedParts.remove(key)) _selectedParts.add(key);
  });

  /// Ticks everything currently on screen, or clears it when it is all ticked.
  ///
  /// SCOPED TO WHAT IS SHOWING, deliberately. The filters above the list are
  /// how somebody says "the Extron parts" or "the ones with no price", and a
  /// Select all that reached past them into the other hundred and eighty rows
  /// would be a bulk edit nobody could see the scope of.
  void _selectShownParts(List<String> keys) => setState(() {
    if (keys.every(_selectedParts.contains)) {
      _selectedParts.removeAll(keys);
    } else {
      _selectedParts.addAll(keys);
    }
  });

  void _clearSelectedParts() => setState(_selectedParts.clear);

  /// One controller for the whole tab, so the scrollbar has something to drag
  /// and switching panes can put the view back at the top — landing halfway
  /// down a different list is disorienting.
  final ScrollController _scroll = ScrollController();

  /// The last pane request this tab acted on — see
  /// [AppStateProvider.projectPaneRequestId].
  ///
  /// Compared rather than cleared: clearing it would be a write to the provider
  /// from inside a build, and leaving it unread would snap the tab back to the
  /// requested pane on every rebuild, which is a reader who cannot move off it.
  int _honouredPaneRequest = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Called whenever the provider notifies, because build() watches it. Safe
    // to set _pane here without setState: this runs immediately before build.
    final provider = context.read<AppStateProvider>();
    if (provider.projectPaneRequestId == _honouredPaneRequest) return;
    _honouredPaneRequest = provider.projectPaneRequestId;
    final wanted = provider.requestedProjectPane;
    for (final pane in _ProjectPane.values) {
      if (pane.name == wanted) {
        _pane = pane;
        break;
      }
    }
    // THE JUMP CARRIES WHAT IT WAS ABOUT. A request that names a filter was
    // made from a sentence about those rows - "19 parts go to Extron" - and
    // landing on four hundred unfiltered rows makes the reader ask their own
    // question again. The search and the room narrowing go with it, for the
    // reason on [_setVendorFilter]: a filter nobody can see on screen is a
    // list quietly missing rows.
    final filter = provider.requestedPartsVendorFilter;
    if (filter.isNotEmpty) {
      _vendorFilter = filter;
      _spareRoom = '';
      _search = '';
    }
  }

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
              sort: _partSort,
              sortAscending: _partSortAscending,
              onSort: _sortParts,
              selected: _selectedParts,
              onToggleSelected: _toggleSelectedPart,
              onSelectShown: _selectShownParts,
              onClearSelected: _clearSelectedParts,
            ),
            _ProjectPane.plans => plansSlivers(context, estimate),
            _ProjectPane.timeline => timelineSlivers(context, estimate),
            _ProjectPane.deliveries =>
              deliveriesSlivers(context, estimate),
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
    // EVERYTHING THAT WOULD MAKE THIS QUOTE WRONG TO SEND, in one number. A
    // part no vendor claims never reaches an order, and a box with no control
    // module arrives and cannot be commissioned - both are things to fix
    // before the job goes out, and both used to be spelled out in the tooltip
    // of a chip whose count had already decided they were nothing.
    final warnings =
        estimate.failedRooms +
        estimate.unpricedParts +
        estimate.untaggedParts +
        estimate.undrivenDevices +
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
    final compact =
        box.maxWidth < gridMetric(context, kProjectHeaderCompactWidth);

    // THE SWITCHER GIVES UP ITS LABELS WHEN THEY NO LONGER FIT ON A LINE, not
    // when the window crosses [kProjectHeaderCompactWidth]. That threshold is
    // the HEADER's - it says when four identity fields stop fitting side by
    // side - and a switcher of nine segments runs out of room before the
    // fields do. Between the two, 'Responsibility' was being wrapped onto a
    // second line inside its own button, which is a label nobody can read on a
    // control that has grown half a row taller than the ones beside it.
    //
    // Below the header's threshold the labels go anyway: the whole strip is in
    // icon mode there and a switcher that kept its words while the buttons
    // above it lost theirs would read as a different kind of control.
    //
    // The 32 is this Padding's own, taken off before the width is measured
    // against - the switcher gets the inside of the header, not the outside.
    final paneCompact =
        compact || !_paneLabelsFit(context, box.maxWidth - 32, openTodos);

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
                  // THE SAME BOOK, WHERE OTHER PEOPLE CAN READ IT. Beside the
                  // Workbook button because it writes the same document - the
                  // difference is only where it lands, and that a link to it
                  // keeps working. See online_copy.dart.
                  _action(
                    compact: compact,
                    icon: Icons.cloud_sync_outlined,
                    label: 'Online copy',
                    emphasis: _ActionEmphasis.tonal,
                    buttonKey: const ValueKey('project_online_copy'),
                    onPressed: () => showOnlineCopyDialog(context, provider),
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
              // WHICH OF THE CATALOG'S TWO PRICES EVERY FIGURE ABOVE IS
              // COSTED FROM. The room's estimate has carried this switch for a
              // while; the project total is where the question is actually
              // asked, because the figure somebody sends out is this one and
              // an education price on a job quoted at list is the difference
              // between winning it and not.
              Tooltip(
                message: 'Which of the two published prices the whole '
                    'job is costed from',
                child: SegmentedButton<PricingTier>(
                  key: const ValueKey('project_pricing_tier'),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    for (final t in PricingTier.values)
                      ButtonSegment(
                        value: t,
                        label: Text(kPricingTierShort[t] ?? t.name),
                        tooltip: kPricingTierLabels[t],
                      ),
                  ],
                  selected: {provider.pricingTier},
                  onSelectionChanged: (s) => provider.setPricingTier(s.first),
                ),
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
                      : estimate.untaggedParts > 0
                      ? '${_warningTooltip(estimate)}'
                            '\n\nClick to list the parts with no vendor.'
                      // A COUNT THAT COULD NOT BE PRESSED. The chip has always
                      // linked the price and vendor faults to the rows they
                      // are about, and left the undriven devices as a number -
                      // so the one fault whose fix is in another room was the
                      // one nothing would take you to.
                      : estimate.undrivenDevices > 0
                      ? '${_warningTooltip(estimate)}'
                            '\n\nClick to list the parts with no control '
                            'module, and the rooms they are in.'
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
                    // Straight to the rows it is talking about. Unpriced
                    // first when there are both: a part with no price makes
                    // the TOTAL wrong, which is worse than a part that is
                    // merely on nobody's order yet.
                    onPressed:
                        estimate.unpricedParts > 0 ||
                            estimate.untaggedParts > 0 ||
                            estimate.undrivenDevices > 0
                        ? () => setState(() {
                              _pane = _ProjectPane.parts;
                              _vendorFilter = estimate.unpricedParts > 0
                                  ? _unpricedFilter
                                  : estimate.untaggedParts > 0
                                  ? _untaggedFilter
                                  : _undrivenFilter;
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
                      // THE KEY IS ON WHICHEVER HALF IS SHOWING. A segment is
                      // the pane, and which of its two shapes is on screen is
                      // a question about the width of the window - so anything
                      // looking for a pane has to find it either way. When the
                      // label is there it carries the key; when it has gone,
                      // the icon does.
                      icon: Icon(
                        pane.icon,
                        size: gridMetric(context, 18),
                        key: paneCompact
                            ? ValueKey('project_pane_${pane.name}')
                            : null,
                      ),
                      // The label goes when the window cannot hold all of
                      // them. Eight labelled segments are wider than a narrow
                      // window on their own, and a switcher that overflows is
                      // a pane nobody can reach — the icons are the same eight
                      // targets, in the same order, with the name on a
                      // tooltip.
                      tooltip: paneCompact
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
                      label: paneCompact
                          ? null
                          : Text(
                              _paneLabel(pane, openTodos),
                              key: ValueKey('project_pane_${pane.name}'),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                ],
                selected: {_pane},
                onSelectionChanged: (s) => _showPane(s.first),
                // With the labels gone the icon IS the pane, so the selected
                // one must keep it. The default swaps in a tick, which on a
                // labelled switcher marks the choice and on this one erases
                // the only thing naming it.
                showSelectedIcon: !paneCompact,
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

  /// The project's name, building and project number.
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
      fieldId: 'project_number_${provider.currentProjectPath}',
      initial: provider.project.projectNumber,
      label: 'Project number',
      onChanged: (v) => provider.setProjectField(projectNumber: v),
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
    if (estimate.untaggedParts > 0)
      '${estimate.untaggedParts} part(s) are tagged to no vendor - they are on '
          'no order as things stand.',
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
    // far as its own contrast holds. Faded to 75% and re-measured rather than
    // assumed: 75% of an ink that only just cleared the threshold does not.
    //
    // MEASURED AS THE SMALL TEXT IT IS. This asked for the large-text bar of
    // 3:1 while being drawn at eleven points, which on a slate accent put
    // "Project total" on its own fill at 4.45:1 - under the bar for body text,
    // and the caption over the one figure this tab exists for.
    final labelInk = readableOn(
      fill,
      prefer: [Color.alphaBlend(ink.withValues(alpha: 0.75), fill), ink],
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
  // The rooms with no config file behind them - see manual_room_lines.dart.
  // Off the project rather than off the estimate: they are not priced from
  // parts, so the estimate has nothing to say about them.
  final lines = provider.project.manualRooms;

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        // WRAPPED, AND THE SENTENCE ON ITS OWN LINE.
        //
        // It used to be a Row of two buttons with the note Expanded into
        // whatever was left. A third button is one more than that arrangement
        // can carry: at 700px the note had no room to shrink into and the Row
        // overflowed, which paints the striped bar over the button rather than
        // moving it. A Wrap drops whatever does not fit onto the next line, so
        // every door is still reachable on a narrow window, and the note sits
        // under them where it reads as a note rather than as a fourth control.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
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
                // THE THIRD KIND OF ROOM. Most of an estate has never
                // been through this app, and a job imported off a refresh
                // spreadsheet has no config files at all - see
                // manual_room_lines.dart. Offered beside the other two
                // rather than buried, because on those jobs it is the only
                // one of the three that does anything.
                const AddManualRoomLineButton(),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Rooms are references. Fix a price on the room’s own Cost tab, '
              'then Refresh. A line item is priced here.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
    // A JOB CAN BE ALL LINE ITEMS. An empty room list used to be the end of
    // this pane, which read as "there is nothing on this job" on the exact
    // jobs where there are thirty-four rooms on a refresh plan - they simply
    // have no config files behind them. The pane is empty only when BOTH
    // lists are.
    if (estimate.rooms.isEmpty && lines.isEmpty)
      const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No rooms on this project yet.\n\n'
              'Add the config.json files for the rooms in this building and '
              'they will be priced together. Or add a line item for a room '
              'nobody has drawn, and it goes on the replacement plan with a '
              'date, a life and a figure.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else ...[
      if (estimate.rooms.isNotEmpty)
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
      // THE ROOMS WITH NO CONFIG, ON A LIST OF THEIR OWN.
      //
      // Not mixed in with the drawn ones: the two are different kinds of row -
      // one is priced from its parts and one is a figure somebody typed - and
      // interleaving them would put an estimate and a quote under the same
      // heading. Below rather than above, because on a job that has both, the
      // drawn rooms are the ones with something to check.
      if (lines.isNotEmpty) ...[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16,
            estimate.rooms.isEmpty ? 4 : 18,
            16,
            8,
          ),
          sliver: SliverToBoxAdapter(
            child: ManualRoomLinesHeading(count: lines.length),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.separated(
            itemCount: lines.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) => ManualRoomLineCard(
              room: lines[index],
              currency: estimate.currency,
            ),
          ),
        ),
      ],
      // Its own sliver rather than the last row of the list, so it is exactly
      // as tall as its contents and can never end up scrolling inside the
      // scroll it already sits in.
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        sliver: SliverToBoxAdapter(child: _BuildingTotals(estimate: estimate)),
      ),
    ],
  ];
}

// ---------------------------------------------------------------------------
//  FROM A FLAG TO THE THING IT IS ABOUT
// ---------------------------------------------------------------------------
//  A flag on the project tab names a fault in a ROOM - three lines with no
//  price, a device with no driver - and the place that fault is fixed is a
//  room-level page one room-switch and one tab away. Reading the flag and then
//  hunting for the room in the picker is most of the work of acting on it,
//  which is why flags get read and not acted on.
//
//  DOUBLE-CLICK, NOT CLICK. Every one of these targets already had a single
//  click that does something useful and smaller - copy the list, set the
//  price - and taking that away to add a jump would be trading a control
//  somebody uses for one they might. A double-click is the ordinary gesture
//  for "open this", it is free on all three, and the tooltip on each says so
//  rather than leaving it to be discovered.

/// Makes [ref] the open room and lands on [tab] — the page the flag is about.
///
/// Goes through the SAME unsaved-work prompt every other way of switching
/// rooms does: switching reads the next room off disk, and two doors into one
/// action must not have two different answers to that question. A room that is
/// already open skips straight to the tab, prompt and all — there is nothing
/// being left.
///
/// [what] is what the reader is being sent to look at, and it goes in the
/// confirmation: landing on a different tab is a big enough move that it has
/// to be narrated, or it reads as the app having lost the project.
Future<void> openProjectRoomOn(
  BuildContext context,
  ProjectRoomRef ref,
  AppTab tab,
  String what, {
  /// What to call the room in the confirmation — the name the reader was just
  /// looking at, which is not always the file's own.
  String roomName = '',

  /// The config section the page should open ON, when the flag is about one
  /// device rather than about the room — see
  /// [AppStateProvider.requestedDeviceKey]. Landing on the first of fourteen
  /// device tabs is most of the work of acting on a flag.
  String deviceKey = '',
}) async {
  final provider = context.read<AppStateProvider>();
  final messenger = ScaffoldMessenger.of(context);
  if (deviceKey.isNotEmpty) provider.requestDevice(deviceKey);

  if (provider.openProjectRoom?.id != ref.id) {
    if (!await confirmLeavingRoom(context, provider)) return;
    if (!context.mounted) return;
    final error = await provider.openProjectRoomRef(ref);
    if (error.isNotEmpty) {
      showTimedSnackBar(
        messenger,
        SnackBar(
          content: Text(error),
          backgroundColor: snackErrorFillOn(messenger),
        ),
      );
      return;
    }
    if (!context.mounted) return;
  }

  provider.selectTab(tab.index);
  showTimedSnackBar(
    messenger,
    SnackBar(
      duration: const Duration(seconds: 3),
      content: Text(
        '${roomName.trim().isEmpty ? ref.fallbackName : roomName}: $what',
      ),
    ),
  );
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

    final include = Tooltip(
      message: room.ref.included
          ? 'Counted in the project total'
          : 'Kept on the job but out of the total - an alternate, or a later '
                'phase',
      child: Checkbox(
        value: room.ref.included,
        onChanged: (v) =>
            provider.updateProjectRoom(room.ref.id, included: v ?? true),
      ),
    );

    final name = _NameTarget(
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
              // Struck through when the room is off the total, and underlined
              // while the pointer is over it — the two never coincide, because
              // the open room is not a way in to itself.
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
          // The room in the editor is priced from MEMORY, so its row can be
          // ahead of its own file. Saying so is the price of that: a total
          // nobody can reconcile with the folder is a total nobody trusts.
          if (isOpen)
            Row(
              children: [
                Icon(Icons.edit_note, size: 13, color: ink),
                const SizedBox(width: 4),
                // Expanded, because the unsaved wording is half a sentence
                // longer than the plain one and the column it sits in is
                // whatever the figures beside it leave over.
                Expanded(
                  child: Text(
                    unsaved
                        ? 'Open in the editor - counted with its unsaved '
                              'changes'
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
    );

    // THE THREE FIGURES, AS A BLOCK. They belong together — equipment plus
    // labor IS the room total — so they move together when the row runs out of
    // width rather than being squeezed one by one until the last two touch.
    final figures = e == null
        ? null
        : <Widget>[
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
          ];

    // WHAT IS TRUE ABOUT THIS ROOM that no other column asks — the asbestos
    // above the grid, the wall it shares with the studio.
    //
    // Editable here rather than read-only, because the moment somebody wants
    // to write one is while they are looking at the room list; sending them to
    // the Notes pane to type it is how it ends up in an email instead. The
    // same field, either way — the Notes pane and this column write to the
    // same place.
    //
    // One line, because a row is a row. The full text is in the tooltip and on
    // the Notes pane, which is where a long one belongs.
    final notes = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Notes', style: theme.textTheme.labelSmall?.copyWith(color: quiet)),
        Tooltip(
          message: room.ref.notes.trim().isEmpty
              ? 'Anything true of this room that the other columns do not '
                    'say. Goes out beside it on the workbook.'
              : room.ref.notes,
          child: LiveTextField(
            key: ValueKey('room_row_notes_${room.ref.id}'),
            fieldId: 'room_row_notes_${room.ref.id}',
            initial: room.ref.notes,
            hint: 'e.g. asbestos above the grid, contact facilities',
            onChanged: (v) =>
                provider.updateProjectRoom(room.ref.id, notes: v),
          ),
        ),
      ],
    );

    // WHAT IS FLAGGED, WORKED OUT ONCE. The list is a pass over the room's
    // estimate, and it was being built three times to draw one icon -
    // once to ask whether there was anything to say, once for the tooltip
    // and once more inside it.
    final flags = e == null ? const <String>[] : _roomFlags(room);

    final actions = <Widget>[
      // WHAT IS ODD ABOUT THIS ROOM. Bigger than the buttons beside it on
      // purpose: it is the one thing on the row that is not always there, and
      // at 18 pixels in the quiet ink it read as decoration.
      //
      // Pressing it COPIES. What it lists is the answer to "why is this room's
      // total short", and that question is nearly always being asked by
      // somebody who is not in front of the app: a tooltip can only be read,
      // and a list that has to be retyped into a message is one that arrives
      // shortened.
      //
      // DOUBLE-CLICKING GOES THERE. Nearly everything on this list is a
      // fault in one room's COST - lines with no price, labor with no rate
      // - and the page that fixes it is that room's own Cost tab. A room
      // with nothing on it at all is the exception and lands on the
      // drawing instead, because there is no cost to go and look at yet.
      //
      // An InkWell rather than an IconButton for exactly that: a button
      // has one gesture and this target needs two - the copy AND the jump.
      // Padded to the size of the button it replaces so the row does not
      // shift under it.
      if (e != null && flags.isNotEmpty)
        Tooltip(
          message:
              '${flags.join('\n')}\n\n'
              'Click to copy  ·  Double-click to open '
              '${room.room.isEmpty ? 'the drawing' : 'this room\'s Cost page'}',
          child: InkWell(
            key: ValueKey('room_row_flags_${room.ref.id}'),
            customBorder: const CircleBorder(),
            onTap: () => _copyFlags(room, flags),
            onDoubleTap: () => openProjectRoomOn(
              context,
              room.ref,
              room.room.isEmpty ? AppTab.avFlow : AppTab.cost,
              room.room.isEmpty
                  ? 'nothing is drawn in here yet'
                  : 'what the flag is about is on this page',
              roomName: room.name,
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.info_outline, size: 24, color: quiet),
            ),
          ),
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
    ];

    return Card(
      margin: EdgeInsets.zero,
      color: fill,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        // THE FIGURES DROP TO THEIR OWN LINE BEFORE THEY COLLIDE. Three money
        // columns, a notes field and four buttons do not fit beside a room
        // name on a narrow window — and at 150% no window is wide. Squeezed on
        // one line, Labor and Room total ended up touching, which on a sheet
        // of figures is two numbers read as one. Below the threshold the row
        // becomes two: what the room IS, then what it COSTS.
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth >= gridMetric(context, 900)) {
              return Row(
                children: [
                  include,
                  Expanded(flex: 3, child: name),
                  if (figures != null)
                    ...figures
                  else
                    const Expanded(flex: 3, child: SizedBox()),
                  const SizedBox(width: 8),
                  Expanded(flex: 3, child: notes),
                  const SizedBox(width: 4),
                  ...actions,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    include,
                    Expanded(child: name),
                    ...actions,
                  ],
                ),
                if (figures != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Row(children: figures),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: notes,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Puts the room's flags on the clipboard, named so the paste stands alone.
  ///
  /// The room's code leads, because a bare list of "3 line(s) have no price"
  /// pasted into a message is a fact with no subject.
  Future<void> _copyFlags(
    ProjectRoomCost room,
    List<String> flags,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
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
      // A GAP THAT CANNOT BE SQUEEZED OUT. Three right-aligned figures in
      // three Expandeds have nothing between them but whatever slack is left,
      // and on a narrow card there is none - which put the end of Labor
      // against the start of Room total.
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: quiet),
            ),
            Text(
              value,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: bold ? FontWeight.bold : null,
                color: ink,
              ),
            ),
          ],
        ),
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

/// THE ROOMS WITH DEVICES NOTHING WILL DRIVE, as rooms.
///
/// The master list answers "which parts have no driver" — the right question
/// when the fix is to write a driver or retire a product, and the wrong one
/// when the fix is to pick a module on a device. That fix happens in a ROOM,
/// on its Devices page, one room at a time, and working out which rooms those
/// are meant reading every filtered row and keeping a tally.
///
/// So the same facts, turned round: a room a line, what is undriven in it, and
/// the way in. Shown only while the list is filtered to the undriven parts,
/// because that is when it is the question being asked.
class _DriverGapRooms extends StatelessWidget {
  final ProjectEstimate estimate;

  const _DriverGapRooms({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (estimate.controlGaps.isEmpty) return const SizedBox.shrink();

    // Room -> what is undriven in it, worst first. A room with six is the one
    // to open, and a list that ordered them by name would hide it.
    final byRoom = <String, ({ProjectRoomCost room, List<ControlGap> gaps})>{};
    for (final entry in estimate.controlGaps) {
      final at = byRoom[entry.room.ref.id];
      byRoom[entry.room.ref.id] = (
        room: entry.room,
        gaps: [...?at?.gaps, entry.gap],
      );
    }
    final rooms = byRoom.values.toList()
      ..sort((a, b) {
        final byCount = b.gaps
            .fold<int>(0, (s, g) => s + g.qty)
            .compareTo(a.gaps.fold<int>(0, (s, g) => s + g.qty));
        return byCount != 0
            ? byCount
            : a.room.name.toLowerCase().compareTo(b.room.name.toLowerCase());
      });

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rooms affected (${rooms.length})',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                'A module is picked on a device, on the room\'s own Devices '
                'page. Open the room to fix its list.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final entry in rooms)
                _DriverGapRoomRow(room: entry.room, gaps: entry.gaps),
            ],
          ),
        ),
      ),
    );
  }
}

/// One room on the undriven list: which devices, and the way into each.
///
/// A ROOM IS NOT A DESTINATION. "BSS 103 has four undriven devices" and a
/// button that opens the room is two steps short: the reader lands on the
/// first of fourteen device tabs and starts hunting for the four the list was
/// about. So the devices are named one to a line, and each line opens the page
/// that fixes THAT device — its own tab under Devices when it has a config
/// block, the signal flow when it is a box somebody drew and never added.
class _DriverGapRoomRow extends StatelessWidget {
  final ProjectRoomCost room;
  final List<ControlGap> gaps;

  const _DriverGapRoomRow({required this.room, required this.gaps});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devices = gaps.fold<int>(0, (s, g) => s + g.qty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.link_off,
                size: 15,
                color: errorTextOn(theme.colorScheme, theme.cardColor),
              ),
              const SizedBox(width: 8),
              Text(
                '${room.name}  ·  $devices device'
                '${devices == 1 ? '' : 's'}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          for (final gap in gaps)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${gap.device}${gap.qty > 1 ? '  ×${gap.qty}' : ''}'
                          '${gap.model.trim().isEmpty ? '' : '  ·  '
                              '${gap.model}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        // WHY it is on the list, which decides what to do
                        // about it: a driver to pick, a model to set, or a
                        // product that never had one.
                        Text(
                          gap.note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    key: ValueKey(
                      'gap_device_open_${room.ref.id}_'
                      '${gap.sectionKey.isEmpty ? gap.device : gap.sectionKey}',
                    ),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(
                      gap.sectionKey.isEmpty ? 'Signal flow' : 'Open device',
                    ),
                    onPressed: () => gap.sectionKey.isEmpty
                        ? openProjectRoomOn(
                            context,
                            room.ref,
                            AppTab.avFlow,
                            '${gap.device} is drawn here with no config block '
                                'behind it',
                            roomName: room.name,
                          )
                        : openProjectRoomOn(
                            context,
                            room.ref,
                            AppTab.devices,
                            'pick the control module for ${gap.device} here',
                            roomName: room.name,
                            deviceKey: gap.sectionKey,
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// THE PRODUCTS SOMEBODY HAS ALREADY SETTLED, and the way to unsettle one.
///
/// "This product never needs a module" is a decision about a PRODUCT, saved to
/// the catalog, and it silences the flag in every room on the estate. That is
/// what makes it useful and what makes it worth checking: a laptop plate
/// marked by mistake is a device that never gets a driver and never gets
/// reported again.
///
/// So the job's own settled products are listed where the undriven ones are —
/// what is flagged, how many of it this job has, and one button to take the
/// flag off and put it back on the list. It reads as an acknowledgement: go
/// down it, agree with each line, and undo the one that is wrong.
class _SettledProducts extends StatelessWidget {
  final ProjectEstimate estimate;

  const _SettledProducts({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);

    final settled = [
      for (final line in estimate.master)
        if (line.model.trim().isNotEmpty &&
            provider.avModelNeverControlled(line.model))
          line,
    ];
    if (settled.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Flagged as needing no module (${settled.length})',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                'These products are marked in the catalog as having no control '
                'interface, so no room asks for a driver for them. Check each '
                'one - and take the flag off any that does need driving.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final line in settled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.block,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              line.description.trim().isEmpty
                                  ? line.model
                                  : line.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                            Text(
                              [
                                line.model,
                                '${trimNumber(line.qty)} on this job',
                                '${line.qtyByRoom.length} room'
                                    '${line.qtyByRoom.length == 1 ? '' : 's'}',
                              ].join('  ·  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        key: ValueKey('unflag_${line.key}'),
                        icon: const Icon(Icons.undo, size: 16),
                        label: const Text('Needs a module'),
                        onPressed: () => _unflag(context, provider, line.model),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Takes the flag off, and says what that did.
  ///
  /// Straight through rather than behind a confirmation: putting a product
  /// BACK on the list of things to check is the safe direction, and the button
  /// that set the flag is one row away for anybody who changes their mind.
  Future<void> _unflag(
    BuildContext context,
    AppStateProvider provider,
    String model,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await provider.setModelNeverControlled(model, false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.message),
        backgroundColor: result.ok ? null : snackErrorFillOn(messenger),
      ),
    );
  }
}

/// Master-list filters that are not a vendor id. Ids are always `vendor<n>`,
/// so these can never collide with one by accident.
///
/// Public because the filter is a piece of state on the tab and these are two
/// of the values it takes — the header's warning chip already reaches for the
/// unpriced one the same way.
const String kSparedFilter = '<spared>';
const String kNoSpareFilter = '<no-spare>';

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

  /// Which column the list is ordered by, and which way. See [PartSortKey]:
  /// the default is the grouped order the estimate built.
  PartSortKey sort = PartSortKey.natural,
  bool sortAscending = true,
  ValueChanged<PartSortKey>? onSort,

  /// The parts ticked for a bulk edit, by [MasterPartLine.key], and the three
  /// ways that set changes. Null callbacks turn the tick boxes off entirely,
  /// which is what a caller that has nowhere to keep a selection wants.
  Set<String> selected = const {},
  ValueChanged<String>? onToggleSelected,
  ValueChanged<List<String>>? onSelectShown,
  VoidCallback? onClearSelected,
}) {
  final theme = Theme.of(context);
  final needle = search.trim().toLowerCase();
  // Only ever a narrowing of the spares list — see [_ProjectViewState].
  final sparesOnly = vendorFilter == kSparedFilter;
  // WHICH ROOMS, while the list is the undriven one. The rows name a part and
  // the rooms that have it; the question somebody actually has next is the
  // other way round - which rooms do I have to go and fix - and answering it
  // off a filtered parts list means reading nine rows and keeping a tally.
  final undrivenOnly = vendorFilter == undrivenFilter;
  final room = sparesOnly ? spareRoom : '';

  // WHAT EACH UNSPARED PART COVERS, built once for the whole list rather than
  // per row: every row asks, and working it out on the row would walk the
  // master list once per row while somebody drags the scrollbar.
  final unspared = {
    for (final c in estimate.unsparedParts) c.line.key: c.installed,
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
    return line.vendor?.id == vendorFilter;
  }

  bool matchesSearch(MasterPartLine line) {
    if (needle.isEmpty) return true;
    return '${line.description} ${line.model} ${line.partNumber} '
            '${line.manufacturer} ${line.category}'
        .toLowerCase()
        .contains(needle);
  }

  Widget filterChip(
    String label,
    String value, {
    bool warn = false,

    /// The vendor this chip narrows to, so the chip carries the same colour
    /// its rows are marked in. Null on the chips that are not about a vendor.
    Color? tint,
  }) {
    final selected = vendorFilter == value;

    return FilterChip(
      avatar: tint == null ? null : NameTintDot(color: tint, size: 12),
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
  if (sparesOnly && sort == PartSortKey.natural) {
    double spareOf(MasterPartLine l) =>
        room.isEmpty ? l.spareQty : (l.spareByRoom[room] ?? 0);
    lines.sort((a, b) {
      final byQty = spareOf(b).compareTo(spareOf(a));
      return byQty != 0
          ? byQty
          : a.description.toLowerCase().compareTo(b.description.toLowerCase());
    });
  }

  // AND THEN WHATEVER COLUMN SOMEBODY PRESSED. Applied last so an explicit
  // sort wins over both the grouped order and the spares list's own - a
  // heading that did nothing on one filter would be a control that works
  // sometimes, which is worse than one that is not there.
  final shown = sortMasterParts(
    lines,
    key: sort,
    ascending: sortAscending,
    project: estimate.project,
  );
  final shownKeys = [for (final l in shown) l.key];
  final selectedLines = [
    for (final l in estimate.master)
      if (selected.contains(l.key)) l,
  ];

  // Built once for the whole list rather than per row — see [_PartRow].
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.name};

  // How many parts nothing on the job can drive. One pass, for the chip.
  var controlGapParts = 0;
  for (final l in estimate.master) {
    if (l.hasControlGap) controlGapParts++;
  }

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
                      filterChip(
                        '${p.name} (${p.lines.length})',
                        p.vendor!.id,
                        tint: projectVendorColor(p.vendor),
                      ),
                  if (estimate.untaggedParts > 0)
                    filterChip(
                      'Untagged (${estimate.untaggedParts})',
                      untaggedFilter,
                      warn: true,
                    ),
                  // Counted ONCE. Asking whether there are any and then
                  // asking how many is two walks of a two-hundred-part
                  // list to label one chip.
                  if (controlGapParts > 0)
                    filterChip(
                      'No control module ($controlGapParts)',
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
                  // THE JOB'S RULE, AND THE ONLY SPARES CHIP THAT IS A
                  // FAULT: one spare of everything the job installs, so a part
                  // with none is a part somebody has to decide about rather
                  // than a question to browse.
                  if (estimate.partsWithoutSpares.isNotEmpty)
                    filterChip(
                      'No spare (${estimate.partsWithoutSpares.length})',
                      kNoSpareFilter,
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
    if (undrivenOnly) ...[
      SliverToBoxAdapter(child: _DriverGapRooms(estimate: estimate)),
      // What has already been decided, under what has not. Both belong to the
      // same question - which devices need a driver - and the settled half is
      // the half nothing else in the app will ever show again.
      SliverToBoxAdapter(child: _SettledProducts(estimate: estimate)),
    ],
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
      // WHAT IS TICKED, AND WHAT CAN BE DONE TO IT. Above the headings rather
      // than floating over the list: it appears and disappears as rows are
      // ticked, and a bar that pushed the list up and down under the pointer
      // while somebody was ticking would make the next tick land on the wrong
      // row.
      if (onToggleSelected != null && selectedLines.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: _PartSelectionBar(
              selected: selectedLines,
              scopeLabel: _selectionScope(selectedLines),
              onClear: onClearSelected ?? () {},
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _PartsHeaderRow(
            theme: theme,
            sort: sort,
            ascending: sortAscending,
            onSort: onSort,
            selectable: onToggleSelected != null,
            // Three states, and the box says which: none of the shown rows are
            // ticked, all of them are, or some are.
            allShownSelected:
                shownKeys.isNotEmpty && shownKeys.every(selected.contains),
            someShownSelected: shownKeys.any(selected.contains),
            onSelectShown: onSelectShown == null
                ? null
                : () => onSelectShown(shownKeys),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverList.builder(
          itemCount: shown.length,
          itemBuilder: (context, index) => _PartRow(
            line: shown[index],
            estimate: estimate,
            roomNames: roomNames,
            spareRoom: room,
            sparesOnly: sparesOnly,
            installedUnspared: unspared[shown[index].key] ?? 0,
            askingAboutSpares: vendorFilter == kNoSpareFilter,
            selected: selected.contains(shown[index].key),
            onSelect: onToggleSelected == null
                ? null
                : () => onToggleSelected(shown[index].key),
          ),
        ),
      ),
    ],
  ];
}

/// What the ticked rows ARE, in words, for the bar and the bulk dialog.
///
/// DERIVED FROM THE SELECTION, not from the filter that produced it. The usual
/// way to select a vendor's parts is to press that vendor's chip and tick them
/// all - but the selection outlives the chip, and a label that went on saying
/// 'Extron' after somebody switched to Shure would be describing a scope that
/// is no longer what is about to be edited.
String _selectionScope(List<MasterPartLine> selected) {
  final vendors = <String>{};
  var untagged = 0;
  for (final line in selected) {
    final name = line.vendor?.name.trim() ?? '';
    if (name.isEmpty) {
      untagged++;
    } else {
      vendors.add(name);
    }
  }
  if (vendors.length == 1 && untagged == 0) return vendors.single;
  if (vendors.isEmpty && untagged > 0) return 'Not tagged to a vendor';
  final bits = [
    '${vendors.length} vendor${vendors.length == 1 ? '' : 's'}',
    if (untagged > 0) '$untagged untagged',
  ];
  return bits.join('  ·  ');
}

/// The bar that appears once anything is ticked: what is selected, and the one
/// thing worth doing to a handful of parts at once.
///
/// ONE ACTION, NOT A MENU OF THEM. Bulk-editing a master list is a loaded gun,
/// and the lead time is the field that genuinely arrives in batches - a vendor
/// quotes "six to eight weeks on anything of ours" for nineteen lines at once.
/// Everything else on a part is a per-part decision and stays one.
class _PartSelectionBar extends StatelessWidget {
  final List<MasterPartLine> selected;
  final String scopeLabel;
  final VoidCallback onClear;

  const _PartSelectionBar({
    required this.selected,
    required this.scopeLabel,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final count = selected.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_box_outlined,
            size: 18,
            color: foregroundOn(
              theme.colorScheme,
              theme.colorScheme.secondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count part${count == 1 ? '' : 's'} selected'
              '${scopeLabel.isEmpty ? '' : '  ·  $scopeLabel'}',
              key: const ValueKey('parts_selected_count'),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: foregroundOn(
                  theme.colorScheme,
                  theme.colorScheme.secondaryContainer,
                ),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('parts_selection_clear'),
            onPressed: onClear,
            child: const Text('Clear'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const ValueKey('parts_selection_lead'),
            icon: const Icon(Icons.schedule, size: 18),
            label: const Text('Set lead time…'),
            onPressed: () async {
              await showBulkPartScheduleDialog(
                context,
                provider,
                selected,
                scopeLabel: scopeLabel,
              );
              // The selection survives the dialog on purpose: the usual next
              // move after "six weeks on all of these" is "and they are all
              // wanted for the second phase", and having to tick nineteen
              // rows again is how the second edit does not get made.
            },
          ),
        ],
      ),
    );
  }
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
                    'Nothing on this job has a spare. Spares are asked for on '
                    'a room’s Cost page, and every one of them shows '
                    'up here.',
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

/// The column headings, which are also how the list is sorted.
///
/// EVERY HEADING IS A BUTTON, including the ones that look like labels. A list
/// where three of the seven columns sort is a list where somebody presses the
/// other four and concludes that none of them do - see part_sort.dart for what
/// a press cycles through.
class _PartsHeaderRow extends StatelessWidget {
  final ThemeData theme;
  final PartSortKey sort;
  final bool ascending;
  final ValueChanged<PartSortKey>? onSort;

  /// Whether the tick column is there at all.
  final bool selectable;
  final bool allShownSelected;
  final bool someShownSelected;

  /// Ticks every row currently on screen, or clears them.
  final VoidCallback? onSelectShown;

  const _PartsHeaderRow({
    required this.theme,
    this.sort = PartSortKey.natural,
    this.ascending = true,
    this.onSort,
    this.selectable = false,
    this.allShownSelected = false,
    this.someShownSelected = false,
    this.onSelectShown,
  });

  @override
  Widget build(BuildContext context) {
    /// One heading, carrying the arrow when the list is ordered by it.
    Widget label(String text, TextAlign align, PartSortKey key) {
      final active = sort == key;
      final style = theme.textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.bold,
        color: active ? theme.colorScheme.primary : null,
      );
      final arrow = Icon(
        ascending ? Icons.arrow_upward : Icons.arrow_downward,
        size: 12,
        color: theme.colorScheme.primary,
      );
      // The arrow goes on the OUTSIDE of the column: left of a right-aligned
      // heading, right of a left-aligned one, so it never sits between the
      // heading and the figures it is about.
      final content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active && align == TextAlign.right) ...[
            arrow,
            const SizedBox(width: 2),
          ],
          Flexible(
            child: Text(
              text,
              textAlign: align,
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (active && align != TextAlign.right) ...[
            const SizedBox(width: 2),
            arrow,
          ],
        ],
      );
      final aligned = Align(
        alignment:
            align == TextAlign.right ? Alignment.centerRight : Alignment.centerLeft,
        child: content,
      );
      if (onSort == null) return aligned;
      return InkWell(
        key: ValueKey('parts_sort_${key.name}'),
        borderRadius: BorderRadius.circular(4),
        onTap: () => onSort!(key),
        child: Tooltip(
          message: !active
              ? 'Sort by ${kPartSortLabels[key]}'
              : ascending
              ? 'Sorted by ${kPartSortLabels[key]}. Press again to reverse it.'
              : 'Sorted by ${kPartSortLabels[key]}, largest first. Press again '
                    'for the grouped order back.',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: aligned,
          ),
        ),
      );
    }

    Widget h(
      String text,
      int flex,
      PartSortKey key, {
      TextAlign align = TextAlign.left,
    }) => Expanded(flex: flex, child: label(text, align, key));

    Widget fixed(String text, double width, PartSortKey key) =>
        SizedBox(width: width, child: label(text, TextAlign.right, key));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          if (selectable)
            SizedBox(
              width: kPartTickWidth,
              child: Tooltip(
                message: allShownSelected
                    ? 'Clear the selection'
                    : 'Select every part on this list - whatever the filters '
                          'above have narrowed it to',
                child: Checkbox(
                  key: const ValueKey('parts_select_shown'),
                  // Three states, and the box says which: none of the rows on
                  // screen are ticked, all of them are, or some are.
                  value: allShownSelected
                      ? true
                      : someShownSelected
                      ? null
                      : false,
                  tristate: true,
                  visualDensity: VisualDensity.compact,
                  onChanged:
                      onSelectShown == null ? null : (_) => onSelectShown!(),
                ),
              ),
            ),
          h('Part', 5, PartSortKey.part),
          h('Qty', 1, PartSortKey.qty, align: TextAlign.right),
          h('Unit', 2, PartSortKey.unit, align: TextAlign.right),
          h('Extended', 2, PartSortKey.extended, align: TextAlign.right),
          // The gap the row has in front of its vendor cell. Without it every
          // heading from here rightwards sat eight pixels left of the column
          // it names.
          const SizedBox(width: 8),
          h('Vendor', 3, PartSortKey.vendor),
          // When it has to be bought, beside who buys it — the two halves of
          // placing one order, and the reason the lead time lives on this list
          // rather than on a screen of its own. Fixed widths rather than flex,
          // to line up with [_ScheduleCells], which cannot flex: a date is a
          // fixed amount of text and a column that shrinks below it would
          // ellipsize the one thing the column is for.
          fixed('Lead time', 84, PartSortKey.leadTime),
          const SizedBox(width: 8),
          fixed('Order by', 132, PartSortKey.orderBy),
          const SizedBox(width: 40),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

/// The tick column's width, shared by the heading and every row so the two
/// line up. A row whose first column is two pixels off the heading's is a
/// table that reads as broken however right the figures on it are.
const double kPartTickWidth = 34;

/// The room a part-level flag is really about: the FIRST of [ids] that is
/// still on the job.
///
/// The callers hand these in worst-first - most installed, most undriven -
/// so the room this picks is the one somebody would have gone to anyway. A
/// part in nine rooms cannot send anybody to nine places at once, and the
/// biggest is the only defensible one of the nine to pick.
///
/// Null when none of them are on the job any more, which is a real case on
/// a rollup built a moment before a room was removed. The flag simply does
/// not offer the jump then, rather than throwing on a double-click.
ProjectRoomCost? _flagRoom(ProjectEstimate estimate, Iterable<String> ids) {
  for (final id in ids) {
    for (final room in estimate.rooms) {
      if (room.ref.id == id) return room;
    }
  }
  return null;
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

  /// How many of this part the job installs, on a part with NOTHING spared —
  /// 0 on a part that has a spare, or that no room installs.
  ///
  /// The figure the note is written from: "no spare for 12 installed" is a
  /// decision, and "no spare" on its own is a row somebody has to go and
  /// research before they can weigh it.
  final double installedUnspared;

  /// True while the list is answering a question ABOUT SPARES. What it changes
  /// is that the row offers the fix: this is the list somebody is looking at
  /// when they decide to spare something, and the only reason to open it is to
  /// act on it.
  final bool askingAboutSpares;

  /// True when this row is ticked for a bulk edit.
  final bool selected;

  /// Ticks or unticks it. Null turns the tick column off entirely.
  final VoidCallback? onSelect;

  const _PartRow({
    required this.line,
    required this.estimate,
    required this.roomNames,
    this.spareRoom = '',
    this.sparesOnly = false,
    this.installedUnspared = 0,
    this.askingAboutSpares = false,
    this.selected = false,
    this.onSelect,
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

    // WHERE EACH OF THIS ROW'S FLAGS LEADS. A part is on the master list
    // once and in as many rooms as have it, so a flag on it cannot send
    // anybody to one place without choosing - and the only choice that
    // needs no explaining is the room with the MOST of what the flag is
    // about. Worked out here rather than in the cell so the tooltip and
    // the double-click cannot name two different rooms.
    final priceRoom = _flagRoom(estimate, line.roomIdsByQty());
    final gapRoom = _flagRoom(
      estimate,
      (line.undrivenByRoom.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .map((e) => e.key),
    );

    // WHICH ORDER THIS PART IS ON, as a colour. The vendor's own — assigned
    // on the Vendors pane or derived from its name — washed behind the row and
    // drawn round it, so a master list of two hundred parts can be read as the
    // four orders it actually is. The vendor is still named in the column on
    // the right: the colour groups the page, the name says who.
    final tint = projectVendorColor(line.vendor);
    final tagged = line.vendor != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      // Blended rather than laid over: a Card's fill is what its text was
      // measured against, and a translucent one would put the row's ink on
      // whatever happens to be behind the list.
      // A TICKED ROW IS A DIFFERENT PAPER, not a different edge: the vendor
      // colour already owns this row's border, and a selection drawn there
      // would be competing with the thing the border is for.
      //
      // A WASH, at the same weight the vendor tint uses. Every colour inside
      // this row is measured against [ThemeData.cardColor] - see the
      // accentTextOn and errorTextOn calls below - and a selection that
      // repainted the card in a container colour would carry that ink onto a
      // background it was never checked against. Blended in the same order it
      // is read: paper, then vendor, then selection.
      color: () {
        var paper = theme.cardColor;
        if (tagged) {
          paper = Color.alphaBlend(tintFill(tint, alpha: 0.10), paper);
        }
        if (selected) {
          paper = Color.alphaBlend(
            theme.colorScheme.primary.withValues(alpha: 0.12),
            paper,
          );
        }
        return tagged || selected ? paper : null;
      }(),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: tagged
              ? tint.withValues(alpha: 0.85)
              : theme.dividerColor,
          width: tagged ? 1.4 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // THE TICK, ON EVERY ROW RATHER THAN BEHIND A MODE.
            //
            // A "select" mode that has to be turned on first is a feature
            // nobody finds: the moment somebody wants it is the moment they
            // are already looking at the four rows they want, and being sent
            // to a toolbar to enable ticking loses that. It costs the row
            // thirty-four pixels of a column that was already the widest on
            // the list.
            if (onSelect != null)
              SizedBox(
                width: kPartTickWidth,
                child: Checkbox(
                  key: ValueKey('part_select_${line.key}'),
                  value: selected,
                  visualDensity: VisualDensity.compact,
                  onChanged: (_) => onSelect!(),
                ),
              ),
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
                  // NOTHING SPARED, AND THE WAY TO FIX IT. One spare of
                  // everything the job installs is the whole rule, so a part
                  // with none is the row worth acting on - and the percentage
                  // table on the spares section says the same thing about the
                  // job as a whole. This says it where the decision to buy one
                  // more actually gets made.
                  //
                  // FLAGGED ONLY WHILE SPARES ARE THE QUESTION. A red note on
                  // every unspared row of a two-hundred-part list is a warning
                  // on none of them.
                  if (askingAboutSpares && installedUnspared > 0)
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
                              'No spare for '
                              '${trimNumber(installedUnspared)} installed',
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
                            qty: 1,
                            label: 'Add a spare',
                          ),
                        ],
                      ),
                    )
                  // The same question about a part no room installs - a quoted
                  // extra, a shelf item. Not a fault: there is nothing to be
                  // a percentage of.
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
                              'No spare of this one',
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
                            // THE NOTE IS THE WAY IN. A driver is picked on
                            // the room's own Devices page, and until now the
                            // only thing this note did was name the rooms
                            // somebody then had to go and find. It has no
                            // single click of its own to lose, so the jump
                            // is the only gesture on it and the tooltip
                            // says what it is.
                            child: Tooltip(
                              message: gapRoom == null
                                  ? 'Nothing on this job drives these.'
                                  : 'Nothing on this job drives these.\n'
                                      'Double-click to open ${gapRoom.name} '
                                      'on its Devices page and pick one.',
                              child: InkWell(
                                key: ValueKey('part_gap_${line.key}'),
                                borderRadius: BorderRadius.circular(4),
                                onDoubleTap: gapRoom == null
                                    ? null
                                    : () => openProjectRoomOn(
                                          context,
                                          gapRoom.ref,
                                          AppTab.devices,
                                          'pick the control module for '
                                              '${line.description} here',
                                          roomName: gapRoom.name,
                                        ),
                                child: Text(
                                  'No control module - $undriven',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: errorTextOn(
                                      theme.colorScheme,
                                      theme.cardColor,
                                    ),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
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
                message: [
                  if (line.unpriced)
                    'Nothing on this job has a price for this part. Click '
                        'to set one - in the catalog, or on this job only.'
                  else if (line.priceVaries)
                    'Rooms on this job hold different prices for this '
                        'part - one of them has a negotiated override.\n'
                        'Click to set one price for the job.'
                  else
                    'Click to change the price',
                  // WHERE THE PRICE ACTUALLY COMES FROM. A price on the
                  // master list is the merge of every room's, and the room
                  // that has most of this part is where a wrong one is
                  // read in context - beside the labor, the overrides and
                  // the rest of that room's total.
                  if (priceRoom != null)
                    'Double-click to open ${priceRoom.name} on its Cost '
                        'page.',
                ].join('\n\n'),
                child: InkWell(
                  key: ValueKey('part_price_${line.key}'),
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => showPartPriceDialog(
                    context,
                    provider,
                    line,
                    currency,
                  ),
                  onDoubleTap: priceRoom == null
                      ? null
                      : () => openProjectRoomOn(
                            context,
                            priceRoom.ref,
                            AppTab.cost,
                            'the price for ${line.description} is on this '
                                'page',
                            roomName: priceRoom.name,
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
          // The dot in front of the name is the same colour the row is washed
          // in, which is what ties the two together: picking a vendor here is
          // what recolours the row.
          for (final v in vendors)
            DropdownMenuItem(
              value: v.id,
              child: Row(
                children: [
                  NameTintDot(color: projectVendorColor(v), size: 10),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(v.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
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

// ---------------------------------------------------------------------------
//  WHERE THE QUOTE HAS GOT TO
// ---------------------------------------------------------------------------
//  This app builds the RFQ per vendor and hands you the .xlsx. Everything after
//  that - it went out on the 4th, two came back, one turned into a PO, the
//  third has never replied - lived in somebody's inbox, and on a six-vendor job
//  "which of these are we still waiting on" is the single most-asked question
//  on this screen.
//
//  Three dates answer it, and one of them does work. See [VendorRfqStage] for
//  the states and [AppStateProvider.markVendorOrdered] for what ordering
//  actually does: it raises the PO, points it at this vendor, and puts every
//  part this vendor is quoting onto it - which is the LINK BACK from a PO
//  number to the equipment it bought, and the thing nobody could produce
//  before.
//
//  The colours, the icon, the one-line sentence, the chip and the way a quote
//  document is opened live in vendor_rfq_view.dart, because the TIMELINE says
//  the same things about the same vendors and two copies would drift apart.

/// The RFQ block on an OPEN vendor card: where the quote has got to, and the
/// one or two things that can happen to it next.
class VendorRfqStrip extends StatelessWidget {
  final ProjectVendor vendor;
  final VendorPackage? package;
  final ProjectEstimate estimate;

  const VendorRfqStrip({
    super.key,
    required this.vendor,
    required this.package,
    required this.estimate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final muted = theme.colorScheme.onSurfaceVariant;
    final stage = vendor.rfqStage;
    final po = vendor.poNumber.trim().isEmpty
        ? null
        : provider.project.poByNumber(vendor.poNumber);

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(rfqIcon(stage), size: 18, color: rfqInk(theme, stage)),
              const SizedBox(width: 6),
              Text(
                stage.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: rfqInk(theme, stage),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  vendorRfqSentence(vendor),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
          // WHAT THE QUOTE SAID, AGAINST WHAT THE JOB THOUGHT. The one figure
          // nobody had anywhere: the package total is this app's estimate of
          // what the vendor's lines come to, and the quote is what the vendor
          // actually wants for them. The gap is the whole reason a quote gets
          // read.
          if (vendor.quoteAmount > 0) ...[
            const SizedBox(height: 4),
            Text(
              _quoteAgainstEstimate(
                quoted: vendor.quoteAmount,
                estimated: package?.total ?? 0,
                currency: estimate.currency,
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (stage == VendorRfqStage.none)
                OutlinedButton.icon(
                  key: ValueKey('vendor_rfq_sent_${vendor.id}'),
                  icon: const Icon(Icons.outbox, size: 18),
                  label: const Text('RFQ sent'),
                  onPressed: () => _markSent(context, provider),
                ),
              if (stage == VendorRfqStage.sent) ...[
                FilledButton.tonalIcon(
                  key: ValueKey('vendor_rfq_quoted_${vendor.id}'),
                  icon: const Icon(Icons.request_quote_outlined, size: 18),
                  label: const Text('Quote came back...'),
                  onPressed: () => _markQuoted(context, provider),
                ),
                TextButton(
                  key: ValueKey('vendor_rfq_unsent_${vendor.id}'),
                  onPressed: () => provider.setVendorRfqSent(vendor.id, null),
                  child: const Text('Not sent after all'),
                ),
              ],
              if (stage == VendorRfqStage.quoted) ...[
                FilledButton.icon(
                  key: ValueKey('vendor_rfq_order_${vendor.id}'),
                  icon: const Icon(Icons.shopping_cart_checkout, size: 18),
                  label: const Text('Ordered...'),
                  onPressed: () => _markOrdered(context, provider),
                ),
                // THE PAPER ITSELF, one press from the row it belongs to. It
                // is attached in the dialog behind "Edit the quote"; this is
                // the way back to it.
                if (vendor.quoteFilePath.trim().isNotEmpty)
                  OutlinedButton.icon(
                    key: ValueKey('vendor_quote_open_${vendor.id}'),
                    icon: Icon(
                      quoteDrawableHere(vendor.quoteFilePath)
                          ? Icons.picture_as_pdf
                          : Icons.description_outlined,
                      size: 18,
                    ),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Text(
                        path.basename(vendor.quoteFilePath.trim()),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    onPressed: () => openVendorQuoteFile(
                      context,
                      provider,
                      stored: vendor.quoteFilePath,
                      vendorName: vendor.name,
                    ),
                  ),
                TextButton(
                  key: ValueKey('vendor_rfq_edit_quote_${vendor.id}'),
                  onPressed: () => _markQuoted(context, provider),
                  child: const Text('Edit the quote'),
                ),
              ],
              if (stage == VendorRfqStage.ordered) ...[
                // THE WAY BACK TO THE EQUIPMENT. A PO number on a vendor row
                // that cannot be followed to the parts it bought is the exact
                // dead end this was built to close.
                //
                // TO THE LIST, NOT TO A TICK-BOX DIALOG. This opened the PO's
                // own tick-list, which is the tool for the other job - saying
                // that only fourteen of the nineteen were actually ordered -
                // and it is the wrong answer to the question the button asks.
                // "Equipment on PO-1188 (19)" is read as "show me the
                // nineteen", and the nineteen are rows on the master list,
                // with their prices, their lead times and their rooms on
                // them. The tick-list is still on the Deliveries pane and on
                // this PO's own card on the timeline, which is where a
                // partial order gets sorted out.
                if (po != null)
                  OutlinedButton.icon(
                    key: ValueKey('vendor_rfq_parts_${vendor.id}'),
                    icon: const Icon(Icons.list_alt, size: 18),
                    label: Text(
                      'Equipment on ${po.number.trim()} '
                      '(${provider.project.partsOnPo(po.number).length})',
                    ),
                    onPressed: () => provider.requestProjectPane(
                      'parts',
                      partsVendorFilter: vendor.id,
                    ),
                  ),
                if (po != null) PoFileButtons(po: po, provider: provider),
                TextButton(
                  key: ValueKey('vendor_rfq_unorder_${vendor.id}'),
                  onPressed: () => provider.clearVendorOrdered(vendor.id),
                  child: const Text('Not ordered after all'),
                ),
              ],
            ],
          ),
          if (stage == VendorRfqStage.ordered && po == null) ...[
            const SizedBox(height: 4),
            Text(
              'The job has no purchase order numbered '
              '"${vendor.poNumber.trim()}". It was probably renumbered or '
              'deleted - mark it ordered again to put the row back.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: errorTextOn(theme.colorScheme, theme.cardColor),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The quote beside the estimate, and the gap between them in the direction
  /// somebody cares about: over is a problem and under is not.
  static String _quoteAgainstEstimate({
    required double quoted,
    required double estimated,
    required String currency,
  }) {
    final quote = 'Quoted ${formatMoney(quoted, currency)}';
    if (estimated <= 0) return '$quote. The job has no figure to compare it to.';
    final delta = quoted - estimated;
    final estimate = formatMoney(estimated, currency);
    if (delta.abs() < 0.005) return '$quote, exactly what the job estimated.';
    return delta > 0
        ? '$quote - ${formatMoney(delta, currency)} OVER the job\'s $estimate.'
        : '$quote - ${formatMoney(-delta, currency)} under the job\'s '
              '$estimate.';
  }

  Future<void> _markSent(
    BuildContext context,
    AppStateProvider provider,
  ) async {
    final picked = await showProjectDatePicker(
      context,
      initial: vendor.rfqSentOn ?? today(),
      title: 'The day the request went to ${vendor.name}',
    );
    if (picked?.date == null) return;
    provider.setVendorRfqSent(vendor.id, picked!.date);
  }

  Future<void> _markQuoted(
    BuildContext context,
    AppStateProvider provider,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _QuoteReturnedDialog(
        vendor: vendor,
        currency: estimate.currency,
        estimated: package?.total ?? 0,
      ),
    );
  }

  Future<void> _markOrdered(
    BuildContext context,
    AppStateProvider provider,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _VendorOrderedDialog(
        vendor: vendor,
        package: package,
        estimate: estimate,
      ),
    );
  }
}

/// What came back from a vendor: when, for how much, under what reference —
/// and the quote itself.
///
/// THREE FIELDS ARE WHAT YOU READ; THE PAPER IS WHAT YOU ARGUE FROM. The three
/// are the ones somebody needs to compare six quotes against each other and
/// against the job's own figure without opening any of them. The PDF settles
/// everything they cannot: what was actually quoted, at what lead time, with
/// which accessories.
///
/// ATTACHED HERE, IN ONE STEP. This dialog opens at the one moment somebody has
/// the quote in front of them - they are reading the figure off it as they type
/// it. Attaching it anywhere else is a second trip back to a file they have
/// already closed, which is a trip that does not get made; the PO learned the
/// same lesson (see [_VendorOrderedDialog]). Nothing is copied - the project
/// stores where the file IS. See [ProjectVendor.quoteFilePath].
class _QuoteReturnedDialog extends StatefulWidget {
  final ProjectVendor vendor;
  final String currency;

  /// What the job thinks this vendor's lines come to, shown under the amount
  /// so the comparison is on screen at the moment the figure is typed.
  final double estimated;

  const _QuoteReturnedDialog({
    required this.vendor,
    required this.currency,
    required this.estimated,
  });

  @override
  State<_QuoteReturnedDialog> createState() => _QuoteReturnedDialogState();
}

class _QuoteReturnedDialogState extends State<_QuoteReturnedDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.vendor.quoteAmount > 0
        ? widget.vendor.quoteAmount.toStringAsFixed(2)
        : '',
  );
  late final TextEditingController _reference = TextEditingController(
    text: widget.vendor.quoteRef,
  );
  late DateTime? _on = widget.vendor.quotedOn ?? today();

  /// The quote document. Whatever is already on the vendor is STORED (relative
  /// to the project where it could be); a fresh pick is absolute. Both go back
  /// through [AppStateProvider.setVendorQuote] unchanged - it knows which is
  /// which and stores accordingly.
  late String _filePath = widget.vendor.quoteFilePath;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final chosen = await pickVendorQuoteFile(widget.vendor.name);
    if (chosen.isEmpty || !mounted) return;
    setState(() => _filePath = chosen);
  }

  void _save() {
    context.read<AppStateProvider>().setVendorQuote(
      widget.vendor.id,
      quotedOn: _on,
      amount: double.tryParse(_amount.text.trim()) ?? 0,
      reference: _reference.text,
      filePath: _filePath,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('vendor_quote_dialog'),
      title: Text('${widget.vendor.name}\'s quote'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('vendor_quote_date'),
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(
                      _on == null
                          ? 'Pick the day it came back'
                          : 'Came back ${formatScheduleDate(_on!)}',
                    ),
                    onPressed: () async {
                      final picked = await showProjectDatePicker(
                        context,
                        initial: _on,
                        title: 'The day the quote came back',
                      );
                      if (picked?.date != null) {
                        setState(() => _on = picked!.date);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('vendor_quote_amount'),
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Quoted',
                prefixText: widget.currency,
                helperText: widget.estimated > 0
                    ? 'The job estimates '
                          '${formatMoney(widget.estimated, widget.currency)} '
                          'for this vendor\'s lines.'
                    : 'Blank when nobody has said. It is not zero.',
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('vendor_quote_ref'),
              controller: _reference,
              decoration: const InputDecoration(
                labelText: 'Their quote number',
                hintText: 'Q-88421',
                helperText: 'What to say on the phone. Blank is fine.',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            // THE PAPER, at the one moment somebody has it in front of them -
            // the same place the order's own document is attached. Anywhere
            // else is a second trip that does not get made.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('vendor_quote_attach'),
                    icon: const Icon(Icons.attach_file, size: 18),
                    label: Text(
                      _filePath.trim().isEmpty
                          ? 'Attach the quote (optional)'
                          : path.basename(_filePath.trim()),
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: _pickFile,
                  ),
                ),
                if (_filePath.trim().isNotEmpty) ...[
                  IconButton(
                    key: const ValueKey('vendor_quote_open'),
                    tooltip: 'Open it',
                    icon: const Icon(Icons.open_in_new, size: 18),
                    onPressed: () => openVendorQuoteFile(
                      context,
                      context.read<AppStateProvider>(),
                      stored: _filePath,
                      vendorName: widget.vendor.name,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('vendor_quote_detach'),
                    // The FILE is left where it is. This is a pointer at it,
                    // and deleting somebody's paperwork off their disk is not
                    // something a project file gets to do.
                    tooltip: 'Take the link off. The file itself is left alone.',
                    icon: const Icon(Icons.link_off, size: 18),
                    onPressed: () => setState(() => _filePath = ''),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Recording a quote changes no price on the job. The estimate '
              'stays what the parts say; this is what the vendor wants for '
              'them. The quote is linked where it sits - nothing is copied.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Only when there IS one, so a first quote's dialog does not offer to
        // delete something that has never been recorded.
        if (widget.vendor.quotedOn != null)
          TextButton(
            key: const ValueKey('vendor_quote_clear'),
            onPressed: () {
              context.read<AppStateProvider>().setVendorQuote(
                widget.vendor.id,
                quotedOn: null,
              );
              Navigator.of(context).pop();
            },
            child: const Text('No quote after all'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('vendor_quote_save'),
          onPressed: _on == null ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Marking a vendor's package ORDERED: the PO number, the dates, and the
/// equipment that goes on it.
///
/// ============================================================================
///  ONE ACTION, THREE FACTS
/// ============================================================================
///  Before this, ordering a vendor's package was three separate jobs on two
///  screens: raise the PO on the Deliveries pane, open it, tick nineteen parts.
///  What happened on real jobs is that the first two got done and the third did
///  not, which leaves a PO nobody can trace to any equipment and nineteen parts
///  that read on the timeline as things nobody has bought.
///
///  So it is one dialog. The parts default to THE WHOLE PACKAGE, because that
///  is what a purchase order to one vendor almost always is; the count is on
///  screen, and the tick-list behind the PO is still there for the job where it
///  was not.
///
///  ATTACHING THE ORDER IS OFFERED HERE, at the one moment somebody actually
///  has the PDF in front of them. See [ProjectPo.filePath].
class _VendorOrderedDialog extends StatefulWidget {
  final ProjectVendor vendor;
  final VendorPackage? package;
  final ProjectEstimate estimate;

  const _VendorOrderedDialog({
    required this.vendor,
    required this.package,
    required this.estimate,
  });

  @override
  State<_VendorOrderedDialog> createState() => _VendorOrderedDialogState();
}

class _VendorOrderedDialogState extends State<_VendorOrderedDialog> {
  late final TextEditingController _number = TextEditingController(
    text: widget.vendor.poNumber,
  );
  late final TextEditingController _amount = TextEditingController(
    text: _openingAmount(),
  );
  late DateTime? _ordered = widget.vendor.orderedOn ?? today();
  DateTime? _expected;

  /// The document, absolute, until it is saved and stored relative.
  String _filePath = '';

  String _error = '';

  /// What the PO was raised for, to start with: the quote if there is one,
  /// otherwise what the job estimates the package at. Either is a better
  /// opening than an empty box, and both are editable.
  String _openingAmount() {
    final quoted = widget.vendor.quoteAmount;
    if (quoted > 0) return quoted.toStringAsFixed(2);
    final total = widget.package?.total ?? 0;
    return total > 0 ? total.toStringAsFixed(2) : '';
  }

  @override
  void dispose() {
    _number.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Pick the order for ${widget.vendor.name}',
    );
    final chosen = picked?.files.single.path;
    if (chosen == null || chosen.isEmpty) return;
    setState(() => _filePath = chosen);
  }

  void _save() {
    final provider = context.read<AppStateProvider>();
    final number = _number.text.trim();
    if (number.isEmpty) {
      setState(() => _error = 'An order needs a PO number.');
      return;
    }

    final lines = widget.package?.lines ?? const <MasterPartLine>[];
    final onIt = provider.markVendorOrdered(
      widget.vendor.id,
      poNumber: number,
      orderedOn: _ordered,
      expectedOn: _expected,
      amount: double.tryParse(_amount.text.trim()) ?? 0,
      // Stored relative to the project where it can be - the provider does
      // that, because only it knows where the project file is.
      filePath: _filePath.trim().isEmpty
          ? ''
          : BuildingProject.storePath(
              _filePath.trim(),
              provider.currentProjectPath,
            ),
      partKeys: [for (final l in lines) l.key],
      partNames: {for (final l in lines) l.key: l.description},
    );

    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          onIt == 0
              ? '${widget.vendor.name} marked ordered on $number.'
              : '${widget.vendor.name} ordered on $number - $onIt part'
                    '${onIt == 1 ? '' : 's'} now say so, and the timeline says '
                    'they are bought.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final lines = widget.package?.lines ?? const <MasterPartLine>[];

    return AlertDialog(
      key: const ValueKey('vendor_ordered_dialog'),
      title: Text('Order ${widget.vendor.name}\'s package'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('vendor_ordered_number'),
                controller: _number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'PO number',
                  hintText: 'PO-1188',
                  helperText: 'The number finance uses. A number the job '
                      'already knows is reused rather than duplicated.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('vendor_ordered_date'),
                      icon: const Icon(Icons.event, size: 18),
                      label: Text(
                        _ordered == null
                            ? 'Ordered - pick a day'
                            : 'Ordered ${formatScheduleDate(_ordered!)}',
                      ),
                      onPressed: () async {
                        final picked = await showProjectDatePicker(
                          context,
                          initial: _ordered,
                          title: 'The day the order went in',
                        );
                        if (picked?.date != null) {
                          setState(() => _ordered = picked!.date);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('vendor_ordered_expected'),
                      icon: const Icon(Icons.local_shipping_outlined, size: 18),
                      label: Text(
                        _expected == null
                            ? 'Promised - optional'
                            : 'Promised ${formatScheduleDate(_expected!)}',
                      ),
                      onPressed: () async {
                        final picked = await showProjectDatePicker(
                          context,
                          initial: _expected,
                          title: 'What the vendor promised for the order',
                        );
                        if (picked?.date != null) {
                          setState(() => _expected = picked!.date);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('vendor_ordered_amount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Raised for',
                  prefixText: widget.estimate.currency,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              // WHAT IT BUYS. Said as a count and a total rather than as a
              // list: the list is nineteen rows and this is a confirmation,
              // not a picker. The PO's own tick-list is where a partial order
              // is dealt with, and the sentence says so.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lines.isEmpty
                          ? 'No parts are tagged to this vendor.'
                          : '${lines.length} part'
                                '${lines.length == 1 ? '' : 's'} go on this PO '
                                '- ${formatMoney(widget.package!.total, widget.estimate.currency)} '
                                'at the job\'s own prices.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      lines.isEmpty
                          ? 'The PO is still raised and the vendor still reads '
                                'as ordered; tick the equipment onto it from '
                                'the Deliveries pane.'
                          : 'Each of them will say it was bought on this '
                                'number, which is what links the PO back to the '
                                'equipment. Ordering only part of the package? '
                                'Do this, then untick the rest on the PO.',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // THE PAPER, at the one moment somebody has it in front of them.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('vendor_ordered_attach'),
                      icon: const Icon(Icons.attach_file, size: 18),
                      label: Text(
                        _filePath.isEmpty
                            ? 'Attach the order (optional)'
                            : path.basename(_filePath),
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: _pickFile,
                    ),
                  ),
                  if (_filePath.isNotEmpty)
                    IconButton(
                      key: const ValueKey('vendor_ordered_detach'),
                      tooltip: 'Do not attach anything',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _filePath = ''),
                    ),
                ],
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _error,
                  key: const ValueKey('vendor_ordered_error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: errorTextOn(theme.colorScheme, theme.cardColor),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('vendor_ordered_save'),
          onPressed: _save,
          child: const Text('Mark ordered'),
        ),
      ],
    );
  }
}


/// The Vendors pane, as slivers for the tab's one scroll view.
List<Widget> vendorsSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.read<AppStateProvider>();
  final theme = Theme.of(context);
  final vendors = estimate.project.vendors;
  final conflicts = estimate.project.vendorConflicts;
  // THE MAKERS AND CATEGORIES ON THIS JOB, not the catalog's. A rule is only
  // ever worth writing about something the job actually has a part in - see
  // [_RulePickerDialog].
  final projectCategories = projectCategoryChoices(estimate);
  final projectManufacturers = projectManufacturerChoices(estimate);
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
            projectCategories: projectCategories,
            projectManufacturers: projectManufacturers,
            estimate: estimate,
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

  /// Every category the job's own parts fall into, with how many parts each
  /// claims - what the category picker offers.
  final List<({String name, int count})> projectCategories;

  /// Every manufacturer the job buys from, with how many parts each one makes
  /// - what the manufacturer picker offers.
  final List<({String name, int count})> projectManufacturers;

  /// The whole priced job. The RFQ strip needs it: a quote is only readable
  /// against what the job thought the package was worth, and marking an order
  /// has to know which parts go on the PO.
  final ProjectEstimate estimate;

  final String currency;
  final bool isFirst;
  final bool isLast;

  const _VendorCard({
    super.key,
    required this.index,
    required this.vendor,
    required this.package,
    required this.projectCategories,
    required this.projectManufacturers,
    required this.estimate,
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

    final tint = projectVendorColor(vendor);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      // The card wears the order's colour, so the vendor list and the parts
      // list are visibly the same four orders rather than two lists that have
      // to be cross-referenced by name.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: tint.withValues(alpha: 0.85), width: 1.4),
      ),
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
                Tooltip(
                  message: vendor.color == null
                      ? 'Colour: from the name. Press to choose one.'
                      : 'Colour: chosen. Press to change it.',
                  child: InkWell(
                    key: ValueKey('vendor_color_${vendor.id}'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => showVendorColorDialog(context, vendor),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: tint,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: theme.dividerColor,
                            width: 0.5,
                          ),
                        ),
                        // An assigned colour says so. Without it there is no
                        // way to tell the colour somebody chose from the one
                        // the name happened to give — and the difference
                        // matters the moment a vendor is renamed.
                        child: vendor.color == null
                            ? null
                            : Icon(
                                Icons.edit,
                                size: 10,
                                color: ThemeData.estimateBrightnessForColor(
                                          tint,
                                        ) ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black87,
                              ),
                      ),
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
                // WHERE THE QUOTE HAS GOT TO, on the row that is always
                // there. A collapsed list of six vendors has to answer "which
                // of these are we waiting on" without any of them being
                // opened - see [VendorRfqChip].
                VendorRfqChip(vendor: vendor),
                // THE COUNT IS THE WAY TO THE ROWS IT COUNTS. This said
                // "19 lines - $18,400" and did nothing, which left the
                // obvious next question - WHICH nineteen - to be answered by
                // going to the Parts pane and finding this vendor's chip by
                // hand. Pressing it now opens the master list already
                // narrowed to exactly the parts this figure was added up
                // from. See [AppStateProvider.requestedPartsVendorFilter].
                if (package != null)
                  ActionChip(
                    key: ValueKey('vendor_package_parts_${vendor.id}'),
                    avatar: const Icon(Icons.list_alt, size: 16),
                    tooltip: 'Show these '
                        '${package.lines.length} part'
                        '${package.lines.length == 1 ? '' : 's'} on the '
                        'Equipment list',
                    label: Text(
                      '${package.lines.length} lines  ·  '
                      '${formatMoney(package.total, currency)}',
                    ),
                    onPressed: () => provider.requestProjectPane(
                      'parts',
                      partsVendorFilter: vendor.id,
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
            VendorRfqStrip(
              vendor: vendor,
              package: package,
              estimate: widget.estimate,
            ),
            const SizedBox(height: 8),
            _RuleEditor(
              label: 'Manufacturers',
              hint: 'Extron',
              helper: 'Every part by these makers goes to this vendor. '
                  'Matched exactly - checked before the category rules.',
              values: vendor.manufacturers,
              suggestions: facets.manufacturers,
              // TICKED, NOT TYPED, the same way the categories are. A maker
              // rule is matched EXACTLY, so 'Extron Electronics' against a
              // catalog that says 'Extron' claims nothing and says nothing
              // about it. See [_RulePickerDialog].
              choices: widget.projectManufacturers,
              chooseLabel: 'Pick from the job',
              pickNoun: 'manufacturer',
              pickOffNote: 'no part on this job is by them',
              pickKeyPrefix: 'vendor_manufacturer',
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
              // TICKED, NOT TYPED. See [_RulePickerDialog]: on a real job
              // this is a dozen boxes off a list, and typing a dozen exact
              // strings is a dozen chances to write one that matches nothing.
              choices: widget.projectCategories,
              chooseLabel: 'Pick from the job',
              pickNoun: 'category',
              pickOffNote: 'no part on this job is in it',
              pickKeyPrefix: 'vendor_category',
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

/// Every maker or category the job's own parts carry, with how many parts each
/// holds, most-used first.
///
/// [field] pulls the string off a line - its manufacturer or its category.
/// Both lists are built the same way and for the same reason; see
/// [projectManufacturerChoices] for why it is the JOB's and not the catalog's.
List<({String name, int count})> _projectFacetChoices(
  ProjectEstimate estimate,
  String Function(MasterPartLine) field,
) {
  final counts = <String, int>{};
  final spelling = <String, String>{};
  for (final line in estimate.master) {
    final name = field(line).trim();
    if (name.isEmpty) continue;
    final key = name.toLowerCase();
    counts[key] = (counts[key] ?? 0) + 1;
    spelling.putIfAbsent(key, () => name);
  }
  return [
    for (final entry in counts.entries)
      (name: spelling[entry.key]!, count: entry.value),
  ]..sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0
        ? byCount
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

/// Every manufacturer the job actually buys from, with how many parts each
/// one makes, most-used first — what the manufacturer tick-list offers.
///
/// THE JOB'S MAKERS AND NOT THE CATALOG'S, for the same reason the categories
/// are. The catalog knows a hundred manufacturers; this job buys from seven,
/// and a rule naming one of the other ninety-three claims nothing and says
/// nothing. The count is what makes it readable as a decision - "Extron (24)"
/// against "Middle Atlantic (1)" is the difference between the order this
/// vendor is really quoting and a bracket somebody added by accident.
///
/// A manufacturer rule is matched EXACTLY, which is what makes ticking so much
/// better than typing here: 'Extron Electronics' against a catalog that says
/// 'Extron' claims nothing, and nothing on screen would say so.
List<({String name, int count})> projectManufacturerChoices(
  ProjectEstimate estimate,
) => _projectFacetChoices(estimate, (line) => line.manufacturer);

/// Every category the job's own parts fall into, with how many parts each
/// holds, most-used first.
///
/// THE JOB'S CATEGORIES AND NOT THE CATALOG'S. The catalog knows two thousand
/// products in thirty categories; this job has parts in six of them, and a
/// vendor rule about the other twenty-four claims nothing and says nothing.
/// The count is what makes the list readable as a decision - "Display (18)"
/// against "Screen (2)" is the difference between the order this vendor is
/// really quoting and a line somebody added by accident.
List<({String name, int count})> projectCategoryChoices(
  ProjectEstimate estimate,
) => _projectFacetChoices(estimate, (line) => line.category);

/// The tick-list a vendor's rules — manufacturers OR categories — are set from.
///
/// ============================================================================
///  SIX BOXES, NOT SIX EXACT STRINGS
/// ============================================================================
///  A rule is matched exactly (a category also by prefix - see
///  [ProjectVendor.quotesCategory] and [ProjectVendor.quotesManufacturer]),
///  which makes typing one the worst possible way to write it: "Cameras"
///  against a catalog that says "Camera", or "Extron Electronics" against a
///  catalog that says "Extron", is a rule that claims nothing, and there is
///  nothing anywhere on the screen to say so. The autocomplete underneath
///  helped and only after you had typed enough of the word for it to appear.
///
///  What people actually do on a live job is read down the list of what is
///  being bought and say "that lot is Extron's, that lot is the AV reseller's".
///  That is a tick-list, so this is one: every maker or category the job has,
///  how many parts each claims, and a box.
///
///  THE TYPED ROUTE SURVIVES. A rule for something no part on the job has yet
///  is a real thing to want - the job is not finished, and a vendor is often
///  set up before the rooms are drawn - so anything the vendor already claims
///  that the job has no parts for is carried at the bottom of the list, ticked,
///  under a heading that says what it is. Unticking one is how it goes; the box
///  on the card is how another is added.
class _RulePickerDialog extends StatefulWidget {
  final String title;
  final List<({String name, int count})> choices;
  final List<String> selected;

  /// What one line of the list IS, in a sentence - 'category', 'manufacturer'.
  final String noun;

  /// What a row of the already-written block says about itself: 'no part on
  /// this job is in it' reads for a category and not for a maker.
  final String offNote;

  /// The stem every key on this dialog is built from, so the two pickers are
  /// separately addressable.
  final String keyPrefix;

  const _RulePickerDialog({
    required this.title,
    required this.choices,
    required this.selected,
    required this.noun,
    required this.offNote,
    required this.keyPrefix,
  });

  @override
  State<_RulePickerDialog> createState() => _RulePickerDialogState();
}

class _RulePickerDialogState extends State<_RulePickerDialog> {
  /// Lower-cased, because a rule is matched case-insensitively and a set that
  /// held both spellings would tick one box and write two rules.
  late final Set<String> _checked = {
    for (final v in widget.selected) v.trim().toLowerCase(),
  };

  /// What this vendor claims that the job has no parts in - see the note on
  /// the class. Worked out once: the choices do not change while the dialog is
  /// open, and neither does what was already written.
  late final List<String> _offList = [
    for (final v in widget.selected)
      if (!widget.choices.any(
        (c) => c.name.toLowerCase() == v.trim().toLowerCase(),
      ))
        v.trim(),
  ];

  bool _isChecked(String name) => _checked.contains(name.trim().toLowerCase());

  void _toggle(String name, bool on) => setState(() {
    final key = name.trim().toLowerCase();
    if (on) {
      _checked.add(key);
    } else {
      _checked.remove(key);
    }
  });

  /// What comes back out. Built from the DISPLAYED spellings rather than from
  /// the lower-cased keys: a rule is written into the project file and read by
  /// a person, and 'usb interface' is not what the catalog calls it.
  List<String> get _result => [
    for (final c in widget.choices)
      if (_isChecked(c.name)) c.name,
    for (final v in _offList)
      if (_isChecked(v)) v,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final chosen = _result.length;

    return AlertDialog(
      key: ValueKey('${widget.keyPrefix}_picker'),
      title: Text('${widget.title} this vendor quotes'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.choices.isEmpty
                  ? 'This job has no parts with a ${widget.noun} on them yet. '
                        'Draw a room, or type a rule on the card behind this.'
                  : 'Every ${widget.noun} on this job, and how many parts each '
                        'one claims. A part goes to the FIRST vendor whose '
                        'rules claim it, so two vendors ticking the same box '
                        'is decided by the order of the list behind this.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in widget.choices)
                    CheckboxListTile(
                      key: ValueKey('${widget.keyPrefix}_${c.name}'),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _isChecked(c.name),
                      onChanged: (v) => _toggle(c.name, v ?? false),
                      title: Text(c.name),
                      subtitle: Text(
                        '${c.count} part${c.count == 1 ? '' : 's'} on the job',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  if (_offList.isNotEmpty) ...[
                    const Divider(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'ALREADY WRITTEN, WITH NOTHING ON THE JOB IT CLAIMS',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: muted,
                        ),
                      ),
                    ),
                    for (final v in _offList)
                      CheckboxListTile(
                        key: ValueKey('${widget.keyPrefix}_off_$v'),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _isChecked(v),
                        onChanged: (on) => _toggle(v, on ?? false),
                        title: Text(v),
                        subtitle: Text(
                          widget.offNote,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: ValueKey('${widget.keyPrefix}_picker_save'),
          onPressed: () => Navigator.of(context).pop(_result),
          child: Text(
            chosen == 0 ? 'Claim nothing' : 'Claim $chosen',
          ),
        ),
      ],
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

  /// What a TICK-LIST would offer, with how many of the job's parts each
  /// choice claims. Empty leaves the button off and the editor is type-only,
  /// which is right for a rule with no closed set behind it.
  final List<({String name, int count})> choices;

  /// What that button reads.
  final String chooseLabel;

  /// What one line of the tick-list IS - 'category', 'manufacturer'. Only read
  /// when [choices] is non-empty; see [_RulePickerDialog].
  final String pickNoun;

  /// What the tick-list says about a rule the job has no parts for.
  final String pickOffNote;

  /// The stem the tick-list's keys are built from.
  final String pickKeyPrefix;

  final ValueChanged<List<String>> onChanged;

  const _RuleEditor({
    required this.label,
    required this.hint,
    required this.helper,
    required this.values,
    required this.suggestions,
    required this.onChanged,
    this.choices = const [],
    this.chooseLabel = 'Pick',
    this.pickNoun = 'rule',
    this.pickOffNote = 'no part on this job matches it',
    this.pickKeyPrefix = 'vendor_rule',
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

  /// Opens the tick-list, and takes back whatever came out of it.
  ///
  /// The dialog owns the whole set rather than adding to it: unticking is as
  /// much of the job as ticking, and a picker that could only add would leave
  /// the deleting to the chips it just filled the row with.
  Future<void> _pick() async {
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (_) => _RulePickerDialog(
        title: widget.label,
        choices: widget.choices,
        selected: widget.values,
        noun: widget.pickNoun,
        offNote: widget.pickOffNote,
        keyPrefix: widget.pickKeyPrefix,
      ),
    );
    if (chosen == null) return;
    widget.onChanged(chosen);
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
        // THE LIST, IN ONE PLACE, WITH TICKS. The type-in box below is still
        // here and still takes anything - a rule for a maker or a category no
        // part on this job has yet is a legitimate thing to write - but it is
        // no longer the only way in. See [_RulePickerDialog].
        if (widget.choices.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('rule_pick_${widget.label}'),
              icon: const Icon(Icons.checklist, size: 18),
              label: Text(widget.chooseLabel),
              onPressed: _pick,
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
