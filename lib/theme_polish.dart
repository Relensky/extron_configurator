import 'package:material_ui/material_ui.dart';

/// Motion shared by the app's own transitions: quick, and easing out so a
/// thing arrives softly rather than stopping dead.
const Duration kMotionShort = Duration(milliseconds: 160);
const Duration kMotionMedium = Duration(milliseconds: 220);
const Curve kMotionCurve = Curves.easeOutCubic;

/// Page transitions for every theme: a short fade and slide in place of the
/// zoom Windows gets by default.
const PageTransitionsTheme kPageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
    TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
    TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
  },
);

/// The Classic theme's furniture, made consistent: flat outlined cards,
/// rounder dialogs and menus, quieter tooltips and floating snack bars.
///
/// Colors come from the scheme as generated, so nothing here moves a color
/// that legibleTheme later measures.
ThemeData polishClassic(ThemeData theme) {
  final s = theme.colorScheme;
  const radius = BorderRadius.all(Radius.circular(10));
  final menuShape = RoundedRectangleBorder(
    borderRadius: const BorderRadius.all(Radius.circular(8)),
    side: BorderSide(color: s.outlineVariant),
  );
  return theme.copyWith(
    pageTransitionsTheme: kPageTransitions,
    cardTheme: theme.cardTheme.copyWith(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: s.outlineVariant),
      ),
    ),
    dialogTheme: theme.dialogTheme.copyWith(
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    popupMenuTheme: theme.popupMenuTheme.copyWith(
      elevation: 4,
      shape: menuShape,
    ),
    menuTheme: MenuThemeData(
      style: (theme.menuTheme.style ?? const MenuStyle()).copyWith(
        elevation: const WidgetStatePropertyAll(4),
        shape: WidgetStatePropertyAll(menuShape),
      ),
    ),
    tooltipTheme: theme.tooltipTheme.copyWith(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: s.inverseSurface.withValues(alpha: 0.94),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      textStyle: theme.textTheme.bodySmall?.copyWith(
        color: s.onInverseSurface,
      ),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      behavior: SnackBarBehavior.floating,
      elevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    dividerTheme: theme.dividerTheme.copyWith(
      color: s.outlineVariant,
    ),
  );
}

/// The same lift for Auris, in its own terms: its cut corners, outlines and
/// colors stay, and overlays gain depth. Dark uses a faint accent glow, which
/// is how Auris shows depth; light uses a soft shadow.
ThemeData polishAuris(ThemeData theme) {
  final s = theme.colorScheme;
  final shadow = theme.brightness == Brightness.dark
      ? s.primary.withValues(alpha: 0.28)
      : const Color(0x33000000);
  final tip = theme.tooltipTheme.decoration;
  return theme.copyWith(
    pageTransitionsTheme: kPageTransitions,
    dialogTheme: theme.dialogTheme.copyWith(
      elevation: 8,
      shadowColor: shadow,
    ),
    popupMenuTheme: theme.popupMenuTheme.copyWith(
      elevation: 4,
      shadowColor: shadow,
    ),
    menuTheme: MenuThemeData(
      style: (theme.menuTheme.style ?? const MenuStyle()).copyWith(
        elevation: const WidgetStatePropertyAll(4),
        shadowColor: WidgetStatePropertyAll(shadow),
      ),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(elevation: 4),
    tooltipTheme: tip is BoxDecoration
        ? theme.tooltipTheme.copyWith(
            decoration: tip.copyWith(
              boxShadow: [
                BoxShadow(
                  color: shadow,
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          )
        : theme.tooltipTheme,
  );
}

/// Fades and lifts its child in once, when it is first built. Keyed by the
/// caller so a new page plays it and a rebuild of the same page does not.
class FadeInPage extends StatefulWidget {
  final Widget child;

  const FadeInPage({super.key, required this.child});

  @override
  State<FadeInPage> createState() => _FadeInPageState();
}

class _FadeInPageState extends State<FadeInPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: kMotionMedium);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: kMotionCurve);
  late final Animation<Offset> _lift = Tween(
    begin: const Offset(0, 0.012),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the system's reduce-motion setting.
    if (_c.status == AnimationStatus.dismissed) {
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(position: _lift, child: widget.child),
      );
}
