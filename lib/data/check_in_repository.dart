import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/domain.dart';

/// Writes the watched person's daily check-in (§7).
///
/// One document per day, at `checkins/{uid}/days/{YYYY-MM-DD}`, and **the
/// document id is the day**. That is not a formatting choice: it gives
/// once-per-day semantics for free, because a second tap the same day is an
/// *update*, which does not fire `onDocumentCreated`, so no duplicate push goes
/// out and there is no dedupe logic anywhere in this app.
class CheckInRepository {
  CheckInRepository({FirebaseFirestore? firestore}) : _injected = firestore;

  // **Resolved on use, not in the constructor.** `FirebaseFirestore.instance`
  // throws if Firebase has not been initialised, and this class is built inside
  // the composition root — so an eager resolve makes `AppServices` itself
  // unconstructible in any test that does not stand up the whole platform, for
  // an object most of them never call. Injected value wins; the singleton is the
  // fallback.
  final FirebaseFirestore? _injected;

  FirebaseFirestore get _firestore => _injected ?? FirebaseFirestore.instance;

  /// Files [checkIn] under the day the **device** decided, at tap time.
  ///
  /// ## Two timestamps, and they are not redundant (§11)
  ///
  /// `deviceTappedAt` is the client clock — *what actually happened*, and what
  /// the family is shown: "checked in at 23:40". `receivedAt` is
  /// `serverTimestamp()` — the audit trail, and the only skew signal available.
  ///
  /// **The day is never derived from `serverTimestamp()`**, and this is the
  /// correction §11 makes to HANDOVER.md. A server timestamp resolves when the
  /// write reaches the server, not when it was queued, so a tap at 23:50 with no
  /// signal that syncs at 08:00 the next morning would be filed on the following
  /// day — a day she did tap recorded as a day she did not, which §17 rates
  /// *High — silently wrong data*. The day comes off the device, at the tap, in
  /// the device's own zone, and there is no alternative that works offline.
  ///
  /// ## It is not awaited to completion, and that is the design
  ///
  /// Firestore's offline persistence queues this write and replays it when the
  /// connection returns. The returned future completes only once the **server**
  /// has it, so awaiting it on a phone with no signal would hang the tap — the
  /// one action this app asks of an elderly person, on the screen whose whole
  /// job is to work every morning.
  ///
  /// So the caller does not wait: `LocalStore` already recorded the tap, the
  /// screen already shows *"You already tapped today"*, and the sync is the
  /// SDK's problem. A failure here is not a failure of the tap. Nothing is
  /// retried by hand either — HANDOVER.md says not to build a retry queue
  /// because Firestore's own persistence is one, and §3's reconcile is what
  /// repairs anything that stays wrong.
  Future<void> write(String watchedUid, CheckIn checkIn) => _firestore
      .doc('checkins/$watchedUid/days/${checkIn.day}')
      .set(<String, Object?>{
    'deviceTappedAt': Timestamp.fromDate(checkIn.deviceTappedAt),
    'receivedAt': FieldValue.serverTimestamp(),
    'timezone': checkIn.timezone,
  });
}
