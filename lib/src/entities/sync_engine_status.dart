enum SyncEnginePhase {
  /// Not started, or stopped by the caller.
  stopped,

  /// Started, nothing left to do.
  idle,

  /// Started, syncing at least one request.
  working,
}

class SyncEngineStatus {
  const SyncEngineStatus({
    required this.phase,
    this.activeRequests = 0,
    this.pendingRequests = 0,
  });

  final SyncEnginePhase phase;

  /// Handles currently held by callers.
  final int activeRequests;

  /// Handles still short of their coverage target.
  final int pendingRequests;
}
