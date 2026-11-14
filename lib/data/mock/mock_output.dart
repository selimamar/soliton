import '../../models/run.dart';
import '../../models/run_output.dart';

/// What a demo run's script might have printed: a few setup lines, a line
/// per epoch (or per stretch of simulated time), and for a crashed run the
/// traceback.
RunOutput mockOutput(Run run) {
  final lines = <String>[
    'soliton: run ${run.id} on ${run.host.isEmpty ? 'this machine' : run.host}',
    if (run.isSimulation) ...[
      'Setting up ${run.name}: grid and initial condition',
      for (var i = 1; i <= 12 && i * 100 <= run.currentStep; i++)
        'step ${i * 100}: residual ${(1e-2 / i).toStringAsExponential(2)}',
    ] else ...[
      'Loading data ...',
      'Model: ${run.architecture.type}',
      for (var e = 1; e <= run.currentEpoch; e++)
        'epoch $e/${run.totalEpochs}: '
            'loss ${(2.0 / (1 + e)).toStringAsFixed(3)}',
    ],
  ];
  if (run.status == RunStatus.crashed) {
    final message = run.statusMessage ?? 'RuntimeError';
    lines.addAll([
      'Traceback (most recent call last):',
      '  File "/home/users/demo/${run.isSimulation ? 'solve' : 'train'}.py", line 87, in <module>',
      '    main()',
      '  File "/home/users/demo/${run.isSimulation ? 'solve' : 'train'}.py", line 61, in main',
      run.isSimulation ? '    sim.log({"energy": energy}, t=t)' : '    loss.backward()',
      if (message.contains(':')) message else 'RuntimeError: $message',
    ]);
  } else if (run.status == RunStatus.finished) {
    lines.add('Done.');
  }
  // As the server would keep them: the latest 1,000.
  final total = lines.length;
  return RunOutput(
    lines: List.unmodifiable(total > 1000 ? lines.sublist(total - 1000) : lines),
    total: total,
  );
}
