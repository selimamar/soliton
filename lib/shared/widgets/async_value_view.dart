import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/run_repository.dart';
import '../../data/services/api_client.dart';

/// Renders an [AsyncValue] with consistent loading and error states, so
/// screens only have to describe the "data" case.
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({super.key, required this.value, required this.data, this.onRetry});

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    // After an error, a retry keeps the old error around while it reloads.
    // Show the spinner then, so pressing Retry visibly does something.
    // (A refresh of loaded data keeps showing the data, as usual.)
    if (value.isLoading && value.hasError) return const _Loading();

    return value.when(
      data: data,
      loading: () => const _Loading(),
      error: (error, _) => _ErrorView(error: error, onRetry: onRetry),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(child: CircularProgressIndicator());
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (:title, :message, :canRetry) = describeError(error);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              canRetry ? Icons.cloud_off_outlined : Icons.search_off,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            if (canRetry && onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Turns an error into words for the user, and says whether retrying can
/// help. Raw exception text stays out of the UI.
({String title, String message, bool canRetry}) describeError(Object error) => switch (error) {
  RunNotFoundException(:final runId) => (
    title: 'Run not found',
    message: 'There is no run called "$runId". It may have been deleted, or the link is wrong.',
    canRetry: false,
  ),
  UnauthorizedException(jobToken: true) => (
    title: 'Not allowed',
    message:
        'The app has the job token, which can only add and update runs and data. Use the '
        "server's main token in Settings → Server.",
    canRetry: false,
  ),
  UnauthorizedException() => (
    title: 'Not allowed',
    message: 'The server rejected the token. Check it in Settings → Server.',
    canRetry: false,
  ),
  ServerUnreachableException(:final address) => (
    title: "Can't reach the server",
    message: 'Check your connection, and that the server at $address is running.',
    canRetry: true,
  ),
  ServerErrorException(:final statusCode) => (
    title: 'Server error',
    message: 'The server had a problem (HTTP $statusCode). Try again in a moment.',
    canRetry: true,
  ),
  _ => (
    title: "Couldn't load data",
    message: 'Check your connection and try again.',
    canRetry: true,
  ),
};
