import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

/// Lets [builder]'s content be saved as a PNG image: through the share
/// sheet on phones, tablets and Macs (to Files, Photos, Mail, AirDrop, ...),
/// as a download in a browser. Put the export button it hands over where it
/// fits (e.g. a card's header); it is left out of the image.
class Exportable extends StatefulWidget {
  const Exportable({super.key, required this.fileName, required this.builder});

  /// Without the extension, e.g. "vorticity step 7000"; made file-safe.
  final String fileName;

  final Widget Function(BuildContext context, Widget exportButton) builder;

  @override
  State<Exportable> createState() => _ExportableState();
}

class _ExportableState extends State<Exportable> {
  final _boundary = GlobalKey();
  var _capturing = false;

  Future<void> _export(BuildContext buttonContext) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // The share sheet points at the button (needed on iPad and Mac).
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _capturing = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png == null) throw StateError('No image');
      final name = '${_safe(widget.fileName)}.png';
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(png.buffer.asUint8List(), mimeType: 'image/png', name: name)],
          fileNameOverrides: [name],
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text("Couldn't export the image")));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  static String _safe(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '-').trim();
    return cleaned.isEmpty ? 'soliton' : cleaned;
  }

  @override
  Widget build(BuildContext context) {
    final button = Builder(
      builder: (buttonContext) => Visibility(
        // Keeps its space while hidden, so the image is laid out the same.
        visible: !_capturing,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: IconButton(
          tooltip: 'Export as an image',
          // A full 48 px target: small icon, big enough to tap.
          iconSize: 18,
          icon: const Icon(Icons.ios_share),
          onPressed: _capturing ? null : () => _export(buttonContext),
        ),
      ),
    );
    return RepaintBoundary(key: _boundary, child: widget.builder(context, button));
  }
}
