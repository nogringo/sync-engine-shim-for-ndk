/// What the engine knows about a relay, independently of any filter.
class RelayKnowledge {
  const RelayKnowledge({
    required this.relayUrl,
    this.lastConnectedAt,
    this.lastFailureAt,
  });

  final String relayUrl;
  final DateTime? lastConnectedAt;
  final DateTime? lastFailureAt;
}
