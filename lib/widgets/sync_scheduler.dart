import 'dart:async';

import 'package:flutter/widgets.dart';

/// Runs syncs while the app is open: once when it starts (or a device signs
/// in), when it comes back to the foreground, and [editDelay] after the last
/// change, if a record actually changed. While [shouldRetry] says the last
/// sync could not reach the server, it tries again after [retryDelay],
/// doubling the wait up to [maxRetryDelay]. Each sync is a call to [sync];
/// this widget only decides when.
class SyncScheduler extends StatefulWidget {
  const SyncScheduler({
    super.key,
    required this.changes,
    required this.canSync,
    required this.hasChanges,
    required this.sync,
    required this.child,
    this.shouldRetry,
    this.editDelay = const Duration(seconds: 20),
    this.retryDelay = const Duration(seconds: 30),
    this.maxRetryDelay = const Duration(minutes: 5),
  });

  /// Notifies on every change to the app's data, such as the app provider.
  final Listenable changes;

  /// Signed in and loaded. A sync asked for while one runs is skipped by
  /// [sync] itself.
  final bool Function() canSync;

  /// Notes local changes and says whether any record changed.
  final Future<bool> Function() hasChanges;
  final Future<void> Function() sync;

  /// After a sync, whether it failed in a way worth trying again, such as no
  /// connection. Without it, a failed sync waits for the next start, return
  /// to the foreground or edit.
  final bool Function()? shouldRetry;
  final Duration editDelay;
  final Duration retryDelay;
  final Duration maxRetryDelay;
  final Widget child;

  @override
  State<SyncScheduler> createState() => _SyncSchedulerState();
}

class _SyncSchedulerState extends State<SyncScheduler> {
  late final AppLifecycleListener _lifecycle;
  Timer? _afterEdits;
  Timer? _retry;
  Duration? _nextRetry;
  bool _synced = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _syncNow);
    widget.changes.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void didUpdateWidget(SyncScheduler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.changes, widget.changes)) {
      oldWidget.changes.removeListener(_changed);
      widget.changes.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    if (!widget.canSync()) {
      // Signed out or still loading: sync again as soon as that changes.
      _synced = false;
      _afterEdits?.cancel();
      return;
    }
    if (!_synced) {
      _syncNow();
      return;
    }
    _afterEdits?.cancel();
    _afterEdits = Timer(widget.editDelay, _syncIfChanged);
  }

  Future<void> _syncIfChanged() async {
    if (!mounted || !widget.canSync()) return;
    if (await widget.hasChanges()) await _syncNow();
  }

  Future<void> _syncNow() async {
    if (!mounted || !widget.canSync()) return;
    _synced = true;
    _afterEdits?.cancel();
    _retry?.cancel();
    await widget.sync();
    if (!mounted) return;
    if (widget.shouldRetry?.call() != true) {
      _nextRetry = null;
      return;
    }
    final wait = _nextRetry ?? widget.retryDelay;
    final doubled = wait * 2;
    _nextRetry = doubled > widget.maxRetryDelay
        ? widget.maxRetryDelay
        : doubled;
    _retry = Timer(wait, _syncNow);
  }

  @override
  void dispose() {
    _afterEdits?.cancel();
    _retry?.cancel();
    _lifecycle.dispose();
    widget.changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
