import 'package:material_ui/material_ui.dart';

import '../../shared/formatters.dart';

/// How the Fields tab names what it shows: a training run's prediction at
/// a step (the default), or a simulation's field at a simulated time. Put
/// one above a `FieldsTab` to change it.
class FieldsWording extends InheritedWidget {
  const FieldsWording({
    super.key,
    this.prediction = 'Prediction',
    this.stepLabel,
    this.compares = true,
    required super.child,
  });

  /// What a field without a target is called: "Prediction", or "Field".
  final String prediction;

  /// A snapshot's step as shown, e.g. "t = 6.4"; default "Step 1,200".
  final String Function(int step)? stepLabel;

  /// Whether fields usually have a truth to compare with (a model's
  /// predictions), so its absence is worth a note; not for a simulation.
  final bool compares;

  /// [step] as a title ("Step 1,200"), or [lower] for inside a sentence.
  String step(int step, {bool lower = false}) =>
      stepLabel?.call(step) ?? '${lower ? 'step' : 'Step'} ${formatInt(step)}';

  static const _default = FieldsWording(child: SizedBox.shrink());

  static FieldsWording of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FieldsWording>() ?? _default;

  @override
  bool updateShouldNotify(FieldsWording oldWidget) =>
      oldWidget.prediction != prediction ||
      oldWidget.stepLabel != stepLabel ||
      oldWidget.compares != compares;
}
