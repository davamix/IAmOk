import 'package:flutter/foundation.dart';

import '../domain/domain.dart';
import 'check_in_reader.dart';
import 'local_store.dart';

/// Lets the debug harness stand in for Firestore, and lets nothing else.
///
/// Phase 3's whole device method rests on `SimulatedCheckInReader`: §10's
/// decision tree has branches — a **refused** read, an away period that cannot
/// be re-verified — that are all but impossible to produce on demand against a
/// real backend, and the harness produces each of them in a second. Losing that
/// on the day Firestore arrives would cost more than it saved.
///
/// So the real reader is the default and the simulated one is an override that
/// has to be **switched on deliberately**, by a harness control that writes a
/// row. Nothing else can reach it.
///
/// ## The gate is `kDebugMode`, and the argument that blocked it is gone
///
/// The Phase 3 security review proposed exactly this gate and it could not be
/// applied, for a good reason recorded at the time: *the clock offset has a real
/// fallback (`Duration.zero`) and the reader has none — in Phase 3 the simulated
/// reader **is** the implementation, so gating it would leave a release build
/// with no reader at all rather than with a safe default.*
///
/// Phase 4 removes that objection by supplying the fallback. The comment on
/// `AppServices.watcherReconcile` said the question would disappear when the
/// real reader landed; this is the line where it does.
///
/// What the gate buys is worth stating plainly, because the risk is not
/// theoretical. `debug_simulated_backend` is a row in a SQLite file, and a row
/// can arrive by a route nobody intended — a restore, a rooted device, a
/// migration bug. The value in it decides **whether a family is told that
/// somebody is fine**. In a release build this class does not consult it at all:
/// the branch is `kDebugMode`, a compile-time constant, so the release tree does
/// not contain the call.
class DebugBackendOverride implements CheckInReader {
  const DebugBackendOverride({required this.store, required this.real});

  final LocalStore store;

  /// Firestore. What every build uses unless a harness control says otherwise,
  /// and the only thing a release build can use at all.
  final CheckInReader real;

  @override
  Future<FirestoreRead> read(Link link) async {
    if (kDebugMode) {
      final raw = await store.simulatedBackendRaw();
      if (raw != null) return SimulatedBackend.decode(raw).toRead();
    }
    return real.read(link);
  }
}
