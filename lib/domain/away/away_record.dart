import '../time/day_key.dart';
import 'away_period.dart';

/// The away **document**, as stored: the period, plus who set it.
///
/// [AwayPeriod] deliberately carries no attribution — its own docstring scopes
/// it to "from/through, containment, validity", because attribution is document
/// metadata for display and for the rules, and is never an input to a decision.
/// This is the type that carries the rest of `users/{uid}/shared/away` (§7, §8),
/// so the two travel together through the cache and to the surfaces that render
/// them, without the period type gaining a field no policy may read.
///
/// ## `setBy` is the identity; `setByName` is only a label
///
/// [ADR-0003][]. The uid is enforced by `firestore.rules` — `setBy ==
/// request.auth.uid` on create *and* update — so it cannot be forged. The name
/// **cannot be meaningfully authenticated**: §8 grants `users/{uid}` write to
/// self, so anybody may rename themselves before writing, and a rules `get()`
/// comparing the two would cost a read and prove nothing. The UI shows the
/// label; any dispute resolves through the uid.
///
/// Both are **mutable on update**, deliberately the opposite of
/// [AwayPeriod.from]. §12 is last-write-wins, so extending somebody else's away
/// period must re-attribute it to whoever wrote last.
///
/// ## A missing name may not cost the period
///
/// [setByName] is nullable, and that is the whole reason this type parses
/// rather than validates. ADR-0003's *Absence* case — an older build or an
/// admin write omitting the field — must degrade to an **unattributed** away
/// period, never to *no* away period: dropping the period would warn a family
/// about days somebody really did mark away, which is the worst thing this app
/// can do. `screens.md`'s rule that every away surface names who set it is
/// satisfied by the already-approved unattributed strings, which name nobody
/// because there is nobody to name.
///
/// [ADR-0003]: ../../../docs/architecture/decisions/0003-away-attribution.md
class AwayRecord {
  AwayRecord({
    required this.period,
    required this.setBy,
    String? setByName,
  }) : setByName = _usableName(setByName);

  /// An away period with nobody to attribute it to.
  ///
  /// Real state, not a test affordance: it is what a document written before
  /// ADR-0003's rules were deployed, or by an admin path that bypasses them,
  /// parses to. It is also what the period alone means wherever attribution has
  /// not been read — see [LocalStore.watcherCache] on a store upgraded from v5.
  AwayRecord.unattributed(this.period)
      : setBy = null,
        setByName = null;

  /// Parses a stored document, returning null rather than throwing.
  ///
  /// The same boundary and the same reason as [AwayPeriod.tryCreate]: a corrupt
  /// or hostile `through < from` must surface as *no valid away period*, not as
  /// an exception thrown inside an alarm isolate with seconds to live.
  ///
  /// **Only the period can make this null.** A missing or unusable `setBy` or
  /// `setByName` yields an unattributed record — see the class docstring.
  static AwayRecord? tryCreate({
    required DayKey from,
    required DayKey through,
    String? setBy,
    String? setByName,
  }) {
    final period = AwayPeriod.tryCreate(from: from, through: through);
    if (period == null) return null;
    return AwayRecord(
      period: period,
      setBy: (setBy != null && setBy.isNotEmpty) ? setBy : null,
      setByName: setByName,
    );
  }

  /// The period itself — the only half any policy is allowed to read.
  final AwayPeriod period;

  /// The uid that wrote the document last, or null when it is unreadable.
  ///
  /// **The identity.** Rules-enforced, so a non-null value here is true. Used to
  /// decide whether the reader is looking at their own action — which is the
  /// whole of what the Tap screen branches on — and never to decide whether the
  /// period is honoured.
  final String? setBy;

  /// The display label the writer denormalised onto the document, bounded to
  /// [AwayRules.nameMaxLength] characters, or null when absent or unusable.
  ///
  /// **Not authenticated.** See the class docstring and ADR-0003.
  final String? setByName;

  /// Whether [uid] is the party this record attributes the away period to.
  ///
  /// False when [setBy] is unreadable, which is the conservative direction: an
  /// unattributed period reads as *somebody else's*, so the reader is never told
  /// they did something the document cannot show they did.
  bool wasSetBy(String uid) => setBy != null && setBy == uid;

  /// The name to render, or null when no surface may name anybody.
  ///
  /// [forUid] is the reader. Their **own** name is suppressed, because every
  /// string that uses this reads *"X marked you away"* / *"set by X"* — and a
  /// reader who is told they were marked away by themselves is being told
  /// something in the wrong grammatical person. The caller renders the
  /// unattributed string instead.
  String? nameToShowFor(String? forUid) {
    if (forUid != null && wasSetBy(forUid)) return null;
    return setByName;
  }

  /// Trims, and rejects what the rules would reject anyway.
  ///
  /// Bounded on **read** as well as on write because the rules bound only what
  /// this app's clients can put there: a document written before they were
  /// deployed, or by an admin path that bypasses them, reaches a family's
  /// notification tray through this field. ADR-0003 lists
  /// `setByName: "Dr. Smith, Hospital Admissions"` as the injection this bound
  /// exists for.
  static String? _usableName(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.length < AwayRules.nameMinLength) return null;
    if (trimmed.length > AwayRules.nameMaxLength) return null;
    return trimmed;
  }

  AwayRecord copyWith({AwayPeriod? period}) => AwayRecord(
        period: period ?? this.period,
        setBy: setBy,
        setByName: setByName,
      );

  @override
  bool operator ==(Object other) =>
      other is AwayRecord &&
      other.period == period &&
      other.setBy == setBy &&
      other.setByName == setByName;

  @override
  int get hashCode => Object.hash(period, setBy, setByName);

  @override
  String toString() => 'AwayRecord($period, setBy: $setBy, as: $setByName)';
}
