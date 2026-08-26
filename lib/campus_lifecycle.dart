import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'equipment_lifecycle.dart';
import 'project_estimate.dart';

/// ============================================================================
///  THE CAMPUS
/// ============================================================================
///  A project answers "what does this BUILDING need and when". Nobody who has
///  to fund it is looking at one building: the question that gets asked at
///  budget time is "what does the whole estate need, in which year, and can we
///  afford that year" - and until now the only way to answer it was to open
///  nine jobs one at a time and add their years up on paper.
///
///  So several projects can be read at once. Every one of them is read the way
///  the Project tab reads the one that is open - the same room loader, the same
///  pricing, the same lifecycle rules - and the results are laid side by side
///  on one calendar.
///
///  NOTHING HERE IS OPENED INTO THE EDITOR. The session keeps whatever job it
///  already had; these are read off disk, priced, and thrown away when the
///  view closes. A campus overview that quietly swapped the job somebody was
///  working on would be a very expensive convenience.
///
///  A JOB THAT CANNOT BE READ IS STILL A ROW. A campus of eleven where one
///  file has moved must say so on the sheet rather than quietly total ten -
///  the whole value of this view is that the total is complete.
/// ============================================================================

/// One job on the campus, priced and aged - or the reason it could not be.
typedef CampusJob = ({
  /// The project file this came from. The identity of the row: two jobs can
  /// share a name and no two share a path.
  String path,

  /// What to call it: the job's own name, else the file it lives in.
  String name,

  /// Null when [error] is set.
  BuildingLifecycle? lifecycle,

  /// How many rooms the job has, said even on a job with nothing dated so an
  /// empty row can be told from an unread one.
  int rooms,

  /// '' when the job read fine.
  String error,
});

/// Every job asked about, and the calendar they add up to.
class CampusLifecycle {
  final List<CampusJob> jobs;
  final DateTime asOf;
  final String currency;

  CampusLifecycle({
    required this.jobs,
    required this.asOf,
    this.currency = r'$',
  });

  /// The jobs that actually read, in the order they were added.
  late final List<CampusJob> ok = [
    for (final j in jobs)
      if (j.lifecycle != null) j,
  ];

  /// The ones that did not, so the sheet can say so out loud.
  late final List<CampusJob> failed = [
    for (final j in jobs)
      if (j.lifecycle == null) j,
  ];

  bool get isEmpty => ok.isEmpty;

  /// Every position on the campus, flattened once.
  late final List<EquipmentLife> items = [
    for (final j in ok) ...j.lifecycle!.items,
  ];

  /// THE YEARS THE SHEET COVERS: the earliest year anything on the campus was
  /// installed to the last year anything falls due.
  ///
  /// Bounded below by this year, so an estate that is entirely up to date
  /// still has a column to say so in, and capped the same way a single
  /// building's span is - a plan that runs to 2061 because one item was given
  /// a forty-year life is a plan nobody reads.
  late final List<int> years = () {
    var first = _span.first;
    var last = _span.last;
    if (first < asOf.year - kCampusMaxYears) {
      first = asOf.year - kCampusMaxYears;
    }
    if (last > asOf.year + kCampusMaxYears) last = asOf.year + kCampusMaxYears;
    return [for (var y = first; y <= last; y++) y];
  }();

  /// EVERY YEAR THE ESTATE TOUCHES, uncapped.
  ///
  /// What a DOCUMENT gets. The cap on [years] exists because a screen is a
  /// window - but a picture or a spreadsheet is not, and one that silently
  /// stops at the twenty-fifth year is a plan missing the building that falls
  /// due after it. A timeline that leaves dates off is worse than a wide one.
  late final List<int> allYears = [
    for (var y = _span.first; y <= _span.last; y++) y,
  ];

  /// The raw span, worked out once: the earliest install anywhere on the estate
  /// to the last year anything falls due, both bounded by today so a campus
  /// with nothing recorded still has a column to say so in.
  late final ({int first, int last}) _span = () {
    var first = asOf.year;
    var last = asOf.year;
    for (final i in items) {
      final installed = i.installedOn?.year;
      if (installed != null && installed < first) first = installed;
      final due = i.dueYear;
      if (due != null && due > last) last = due;
    }
    return (first: first, last: last);
  }();

  /// What one job has falling due in one year.
  double costIn(CampusJob job, int year) =>
      job.lifecycle?.costDueIn(year) ?? 0;

  /// What the WHOLE CAMPUS has falling due in one year - the budget line.
  double totalIn(int year) =>
      ok.fold<double>(0, (sum, j) => sum + costIn(j, year));

  /// The worst year on the calendar, which is the one a phased plan exists to
  /// flatten. 0 when nothing falls due at all.
  /// Read across EVERY year, not just the ones the screen has room for: a
  /// spike parked outside the window is still the year that has to be
  /// flattened, and a figure headed "worst single year" that quietly skipped
  /// it would be wrong in the direction nobody checks.
  double get peakYear {
    var worst = 0.0;
    for (final y in allYears) {
      final total = totalIn(y);
      if (total > worst) worst = total;
    }
    return worst;
  }

