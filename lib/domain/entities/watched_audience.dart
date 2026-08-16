import 'link.dart';

/// **Who will be notified when the watched person taps.**
///
/// The watched-side mirror of `WatchStatus`, and the whole of what the Tap
/// screen is permitted to say about watchers.
///
/// ## The gap this closes
///
/// §8 lets **either party** revoke a link, and ADR-0004 modelled the watcher
/// side of that thoroughly. Nothing modelled the watched side:
/// `WatchedReconciler.reconcile` took no links at all, so if the last watcher
/// revoked, the watched person went on tapping every day believing the promise
/// and no surface anywhere said otherwise. No Cloud Function is needed to close
/// it — §8 already lets the watched person read their own links, so their device
/// can see this by reconciling.
///
/// ## What this deliberately does NOT do
///
/// Owner's decision at the Phase 1 gate, recorded here and in `screens.md` so a
/// future reviewer meets the decision rather than the gap — in the same way
/// ADR-0003 records the display-name check it rejects.
///
/// **Explicitly rejected — do not implement, and do not re-propose:**
///
/// - a notification when someone starts watching;
/// - a notification when someone stops watching;
/// - a "nobody is watching you" *warning*, banner, or health-panel item;
/// - any other status-change message on the watched side.
///
/// > If everyone stops watching Mum, that is a family problem or a lack of
/// > communication. It is not the app's responsibility.
/// >
/// > It is important to avoid extra notifications or messages in the watched
/// > app. Elderly people can be overwhelmed if we start showing different
/// > messages like "this started watching you", "that stopped watching you",
/// > "no one is watching you". Elderly users are not ready to read a lot, and
/// > may not understand what the different messages mean.
///
/// This knowingly accepts the silent-inertness exposure the Phase 1 security
/// review raised (its finding M4), in exchange for a screen an 80-year-old can
/// read at a glance. **A future reviewer will flag it again**; the finding is
/// real and the acceptance is a judgement about who the app is for.
///
/// The empty case renders a *static* line — see `screens.md`. It is the same
/// line before pairing has ever happened and after the last watcher revokes,
/// which is the point: this type cannot tell those apart, and giving it the
/// power to would be the "someone stopped watching you" message the list above
/// rejects, under another name.
class WatchedAudience {
  const WatchedAudience(this.names);

  const WatchedAudience.empty() : names = const [];

  /// The accepted links, by name.
  ///
  /// Revoked links are absent rather than marked: this answers *who will be
  /// notified*, present tense, and a revoked watcher will not be. There is no
  /// "was watching" state, because rendering one is a status-change message.
  factory WatchedAudience.from(Iterable<Link> links) {
    // Deduped by watcher, never by name. Two different people genuinely called
    // "Ana" must both appear — collapsing them would silently drop a real
    // watcher from a list whose only job is to be complete. The deterministic
    // link id (§7) means duplicates should not occur; this is the backstop for
    // a caller that concatenates two queries.
    final seen = <String>{};
    final accepted = <Link>[];
    for (final link in links) {
      if (!link.isAccepted) continue;
      if (seen.add(link.watcherUid)) accepted.add(link);
    }

    // Sorted so the line does not reorder between sessions. The tap target
    // must not move, and text above it that reshuffles is the same failure in
    // miniature. `watcherUid` breaks ties so two identical names still produce
    // a total order rather than an arbitrary one.
    accepted.sort((a, b) {
      final byName =
          a.watcherName.toLowerCase().compareTo(b.watcherName.toLowerCase());
      return byName != 0 ? byName : a.watcherUid.compareTo(b.watcherUid);
    });

    return WatchedAudience([for (final link in accepted) link.watcherName]);
  }

  /// The names to render, in a stable order. Never null, possibly empty.
  final List<String> names;

  bool get isEmpty => names.isEmpty;
  bool get isNotEmpty => names.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is WatchedAudience &&
      other.names.length == names.length &&
      _sameOrder(other.names, names);

  @override
  int get hashCode => Object.hashAll(names);

  static bool _sameOrder(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'WatchedAudience($names)';
}
