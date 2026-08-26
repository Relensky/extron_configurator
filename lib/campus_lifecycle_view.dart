import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_model.dart' show formatEquipmentDate;
import 'building_project.dart' show kProjectFileSuffix;
import 'campus_file.dart';
import 'campus_lifecycle.dart';
import 'contrast.dart';
import 'equipment_lifecycle.dart';
import 'lifecycle_export.dart';
import 'lifecycle_picture.dart';
import 'lifecycle_view.dart'
    show
        EquipmentTimingKey,
        LifecycleEverythingChunk,
        equipmentConditionColor,
        equipmentTimingColor,
        equipmentTimingFill;
import 'pinned_grid.dart';
import 'save_actions.dart'
    show confirmLeavingProject, openProjectAtPath;

/// ============================================================================
///  THE CAMPUS VIEW
/// ============================================================================
///  Several jobs on one calendar: which building, which year, how much.
///
///  WHY IT IS A SCREEN OF ITS OWN AND NOT A TAB. Every tab in this app is about
///  the room or the job that is OPEN. This is about neither - it reads jobs off
///  disk without opening any of them, and closing it leaves the session exactly
///  where it was. A tab would have to answer "which of these am I editing", and
///  the answer is none of them.
///
///  WHAT IT IS READ FOR, in the order the questions get asked in the meeting:
///
///    1. WHAT DOES THE ESTATE NEED NOW, and how much of that is already late.
///    2. WHICH YEAR IS THE SPIKE. A phased refresh exists to flatten one bad
///       year, and it cannot be flattened until somebody can see it - which is
///       why the totals row carries a bar as well as a figure.
///    3. WHICH BUILDING IS DRIVING IT. The grid answers that by reading down
///       the column: one row per job, so the year that is frightening can be
///       traced to the two buildings that make it up.
///    4. WHAT IS THE WHOLE ESTATE WORTH replacing, which is the number a
///       ten-year budget is sized against.
/// ============================================================================

/// Opens the campus overview, starting with the job that is open (if any).
Future<void> showCampusLifecycle(BuildContext context) async {
  final provider = context.read<AppStateProvider>();
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog.fullscreen(
      child: _CampusView(
        // THE OPEN JOB IS ALREADY ON IT. Opening a campus view from a project
        // and then being asked to go and find that same project on disk is a
        // step nobody should have to take.
        initial: provider.currentProjectPath.isEmpty
            ? const []
            : [provider.currentProjectPath],
      ),
    ),
  );
}

/// Opens the campus SAVED AT [file] - the list of jobs somebody assembled once
/// and named, re-read off disk so the plan is today's.
///
/// Its own entry point because a campus is a document now: Open File hands one
/// here the same way it hands a project to [openProjectAtPath], and a campus
/// opened that way has to be the campus opened from the button.
Future<void> showCampusLifecycleFile(
  BuildContext context,
  CampusFile campus,
) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog.fullscreen(
      child: _CampusView(
        initial: campus.projects,
        name: campus.name,
        savedAt: campus.file,
      ),
    ),
  );
}

class _CampusView extends StatefulWidget {
  final List<String> initial;

  /// What this estate is called, when it came out of a campus file.
  final String name;

  /// The campus file it came out of, so saving again goes back to it.
  final String savedAt;

  const _CampusView({
    required this.initial,
    this.name = '',
    this.savedAt = '',
  });

  @override
  State<_CampusView> createState() => _CampusViewState();
}

class _CampusViewState extends State<_CampusView> {
  /// The project files on the sheet, in the order they were added. A Set would
  /// lose that order, and the order is how somebody keeps track of what they
  /// have added on an estate of thirty.
  late final List<String> _paths = [...widget.initial];

  /// What this estate is called, and the file it is saved in - both empty
  /// until somebody saves it or opens one.
  late String _name = widget.name;
  late String _file = widget.savedAt;

  CampusLifecycle? _campus;
  bool _reading = false;

