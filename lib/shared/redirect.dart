import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// Goes to [location] once this frame is drawn: for a screen that finds,
/// while building, that it is the wrong place for what it was asked to show
/// (e.g. a simulation's link under /runs).
void goAfterFrame(BuildContext context, String location) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (context.mounted) GoRouter.of(context).go(location);
  });
}
