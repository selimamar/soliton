import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Content wider than this is centred, so cards don't stretch across tablets
/// and desktop windows.
const maxContentWidth = 720.0;

/// [padding] plus the horizontal space that centres a [maxContentWidth]
/// column in [width]. The list itself stays full width, so it still scrolls
/// from anywhere in the window and its scrollbar stays at the edge.
EdgeInsetsGeometry centeredPadding(double width, EdgeInsetsGeometry padding) {
  final extra = math.max(0.0, (width - maxContentWidth) / 2);
  return padding.add(EdgeInsets.symmetric(horizontal: extra));
}

/// A padded [ListView] with equal vertical spacing between its children,
/// centred at [maxContentWidth] on wide screens.
class SpacedListView extends StatelessWidget {
  const SpacedListView({
    super.key,
    required this.children,
    this.spacing = 12,
    this.padding = const EdgeInsets.all(16),
    this.physics,
  });

  final List<Widget> children;
  final double spacing;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView.separated(
        padding: centeredPadding(constraints.maxWidth, padding),
        physics: physics,
        itemCount: children.length,
        separatorBuilder: (context, index) => SizedBox(height: spacing),
        itemBuilder: (context, index) => children[index],
      ),
    );
  }
}