  /// True while the sheet is being drawn off screen for a spreadsheet.
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    if (_paths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reread());
    }
  }

  /// Re-prices and re-ages every job on the sheet.
  ///
  /// WHOLESALE, not incrementally. Reading eleven jobs takes a moment and
  /// doing it again costs the same moment; keeping a per-job cache would save
  /// that and cost the guarantee that every figure on the sheet came from the
  /// same pass over the same disk.
  Future<void> _reread() async {
    setState(() => _reading = true);
    final provider = context.read<AppStateProvider>();
    final campus = await readCampus(provider: provider, projectPaths: _paths);
    if (!mounted) return;
    setState(() {
      _campus = campus;
      _reading = false;
    });
  }

  Future<void> _addFiles() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Which projects belong to this campus?',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final files = [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.path != null) f.path!,
    ];
    if (files.isEmpty) return;
    _add(files);
  }

  Future<void> _addFolder() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Which folder holds the campus?',
    );
    if (folder == null) return;
    final found = projectFilesUnder(folder);
    if (found.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No project files under ${path.basename(folder)}. A project is a '
            'file ending in $kProjectFileSuffix.',
          ),
        ),
      );
      return;
    }
    _add(found);
  }

  /// Adds what is not already on the sheet, and says how many were skipped.
  ///
  /// A JOB TWICE IS A TOTAL THAT IS WRONG BY ONE BUILDING, and wrong in the
  /// direction nobody checks - the figure is bigger, which is what somebody
  /// scanning a refresh request half expects it to be.
  void _add(List<String> files) {
    final before = _paths.length;
    for (final f in files) {
      if (!_paths.any((p) => path.equals(p, f))) _paths.add(f);
    }
    final added = _paths.length - before;
    final skipped = files.length - added;
    if (skipped > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$skipped ${skipped == 1 ? 'job was' : 'jobs were'} already on the '
            'campus.',
          ),
        ),
      );
    }
    if (added > 0) _reread();
  }

  // -------------------------------------------------------------------------
  //  THE CAMPUS AS A DOCUMENT
  // -------------------------------------------------------------------------
  //  An assembled campus was worth nothing the moment the window closed: the
  //  next person to want the same estate picked the same eleven files out of
  //  the same four folders from memory, and got a different eleven. Saving it
  //  keeps the LIST - never the figures, which are re-read off disk every time
  //  it is opened, so a campus saved in March opens in June showing June.

  /// Writes the campus, asking for a name the first time and a folder every
  /// time it is saved somewhere new.
  Future<void> _saveCampus() async {
    final messenger = ScaffoldMessenger.of(context);
    var name = _name;
    if (name.trim().isEmpty) {
      final asked = await _askName();
      if (asked == null || !mounted) return;
      name = asked;
    }
    final campus = CampusFile(name: name, projects: _paths);
    final picked = await FilePicker.saveFile(
      dialogTitle: 'Save this campus',
      fileName: _file.isNotEmpty
          ? path.basename(_file)
          : '${campus.fileStem}$kCampusFileSuffix',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (picked == null) return;
    // Named the way this app names its own documents, so the campus and the
    // projects beside it are told apart in a folder listing and by
    // [CampusFile.looksLikeCampus].
    final target = picked.toLowerCase().endsWith('.json')
        ? picked
        : '$picked$kCampusFileSuffix';
    try {
      await campus.save(target);
      if (!mounted) return;
      setState(() {
        _name = name;
        _file = target;
      });
      showSavedFileSnack(context, context.read<AppStateProvider>(),
          'The campus', target);
    } catch (e) {
      showTimedSnackBar(
        messenger,
        SnackBar(
          content: Text('The campus could not be saved: $e'),
          backgroundColor: snackErrorFillOn(messenger),
        ),
      );
    }
  }

  /// Opens a saved campus over this one.
  Future<void> _openCampus() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Open a campus',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final file = picked?.files.single.path;
    if (file == null || !mounted) return;
    try {
      final campus = await CampusFile.load(file);
      if (!mounted) return;
      setState(() {
        _paths
          ..clear()
          ..addAll(campus.projects);
        _name = campus.name;
        _file = campus.file;
        _campus = null;
      });
      await _reread();
    } catch (e) {
      showTimedSnackBar(
        messenger,
        SnackBar(
          content: Text('${path.basename(file)} is not a campus: $e'),
          backgroundColor: snackErrorFillOn(messenger),
        ),
      );
    }
  }

  /// Asks what the estate is called. A campus with no name is a file called
  /// campus.json in a folder of them.
  Future<String?> _askName() async {
    final controller = TextEditingController(text: _name);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('campus_name_dialog'),
        title: const Text('What is this campus called?'),
        content: SizedBox(
          width: 380,
          child: TextField(
            key: const ValueKey('campus_name'),
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Called',
              hintText: 'Chico campus',
              helperText: 'It heads the sheet and names the file.',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('campus_name_ok'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Opens one of the buildings as the job it is, and leaves the campus.
  ///
  /// THE WAY IN FROM THE OVERVIEW. The campus answers "which year is
  /// frightening and which buildings make it up"; the answer to both is a job
  /// somebody then has to work on, and going and finding that job on disk
  /// again is the step this removes. Same prompt about unsaved edits and same
  /// briefing as every other way of opening a project - see
  /// [openProjectAtPath].
  Future<void> _openJob(String file) async {
    final provider = context.read<AppStateProvider>();
    if (!await confirmLeavingProject(context, provider)) return;
    if (!mounted) return;
    final opened = await openProjectAtPath(context, provider, file);
    // Only on the way in: a job that would not open leaves the campus where
    // it was, with the message about why on top of it.
    if (opened && mounted) Navigator.of(context).pop();
  }

  void _remove(String file) {
    _paths.removeWhere((p) => path.equals(p, file));
    if (_paths.isEmpty) {
      setState(() => _campus = null);
    } else {
      _reread();
    }
  }

  // -------------------------------------------------------------------------
  //  WHAT LEAVES THE SCREEN
  // -------------------------------------------------------------------------

  /// The campus as it is read, laid out flat so it can be photographed whole.
  Widget get _sheet => CampusPlanSheet(campus: _campus!);

  /// The file both documents are named after.
  ///
  /// The campus has no name of its own - it is whichever jobs somebody put on
  /// the sheet this afternoon - so it is dated instead. Two exports on
  /// different days are two different documents and have to be filed as such.
  String get _fileStem {
    final at = _campus?.asOf ?? DateTime.now();
    final month = at.month.toString().padLeft(2, '0');
    final day = at.day.toString().padLeft(2, '0');
    // A campus that has been saved HAS a name, and a folder of exports called
    // after four different estates beats a folder of dates.
    final named = _name.trim().isEmpty
        ? ''
        : '${CampusFile(name: _name, projects: const []).fileStem}_';
    return '${named}campus_refresh_plan_${at.year}-$month-$day';
  }

  void _picture() => showLifecycleSheetPicture(
    context,
    dialogTitle: 'The campus plan as a picture',
    fileStem: _fileStem,
    what: 'The campus refresh plan',
    sheet: _sheet,
  );

  Future<void> _spreadsheet() async {
    final campus = _campus;
    if (campus == null) return;
    setState(() => _exporting = true);
    Uint8List? picture;
    try {
      // Only when there is something to draw. A campus where every job failed
      // to read still writes a book - it has to, that is the sheet that says
      // WHY - but there is no calendar to illustrate it with.
      if (!campus.isEmpty) {
        picture = await captureOffscreenSheet(context, _sheet);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
    if (!mounted) return;
    await saveLifecycleWorkbook(
      context,
      fileStem: _fileStem,
      what: 'The campus refresh plan',
      bytes: buildCampusLifecycleXlsx(campus: campus, picture: picture),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final campus = _campus;
    // THE LABELS GIVE WAY BEFORE THE BUTTONS DO. The bar carries the mode
    // strip and four controls, and on a laptop the four of them with their
    // labels on ran off the right-hand edge - which is a button that cannot
    // be pressed on a screen that had room for it.
    final compact = MediaQuery.sizeOf(context).width < 1300;

    return Scaffold(
      appBar: AppBar(
        // WHICH MODE THIS SESSION IS IN, said the same way the banner says it
        // one level down. The strip under the title bar reads Room when a room
        // is open and Project when a job is; while the campus is up it reads
        // CAMPUS, and pressing it drops back to the job - the same shape, the
        // same size, the same X beside it, so closing goes campus, project,
        // room without anybody having to learn a second control.
        titleSpacing: 12,
        leadingWidth: 0,
        leading: const SizedBox.shrink(),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              key: const ValueKey('banner_campus'),
              icon: const Icon(Icons.location_city, size: 22),
              label: const Text('Campus'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                minimumSize: const Size(0, 44),
                textStyle: theme.textTheme.titleMedium,
              ),
              // A toggle rather than a label: it is lit because the campus is
              // what is open, and pressing it is how you stop being in it.
              onPressed: () => Navigator.of(context).pop(),
            ),
            IconButton(
              key: const ValueKey('campus_close'),
              icon: const Icon(Icons.close, size: 18),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: 'Close the campus and go back to the project',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        actions: [
          // FOUR CONTROLS, NOT SIX. The bar carries the mode strip as well
          // now, and six full-width buttons beside it ran off the edge of a
          // laptop - so the two ways of adding jobs share a menu, and so do
          // the two documents the sheet can be turned into.
          PopupMenuButton<String>(
            key: const ValueKey('campus_add'),
            enabled: !_reading,
            tooltip: 'Put jobs on this campus',
            onSelected: (v) => v == 'files' ? _addFiles() : _addFolder(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                key: ValueKey('campus_add_files'),
                value: 'files',
                child: Text('Add projects…'),
              ),
              PopupMenuItem(
                key: ValueKey('campus_add_folder'),
                value: 'folder',
                child: Text('Add a folder…'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.note_add_outlined, size: 18),
                  if (!compact) ...[
                    const SizedBox(width: 6),
                    const Text('Add jobs…'),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // THE ASSEMBLY ITSELF, KEPT. See [_saveCampus].
          if (compact) ...[
            IconButton(
              key: const ValueKey('campus_open'),
              onPressed: _reading ? null : _openCampus,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              tooltip: 'Open a campus…',
            ),
            IconButton(
              key: const ValueKey('campus_save'),
              onPressed: _reading || _paths.isEmpty ? null : _saveCampus,
              icon: const Icon(Icons.save_outlined, size: 18),
              tooltip: 'Save the campus…',
            ),
          ] else ...[
            TextButton.icon(
              key: const ValueKey('campus_open'),
              onPressed: _reading ? null : _openCampus,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('Open a campus…'),
            ),
            TextButton.icon(
              key: const ValueKey('campus_save'),
              onPressed: _reading || _paths.isEmpty ? null : _saveCampus,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Save the campus…'),
            ),
          ],
          const SizedBox(width: 8),
          // WHAT LEAVES THE ROOM. This view exists to be quoted at a budget
          // meeting, and until now the only way to quote it was to describe
          // it: nothing on it could be attached to a mail or pasted onto a
          // slide. Disabled until there is a campus to picture.
          PopupMenuButton<String>(
            key: const ValueKey('campus_export'),
            enabled: !_reading &&
                !_exporting &&
                campus != null &&
                !campus.isEmpty,
            tooltip: 'Hand this campus over',
            onSelected: (v) => v == 'picture' ? _picture() : _spreadsheet(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                key: ValueKey('campus_picture'),
                value: 'picture',
                child: Text('Picture…'),
              ),
              PopupMenuItem(
                key: ValueKey('campus_spreadsheet'),
                value: 'spreadsheet',
                child: Text('Spreadsheet…'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.ios_share, size: 18),
                  if (!compact || _exporting) ...[
                    const SizedBox(width: 6),
                    Text(_exporting ? 'Drawing…' : 'Hand over…'),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _reading && campus == null
          ? const Center(child: CircularProgressIndicator())
          : campus == null || campus.jobs.isEmpty
              ? _EmptyCampus(onAddFiles: _addFiles, onAddFolder: _addFolder)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    if (_reading)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: LinearProgressIndicator(),
                      ),
                    // WHAT THIS ESTATE IS CALLED, where a heading has room
                    // to be one. The app bar carries the mode control and the
                    // five things a campus can be done to; a long name up
                    // there pushed the lot off the edge.
                    if (_name.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _name.trim(),
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                    _CampusHeadline(campus: campus),
                    const SizedBox(height: 12),
                    const EquipmentTimingKey(),
                    const SizedBox(height: 12),
                    _CampusGrid(campus: campus),
                    const SizedBox(height: 16),
                    _JobList(
                      campus: campus,
                      onRemove: _remove,
                      onOpen: _openJob,
                    ),
                    if (campus.failed.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'COULD NOT BE READ',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      for (final j in campus.failed)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${j.name} - ${j.error}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: errorTextOn(
                                theme.colorScheme,
                                theme.scaffoldBackgroundColor,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
    );
  }
}

/// What to do on a campus with nothing on it yet.
class _EmptyCampus extends StatelessWidget {
  final VoidCallback onAddFiles;
  final VoidCallback onAddFolder;

  const _EmptyCampus({required this.onAddFiles, required this.onAddFolder});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Put some jobs on the campus.\n\n'
            'Every project you add is read off disk, priced and aged the way '
            'its own Project tab would do it, and laid on one calendar beside '
            'the others. Nothing here opens a job or writes to one.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: onAddFiles,
                icon: const Icon(Icons.note_add_outlined, size: 18),
                label: const Text('Add projects…'),
              ),
              OutlinedButton.icon(
                onPressed: onAddFolder,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('Add a folder…'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// The four figures the meeting opens with.
class _CampusHeadline extends StatelessWidget {
  final CampusLifecycle campus;

  const _CampusHeadline({required this.campus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currency = campus.currency;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 10,
          children: [
            _Figure(
              label: 'Buildings',
              value: '${campus.ok.length} · ${campus.rooms} rooms',
            ),
            if (campus.toReplaceCount > 0)
              _Figure(
                key: const ValueKey('campus_now'),
                label: 'Recommended now',
                value: formatEquipmentBand(
                  campus.toReplaceCount,
                  campus.toReplaceCost,
                  currency,
                ),
                color: equipmentConditionColor(
                  context,
                  campus.overdueCost > 0
                      ? EquipmentCondition.overdue
                      : EquipmentCondition.ageing,
                ),
              ),
            if (campus.overdueCost > 0)
              _Figure(
                label: 'Past its life today',
                value: formatLifecycleMoney(campus.overdueCost, currency),
                color: equipmentConditionColor(
                  context,
                  EquipmentCondition.overdue,
                ),
              ),
            // The year a phased plan exists to flatten.
            if (campus.peakYear > 0)
              _Figure(
                label: 'Worst single year',
                value: formatLifecycleMoney(campus.peakYear, currency),
              ),
            // AND THEN A GAP, AND THE WHOLE-ESTATE FIGURE BEHIND A RULE.
            //
            // Everything to the left of the rule is money somebody is being
            // asked to find. This is not an ask at all - it is what the estate
            // is worth in replacement terms - and it is always the biggest
            // number on the screen. Read along the same unbroken row as the
            // asks, the biggest number reads as the biggest ask.
            if (campus.items.isNotEmpty)
              LifecycleEverythingChunk(
                key: const ValueKey('campus_everything'),
                items: campus.items.length,
                cost: campus.refreshCost,
                currency: currency,
                scope: 'this campus',
                undated: campus.undated,
              ),
          ],
        ),
        // The survey's own to-do list, said out loud: a campus plan built on an
        // estate that is half surveyed reads far better than the estate is.
        if (campus.undated > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${campus.undated} item${campus.undated == 1 ? '' : 's'} across '
              'the campus have no install date, so they fall due in no year on '
              'this sheet and are in none of these figures.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Figure({super.key, required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color)),
      ],
    );
  }
}

/// The calendar: a building a row, a year a column, and the campus total under
/// it as a figure AND as a bar.
class _CampusGrid extends StatefulWidget {
  final CampusLifecycle campus;

  const _CampusGrid({required this.campus});

  @override
  State<_CampusGrid> createState() => _CampusGridState();
}

class _CampusGridState extends State<_CampusGrid> {
  /// How big the calendar is being read at. See [GridZoomControls].
  double _zoom = kGridZoomNormal;

  /// Whether the size is taken from the window rather than from the steps -
  /// see [_LifecycleYearGridState], which does the same for one building.
  bool _fit = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => _calendar(context, box.maxWidth),
  );

  Widget _calendar(BuildContext context, double available) {
    final campus = widget.campus;
    final theme = Theme.of(context);
    // A fitted calendar keeps the window it opens with and only changes size,
    // or every year it let in would be another column to fit.
    final years = campus.yearsWithin(
      _fit ? kCampusMaxYears : gridYearWindow(kCampusMaxYears, _zoom),
    );
    final jobs = campus.ok;
    if (years.isEmpty || jobs.isEmpty) return const SizedBox.shrink();

    final zoom = _fit
        ? gridFitZoom(
            natural: gridMetric(context, 210) +
                gridMetric(context, 92) * years.length,
            available: available - 8,
          )
        : _zoom;

    // The reader's display scale, and then the reader's own zoom on top of it
    // - see [LifecycleYearGrid] for why those are two different questions.
    final yearColumn = gridMetric(context, 92) * zoom;
    final rowHeight = gridMetric(context, 30) * zoom;
    final nameColumn = gridMetric(context, 210) * zoom;
    final headHeight = gridMetric(context, 26) * zoom;
    final barRow = gridMetric(context, 46) * zoom;
    final thisYear = campus.asOf.year;
    final peak = campus.peakYear;

    final zoomed = zoomedTextTheme(theme, zoom);
    final headStyle = zoomed.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'REPLACEMENT YEAR, ACROSS THE CAMPUS',
              style: headStyle?.copyWith(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            GridZoomControls(
              keyPrefix: 'campus',
              zoom: zoom,
              fitted: _fit,
              onChanged: (z) => setState(() {
                _zoom = z;
                _fit = false;
              }),
              onFit: () => setState(() {
                if (_fit) _zoom = zoom;
                _fit = !_fit;
              }),
            ),
          ],
        ),
        SizedBox(height: gridMetric(context, 4)),
        Text(
          'What each building has falling due in each year, and the campus '
          'total under it. The bar is that total against the worst year on '
          'the sheet, which is the year a phased plan exists to flatten.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        SizedBox(height: gridMetric(context, 8)),
        PinnedGrid(
          frozenWidth: nameColumn,
          headerHeight: headHeight,
          bodyWidth: yearColumn * years.length,
          bodyHeight: rowHeight * (jobs.length + 1) + barRow,
          corner: Align(
            alignment: Alignment.bottomLeft,
            child: Text('BUILDING', style: headStyle),
          ),
          header: Row(
            children: [
              for (final y in years)
                SizedBox(
                  width: yearColumn,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Text(
                      '$y',
                      style: headStyle?.copyWith(
                        fontWeight: y == thisYear
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: y == thisYear
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          frozen: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final j in jobs)
                SizedBox(
                  height: rowHeight,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      j.name,
                      overflow: TextOverflow.ellipsis,
                      style: zoomed.bodyMedium,
                    ),
                  ),
                ),
              SizedBox(
                height: rowHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'CAMPUS',
                    style: zoomed.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: barRow,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    'against ${formatLifecycleMoney(peak, campus.currency)}',
                    style: zoomed.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final j in jobs)
                SizedBox(
                  height: rowHeight,
                  child: Row(
                    children: [
                      for (final y in years)
                        _MoneyCell(
                          width: yearColumn,
                          height: rowHeight,
                          money: campus.costIn(j, y),
                          year: y,
                          asOf: campus.asOf,
                          currency: campus.currency,
                          tooltip: '${j.name} - $y',
                          label: zoomed.labelMedium,
                        ),
                    ],
                  ),
                ),
              // THE LINE THE BUDGET IS ACTUALLY SET FROM.
              SizedBox(
                height: rowHeight,
                child: Row(
                  children: [
                    for (final y in years)
                      _MoneyCell(
                        width: yearColumn,
                        height: rowHeight,
                        money: campus.totalIn(y),
                        year: y,
                        asOf: campus.asOf,
                        currency: campus.currency,
                        bold: true,
                        tooltip: 'The whole campus in $y',
                        label: zoomed.labelMedium,
                      ),
                  ],
                ),
              ),
              // THE SAME NUMBERS AS A SHAPE. A row of figures says what each
              // year costs; it does not say which year is twice the one beside
              // it, and that is the only thing a phased plan is trying to fix.
              SizedBox(
                height: barRow,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final y in years)
                      _YearBar(
                        width: yearColumn,
                        height: barRow,
                        money: campus.totalIn(y),
                        peak: peak,
                        year: y,
                        asOf: campus.asOf,
                        currency: campus.currency,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One building's money in one year.
///
/// Coloured on the same ramp the building sheets use, read against TODAY: a
/// year already gone is red because that money is late, and a year twenty
/// years out is green because it is somebody else's problem yet.
class _MoneyCell extends StatelessWidget {
  final double width, height, money;
  final int year;
  final DateTime asOf;
  final String currency;
  final String tooltip;
  final bool bold;

  /// The type the money is set in, handed down rather than read off the theme:
  /// the calendar on screen zooms, and the figure has to move with the box it
  /// is in. Null takes the theme's own - the flat sheet a picture is made from
  /// does not zoom.
  final TextStyle? label;

  const _MoneyCell({
    required this.width,
    required this.height,
    required this.money,
    required this.year,
    required this.asOf,
    required this.currency,
    required this.tooltip,
    this.bold = false,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    if (money <= 0) return SizedBox(width: width, height: height);
    final theme = Theme.of(context);
    final timing = timingFor(
      yearsRemaining: (year - asOf.year).toDouble(),
      lifeYears: kDefaultEquipmentLifeYears,
    );

    return Tooltip(
      message: '$tooltip\n${formatLifecycleMoney(money, currency)}',
      child: Container(
        width: width - 2,
        height: height - 2,
        margin: const EdgeInsets.only(right: 2, bottom: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: equipmentTimingFill(context, timing),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          formatLifecycleMoney(money, currency),
          overflow: TextOverflow.ellipsis,
          style: (label ?? theme.textTheme.labelMedium)?.copyWith(
            color: equipmentTimingColor(context, timing),
            fontWeight: bold ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }
}

/// One year of the campus total, as a bar against the worst year on the sheet.
class _YearBar extends StatelessWidget {
  final double width, height, money, peak;
  final int year;
  final DateTime asOf;
  final String currency;

  const _YearBar({
    required this.width,
    required this.height,
    required this.money,
    required this.peak,
    required this.year,
    required this.asOf,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    if (money <= 0 || peak <= 0) return SizedBox(width: width, height: height);
    final timing = timingFor(
      yearsRemaining: (year - asOf.year).toDouble(),
      lifeYears: kDefaultEquipmentLifeYears,
    );
    // A floor of three pixels: a year that is one per cent of the worst one is
    // still a year with money in it, and a bar of nothing says there is none.
    final tall = (height - 8) * (money / peak);

    return Tooltip(
      message: '$year: ${formatLifecycleMoney(money, currency)}',
      child: SizedBox(
        width: width,
        height: height,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: width * 0.55,
            height: tall < 3 ? 3 : tall,
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: equipmentTimingFill(context, timing, alpha: 0.9),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// THE WHOLE CAMPUS CALENDAR AT ITS FULL SIZE, for a picture of it.
///
/// [_CampusGrid] is the version for reading: it scrolls in its own frame with
/// the building names and the year headings pinned, and a photograph of that
/// is a photograph of the frame - four buildings and six years of an estate of
/// eleven. This is the same sheet laid out flat, nothing scrolling and nothing
/// clipped, with its own heading and figures so it can be understood in a
/// document that has no app around it.
///
/// The cells and the bars are the SAME widgets the screen draws, so the
/// picture cannot come out saying something the sheet does not.
class CampusPlanSheet extends StatelessWidget {
  final CampusLifecycle campus;

  const CampusPlanSheet({super.key, required this.campus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // EVERY YEAR, not the window the screen uses - see [CampusLifecycle.years]
    // for why the on-screen grid caps its own and a picture must not.
    final years = campus.allYears;
    final jobs = campus.ok;
    final currency = campus.currency;
    final thisYear = campus.asOf.year;
    final peak = campus.peakYear;

    final yearColumn = gridMetric(context, 92);
    final rowHeight = gridMetric(context, 30);
    final nameColumn = gridMetric(context, 210);
    final barRow = gridMetric(context, 46);

    final headStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Campus refresh plan', style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              'As of ${formatEquipmentDate(campus.asOf)}  ·  '
              '${jobs.length} building${jobs.length == 1 ? '' : 's'}  ·  '
              '${campus.rooms} room${campus.rooms == 1 ? '' : 's'}  ·  '
              '${campus.items.length} item'
              '${campus.items.length == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 28,
              runSpacing: 6,
              children: [
                if (campus.toReplaceCount > 0)
                  _SheetFigure(
                    label: 'Recommended now',
                    value: formatEquipmentBand(
                      campus.toReplaceCount,
                      campus.toReplaceCost,
                      currency,
                    ),
                    color: equipmentConditionColor(
                      context,
                      campus.overdueCost > 0
                          ? EquipmentCondition.overdue
                          : EquipmentCondition.ageing,
                    ),
                  ),
                if (campus.overdueCost > 0)
                  _SheetFigure(
                    label: 'Past its life today',
                    value: formatLifecycleMoney(campus.overdueCost, currency),
                    color: equipmentConditionColor(
                      context,
                      EquipmentCondition.overdue,
                    ),
                  ),
                if (peak > 0)
                  _SheetFigure(
                    label: 'Worst single year',
                    value: formatLifecycleMoney(peak, currency),
                  ),
                _SheetFigure(
                  label: 'Everything, whatever its age',
                  value: formatEquipmentBand(
                    campus.items.length,
                    campus.refreshCost,
                    currency,
                  ),
                ),
              ],
            ),
            if (campus.undated > 0) ...[
              const SizedBox(height: 6),
              Text(
                '${campus.undated} item${campus.undated == 1 ? '' : 's'} '
                'across the campus have no install date, so they fall due in '
                'no year on this sheet and are in none of the figures above.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            const EquipmentTimingKey(),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: nameColumn,
                  child: Text('BUILDING', style: headStyle),
                ),
                for (final y in years)
                  SizedBox(
                    width: yearColumn,
                    child: Center(
                      child: Text(
                        '$y',
                        style: headStyle?.copyWith(
                          fontWeight: y == thisYear
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: y == thisYear
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 2),
            // EVERY OTHER BUILDING WASHED. The calendar is seventy years
            // across on an estate with anything old on it, and a row is read
            // by running a finger from the name on the left to a figure four
            // feet to the right - on paper, with no pointer to follow. The
            // wash is what a ruled ledger did about that.
            for (final (i, job) in jobs.indexed)
              SheetBand(
                shaded: i.isOdd,
                child: Row(
                  children: [
                    SizedBox(
                      width: nameColumn,
                      height: rowHeight,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            job.name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ),
                    for (final y in years)
                      _MoneyCell(
                        width: yearColumn,
                        height: rowHeight,
                        money: campus.costIn(job, y),
                        year: y,
                        asOf: campus.asOf,
                        currency: currency,
                        tooltip: '${job.name} - $y',
                      ),
                  ],
                ),
              ),
            // THE LINE THE BUDGET IS ACTUALLY SET FROM, and the same figures
            // as a shape under it: a row of numbers says what each year costs
            // and does not say which year is twice the one beside it.
            Row(
              children: [
                SizedBox(
                  width: nameColumn,
                  height: rowHeight,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'CAMPUS',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                for (final y in years)
                  _MoneyCell(
                    width: yearColumn,
                    height: rowHeight,
                    money: campus.totalIn(y),
                    year: y,
                    asOf: campus.asOf,
                    currency: currency,
                    bold: true,
                    tooltip: 'The whole campus in $y',
                  ),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: nameColumn,
                  height: barRow,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      'against ${formatLifecycleMoney(peak, currency)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                for (final y in years)
                  _YearBar(
                    width: yearColumn,
                    height: barRow,
                    money: campus.totalIn(y),
                    peak: peak,
                    year: y,
                    asOf: campus.asOf,
                    currency: currency,
                  ),
              ],
            ),
            // A JOB THAT COULD NOT BE READ IS STILL ON THE PICTURE. The whole
            // value of the sheet is that the total is complete, and a picture
            // that quietly leaves out the building nobody could open is a
            // picture that overstates how complete it is.
            if (campus.failed.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'COULD NOT BE READ',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              for (final job in campus.failed)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${job.name} - ${job.error}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: errorTextOn(
                        theme.colorScheme,
                        theme.colorScheme.surface,
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One figure in a sheet's heading block: the screen's [_Figure] with no
/// interaction behind it.
class _SheetFigure extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SheetFigure({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color)),
      ],
    );
  }
}

/// The jobs on the sheet, with what each one is asking for and a way off.
class _JobList extends StatelessWidget {
  final CampusLifecycle campus;
  final ValueChanged<String> onRemove;

  /// Opens one of them as the job it is - see [_CampusViewState._openJob].
  final ValueChanged<String> onOpen;

  const _JobList({
    required this.campus,
    required this.onRemove,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ON THIS CAMPUS',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        for (final j in campus.jobs)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(j.name, style: theme.textTheme.titleSmall),
                      Text(
                        j.error.isNotEmpty
                            ? j.error
                            : [
                                '${j.rooms} room${j.rooms == 1 ? '' : 's'}',
                                if (j.lifecycle!.toReplaceCount > 0)
                                  'now: ${formatEquipmentBand(
                                    j.lifecycle!.toReplaceCount,
                                    j.lifecycle!.toReplaceCost,
                                    campus.currency,
                                  )}',
                                'everything: '
                                    '${formatLifecycleMoney(
                                  j.lifecycle!.refreshCost,
                                  campus.currency,
                                )}',
                                path.basename(j.path),
                              ].join('  ·  '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: j.error.isEmpty
                              ? theme.colorScheme.onSurfaceVariant
                              : errorTextOn(
                                  theme.colorScheme,
                                  theme.scaffoldBackgroundColor,
                                ),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // The way from the overview into the job it is about. Only
                // on a job that could be read - a file that failed to open
                // as a campus entry will not open as a project either.
                if (j.error.isEmpty)
                  TextButton.icon(
                    key: ValueKey('campus_open_${path.basename(j.path)}'),
                    onPressed: () => onOpen(j.path),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Open'),
                  ),
                IconButton(
                  key: ValueKey('campus_remove_${path.basename(j.path)}'),
                  tooltip: 'Take it off the campus (the file is untouched)',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => onRemove(j.path),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
