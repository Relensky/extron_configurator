import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'live_text_field.dart';
import 'pdf_viewer_dialog.dart';
import 'project_estimate.dart';

/// ============================================================================
///  BUILDING PLANS — THE DRAWINGS THE JOB IS QUOTED AGAINST
/// ============================================================================
///  Every job arrives with a set of sheets: the architectural floor plans, the
///  reflected ceiling plan, the electrical riser, the as-builts somebody dug
///  out of a filing cabinet. They are looked at constantly — where the floor
///  boxes are, which wall the screen goes on, whether that column is really
///  where the drawing says — and until now the app had nowhere to put them, so
///  they lived in an email thread and got opened from a Downloads folder.
///
///  THREE DECISIONS, and they are the same three the room list makes:
///
///    1. REFERENCES, NOT COPIES. A plan set is hundreds of megabytes and gets
///       reissued halfway through a job. A copy taken in March is the drawing
///       somebody installs the wrong thing from in June, so this list points at
///       the file where it lives and says so when it is not there any more.
///
///    2. RELATIVE WHERE IT CAN BE. A project and its drawings travel together
///       — onto a laptop, into a backup, across to whoever is covering next
///       week — so a plan under the project's own folder is stored relative to
///       it. See [BuildingProject.storePath].
///
///    3. READ IT HERE. The whole point of attaching a drawing to the job is to
///       look at it WHILE filling in the fields it answers, and a PDF handed to
///       the machine's default reader is a second window that has to be found
///       again every time. PDFs and images open in the app's own viewer — the
///       same one the module manuals use — with the machine's opener still one
///       button away for the formats it cannot draw and for the times a real
///       CAD viewer is wanted.
///
///  NOT THE ROOM'S FLOOR PLAN. That is a picture you drag locations and
///  call-outs onto, it belongs to one config, and it lives on the Floor Plan
///  tab. This is the set the BUILDING came with, shared by every room on the
///  job — see [ProjectPlan].
/// ============================================================================

/// The Plans pane, as slivers for the project tab's one scroll view.
List<Widget> plansSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.watch<AppStateProvider>();
  final theme = Theme.of(context);
  final plans = provider.project.plans;

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey('add_plans'),
              onPressed: () => _pickPlans(context, provider),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add plans…'),
            ),
            // Expanded rather than a Spacer: the sentence is longer than what
            // is left beside the button on a laptop, and an unconstrained Text
            // runs off the edge instead of wrapping.
            Expanded(
              child: Text(
                'Plans are references. The file stays where it is: removing '
                'a row here never deletes a drawing.',
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
    if (plans.isEmpty)
      const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No building plans on this project yet.\n\n'
              'Add the floor plans, ceiling plans and riser diagrams this job '
              'is quoted against. PDFs and images open in the app; anything '
              'else opens in whatever this machine uses.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverList.separated(
          itemCount: plans.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, index) => _PlanRow(
            plan: plans[index],
            isFirst: index == 0,
            isLast: index == plans.length - 1,
          ),
        ),
      ),
  ];
}

/// The file picker behind "Add plans…", and the report of what it did.
///
/// Multiple at once because a drawing set arrives as a set: six sheets picked
/// in one go is one decision, and six trips through a file dialog is the
/// reason somebody goes back to the email thread instead.
Future<void> _pickPlans(
    BuildContext context, AppStateProvider provider) async {
  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Add building plans to the project',
    // ANY file, not just the ones the app can draw. A DWG is a plan; it is
    // worth listing beside the PDFs and handing to the machine's own opener,
    // and a picker that hides it is a picker that says the app does not
    // support drawings it in fact supports perfectly well.
    allowMultiple: true,
  );
  if (picked == null) return;

  final problems = <String>[];
  var added = 0;
  for (final f in picked.files) {
    if (f.path == null) continue;
    final error = provider.addPlanToProject(f.path!);
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
            ? '$added plan${added == 1 ? '' : 's'} added.'
            : '$added added. ${problems.join(' ')}',
      ),
    ),
  );
}