  /// What the campus is asking for NOW: past its life plus inside the planning
  /// window, across every job.
  double get toReplaceCost =>
      ok.fold<double>(0, (sum, j) => sum + j.lifecycle!.toReplaceCost);

  int get toReplaceCount =>
      ok.fold<int>(0, (sum, j) => sum + j.lifecycle!.toReplaceCount);

  /// What is already late.
  double get overdueCost =>
      ok.fold<double>(0, (sum, j) => sum + j.lifecycle!.overdueCost);

  /// What replacing everything on the campus would come to, whatever its age -
  /// the figure a ten-year budget is sized against.
  double get refreshCost =>
      ok.fold<double>(0, (sum, j) => sum + j.lifecycle!.refreshCost);

  /// How many positions across the estate carry no install date, and are
  /// therefore in none of the figures above.
  ///
  /// SAID OUT LOUD ON THE SHEET. A campus plan built on an estate that is half
  /// surveyed reads far better than the estate actually is, and the difference
  /// between "nothing falls due until 2031" and "nothing we have dated falls
  /// due until 2031" is the whole credibility of the document.
  int get undated =>
      ok.fold<int>(0, (sum, j) => sum + j.lifecycle!.countOf(EquipmentCondition.unknown));

  int get rooms => ok.fold<int>(0, (sum, j) => sum + j.rooms);
}

/// How far either side of today the campus calendar will run before it stops.
///
/// Wider than one building's, because an estate really does hold something
/// installed in the nineties, and the whole point of the sheet is that the
/// oldest thing on it is visible.
const int kCampusMaxYears = 25;

/// Reads, prices and ages every project at [projectPaths].
///
/// THE SAME READ THE PROJECT TAB DOES, run headlessly: [computeProjectEstimate]
/// over rooms off disk, then [buildProjectLifecycle] over that. Doing it any
/// other way would let the campus sheet and the building sheet disagree about
/// the same building, which is the one thing this cannot survive.
///
/// [provider] supplies the application data the pricing needs - the catalog,
/// the rate card, the base costs and the tier. It is READ ONLY: nothing here
/// touches the open project, the open room, or any file.
Future<CampusLifecycle> readCampus({
  required AppStateProvider provider,
  required List<String> projectPaths,
  DateTime? asOf,
}) async {
  final now = asOf ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);

  final jobs = <CampusJob>[];
  for (final file in projectPaths) {
    final fallback = path.basenameWithoutExtension(file);
    try {
      final project = await BuildingProject.load(file);
      final estimate = computeProjectEstimate(
        project: project,
        projectPath: file,
        library: provider.avDeviceLibrary,
        rates: provider.laborRates,
        baseCosts: provider.baseCosts,
        tier: provider.pricingTier,
        deviceCountMap: provider.uiSchema.deviceCountMap,
        moduleForModel: provider.moduleForModel,
      );
      jobs.add((
        path: file,
        name: project.name.trim().isEmpty ? fallback : project.name.trim(),
        lifecycle: buildProjectLifecycle(
          estimate: estimate,
          library: provider.avDeviceLibrary,
          baseCosts: provider.baseCosts,
          tier: provider.pricingTier,
          asOf: day,
        ),
        rooms: project.rooms.length,
        error: '',
      ));
    } catch (e, stack) {
      AppLogger.logError('Campus view could not read $file', e, stack);
      jobs.add((
        path: file,
        name: fallback,
        lifecycle: null,
        rooms: 0,
        error: '$e',
      ));
    }
  }

  return CampusLifecycle(
    jobs: jobs,
    asOf: day,
    currency: provider.currencySymbol,
  );
}

/// The project files under [folder], deepest last, in a stable order.
///
/// A FOLDER RATHER THAN ELEVEN FILE PICKS. An estate's jobs live together on a
/// share, and picking them out of a dialog one at a time is how somebody ends
/// up with eight of the eleven and a total nobody can use.
List<String> projectFilesUnder(String folder, {int maxDepth = 3}) {
  final out = <String>[];
  void walk(Directory dir, int depth) {
    if (depth > maxDepth) return;
    late final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      // A share that is briefly offline, or a folder this user cannot read.
      // One unreadable branch must not take the whole scan with it.
      return;
    }
    final folders = <Directory>[];
    for (final entry in entries) {
      if (entry is File) {
        if (entry.path.toLowerCase().endsWith(kProjectFileSuffix)) {
          out.add(entry.path);
        }
      } else if (entry is Directory) {
        folders.add(entry);
      }
    }
    folders.sort((a, b) => a.path.compareTo(b.path));
    for (final child in folders) {
      walk(child, depth + 1);
    }
  }

  walk(Directory(folder), 0);
  return out;
}
