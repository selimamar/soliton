import 'dart:convert';

import '../../models/logged_image.dart';
import 'mock_images_data.dart';

/// The demo runs' logged pictures: the CIFAR run's confusion matrix, early
/// and late in training.
Map<String, List<LoggedImage>> mockImages(int Function(String runId) currentStep) {
  final step = currentStep('resnet50-cifar');
  final (width, height) = mockConfusionSize;
  LoggedImage confusion(int at, String png, String caption) => LoggedImage(
    name: 'confusion matrix',
    step: at,
    format: 'png',
    bytes: base64Decode(png),
    width: width,
    height: height,
    caption: caption,
  );
  return {
    'resnet50-cifar': [
      confusion(step ~/ 8, mockConfusionEarlyPng, 'Validation set; cats and dogs get mixed up'),
      confusion(step, mockConfusionLatePng, 'Validation set'),
    ],
  };
}