/// Opens a plan: in the app when it can draw it, otherwise in whatever this
/// machine opens the file type with.
Future<void> openProjectPlan(
    BuildContext context, AppStateProvider provider, ProjectPlan plan) async {
  final resolved = provider.resolveProjectPlanPath(plan);
  final messenger = ScaffoldMessenger.of(context);

  // SAID, NOT THROWN. A drawing that has been moved or renamed is a fact about
  // the file, and "the viewer failed" would send somebody looking in the wrong
  // place for it.
  if (resolved.isEmpty || !File(resolved).existsSync()) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text('${plan.displayName} is not where the project says it '
            'is${resolved.isEmpty ? '' : ' ($resolved)'}.'),
      ),
    );
    return;
  }

  if (!plan.isViewable) {
    final error = await provider.openProjectPlanExternally(plan);
    if (error != null) {
      showTimedSnackBar(messenger, SnackBar(content: Text(error)));
    }
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (_) => PdfViewerDialog(
      filePath: resolved,
      title: plan.displayName,
      screenshotStem: path.basenameWithoutExtension(resolved),
      onOpenExternally: () => provider.openProjectPlanExternally(plan),
    ),
  );
}

/// One drawing on the job.
class _PlanRow extends StatelessWidget {
  final ProjectPlan plan;
  final bool isFirst;
  final bool isLast;

  const _PlanRow({
    required this.plan,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final resolved = provider.resolveProjectPlanPath(plan);
    final exists = provider.projectPlanExists(plan);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // WHAT KIND OF SHEET THIS IS, at a glance. A drawing set is
                // read by picking the one you want out of a list of twenty,
                // and the file type is half of how somebody does that.
                Tooltip(
                  message: exists
                      ? resolved
                      : 'Missing: $resolved',
                  child: Icon(
                    !exists
                        ? Icons.error_outline
                        : plan.isPdf
                            ? Icons.picture_as_pdf
                            : plan.isViewable
                                ? Icons.image_outlined
                                : Icons.description_outlined,
                    color: exists
                        ? theme.colorScheme.onSurfaceVariant
                        : errorTextOn(theme.colorScheme, theme.cardColor),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plan.displayName,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // The file, under the name it is called on the job. Both
                      // are worth having: the label is what the drawing IS and
                      // the path is what to go looking for when it has moved.
                      Text(
                        exists
                            ? path.basename(resolved)
                            : 'Missing: $resolved',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: exists
                              ? theme.colorScheme.onSurfaceVariant
                              : errorTextOn(
                                  theme.colorScheme, theme.cardColor),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // VIEW is the button this pane exists for, so it is the filled
                // one. Dead when the file is gone rather than opening onto an
                // error somebody has to read to find out the same thing the
                // row already says.
                FilledButton.tonalIcon(
                  key: ValueKey('plan_view_${plan.id}'),
                  onPressed: exists
                      ? () => openProjectPlan(context, provider, plan)
                      : null,
                  icon: Icon(
                    plan.isViewable ? Icons.visibility : Icons.open_in_new,
                    size: 18,
                  ),
                  label: Text(plan.isViewable ? 'View' : 'Open'),
                ),
                IconButton(
                  key: ValueKey('plan_external_${plan.id}'),
                  tooltip: 'Open in the viewer this machine uses',
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: exists
                      ? () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final error =
                              await provider.openProjectPlanExternally(plan);
                          if (error != null) {
                            showTimedSnackBar(
                                messenger, SnackBar(content: Text(error)));
                          }
                        }
                      : null,
                ),
                // The order the set reads in. Same control as the room list,
                // because it is the same decision.
                IconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed:
                      isFirst ? null : () => provider.moveProjectPlan(plan.id, -1),
                ),
                IconButton(
                  tooltip: 'Move down',
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed:
                      isLast ? null : () => provider.moveProjectPlan(plan.id, 1),
                ),
                IconButton(
                  key: ValueKey('plan_remove_${plan.id}'),
                  tooltip: 'Take this plan off the job (the file is untouched)',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => provider.removePlanFromProject(plan.id),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: LiveTextField(
                    fieldId: 'plan_label_${plan.id}',
                    initial: plan.label,
                    label: 'What this sheet is',
                    hint: path.basename(resolved),
                    onChanged: (v) =>
                        provider.updateProjectPlan(plan.id, label: v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: LiveTextField(
                    fieldId: 'plan_notes_${plan.id}',
                    initial: plan.notes,
                    label: 'Notes',
                    hint: 'issued 3 Feb, supersedes the December set',
                    onChanged: (v) =>
                        provider.updateProjectPlan(plan.id, notes: v),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
