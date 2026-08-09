/// Opaque reference to a registered [SyncRequest].
class SyncHandle {
  const SyncHandle(this.id);

  final String id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SyncHandle && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SyncHandle($id)';
}
