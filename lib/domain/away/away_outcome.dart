/// What happened when somebody set, extended or cancelled an away period.
///
/// ## Three outcomes, and the missing fourth is the decision
///
/// There is deliberately **no "could not reach the server"**, and its absence is
/// [ADR-0004][]'s *refused is not unreachable* applied one layer further down
/// than `PairingRefusal.serverFault` took it.
///
/// Away is a **direct client write** rather than a callable, on purpose (§8,
/// §12): *"a watcher can set away on a plane and have it queue offline like any
/// other write"*. Firestore's offline persistence is what delivers that — the
/// mutation is held locally and replayed when the connection returns, and the
/// future the SDK hands back completes only once the **server** has it. So a
/// write that has not completed is in exactly one of two states, and **the
/// client cannot tell them apart**: still in flight, or queued behind a dead
/// radio. Both end the same way. The SDK will deliver it.
///
/// That makes *"could not reach the server"* a sentence this path can never
/// truthfully say. Saying it would tell somebody their family had not been told,
/// about a write that lands ninety seconds later — and the reader's obvious
/// response is to set the period again, which is a second write of the same
/// thing attributed to the same person. [queued] is the honest name for the
/// state that actually exists.
///
/// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
sealed class AwayOutcome {
  const AwayOutcome();

  /// The server has the write. Every other device will hear about it through
  /// `onAwayChanged`, and would find it at its next reconcile regardless (§12 —
  /// the nudge carries no authority).
  const factory AwayOutcome.set() = AwaySet;

  /// The write did not confirm inside the window, so Firestore is holding it.
  ///
  /// **Not a failure and not a refusal.** It is the offline property §8 chose
  /// this write shape for, observed. The one thing the reader must not be told
  /// here is that nothing was saved.
  const factory AwayOutcome.queued() = AwayQueued;

  const factory AwayOutcome.refused(AwayRefusal refusal) = AwayRefused;

  /// True only for [AwayRefused] — the one outcome where nothing was recorded
  /// anywhere and the reader has something to do about it.
  bool get isRefused => this is AwayRefused;
}

final class AwaySet extends AwayOutcome {
  const AwaySet();
}

final class AwayQueued extends AwayOutcome {
  const AwayQueued();
}

final class AwayRefused extends AwayOutcome {
  const AwayRefused(this.refusal);

  final AwayRefusal refusal;
}

/// Why an away write was not accepted.
///
/// Each of these is a **different sentence**, for the same reason ADR-0004 gives
/// for the warning messages: a refusal that names the wrong cause names the
/// wrong remedy, and a remedy that cannot work is worse than none.
enum AwayRefusal {
  /// The period itself is not allowed — [AwayRules] said no before anything was
  /// sent.
  ///
  /// Not reachable by choosing a day in the picker, which is bounded to the
  /// same rule. It is reachable by the **clock**: a device whose date moves
  /// between opening the picker and confirming it can turn a legal `from` into
  /// a retroactive one, and §11 says skew is surfaced rather than silently
  /// corrected.
  rejectedPeriod,

  /// The server answered, and said no.
  ///
  /// `permission-denied` on this document means the accepted link the write
  /// depended on is gone (§8 gates it on `isSelf(uid) || hasAcceptedLink(uid)`),
  /// or that the period broke a rule the client's own check does not mirror
  /// exactly — the rules are deliberately slack where `AwayRules` is exact, so
  /// this direction is possible only for the attribution clauses.
  ///
  /// **A claim about access, never about the device.** The phone demonstrably
  /// reached the backend: it got an answer.
  notPermitted,

  /// Reached, answered, and the answer is one this build cannot act on.
  ///
  /// `PairingRefusal.serverFault`'s twin, and the pattern the Phase 5 gate
  /// settled: a sentence that claims nothing about **either** side, for the case
  /// where the phone reached the backend and cannot use what came back. It is
  /// where "no better case" goes, so that no unrecognised condition can fall
  /// through into a claim that happens to be false.
  serverFault,

  /// Nobody is signed in, so there is no `setBy` to attribute the period to and
  /// no document to write it into.
  ///
  /// ADR-0003 makes the uid the identity: a write with nobody behind it is not a
  /// weaker version of an away period, it is not one at all.
  notSignedIn,
}
