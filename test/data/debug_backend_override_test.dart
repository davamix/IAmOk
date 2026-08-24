@TestOn('vm')
library;

import 'package:i_am_ok/data/check_in_reader.dart';
import 'package:i_am_ok/data/debug_backend_override.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// The one switch that lets something other than Firestore answer *"is she all
/// right?"*.
///
/// Phase 3's device method depends on it — §10 has branches, a **refused** read
/// and an away period that cannot be re-verified, that are all but impossible to
/// produce on demand against a real backend and take a second in the harness. So
/// it stays. What this file asserts is that it is **off unless somebody turned
/// it on**, because the value it can inject decides whether a family is told
/// that somebody is fine.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
  });

  tearDown(() => store.close());

  final mum = Link(
    watchedUid: 'mum',
    watcherUid: 'ana',
    status: LinkStatus.accepted,
    watchedName: 'Mum',
    watcherName: 'Ana',
    watchedTimezone: 'Europe/Madrid',
    activeFrom: day('2026-08-01'),
    createdAt: at(madrid, 2026, 8, 1),
  );

  test('with no row set, it asks the real reader', () async {
    final real = _RecordingReader(const FirestoreRead.succeeded());
    final override = DebugBackendOverride(store: store, real: real);

    final read = await override.read(mum);

    expect(real.calls, 1, reason: 'Firestore is the default, not the fallback');
    expect(read, isA<ReadSucceeded>());
  });

  test('with a row set, it answers from the harness and does NOT ask', () async {
    // The device method in one assertion: the harness can produce a refused read
    // — the branch ADR-0004 exists for — without a backend that will refuse.
    await store.setSimulatedBackendRaw(
      const SimulatedBackend(outcome: SimulatedReadOutcome.refused).encode(),
    );
    final real = _RecordingReader(const FirestoreRead.succeeded());
    final override = DebugBackendOverride(store: store, real: real);

    final read = await override.read(mum);

    expect(read, isA<ReadRefused>());
    expect(real.calls, 0,
        reason: 'the override stands in FRONT of Firestore, not beside it — a '
            'read that reached the network as well would make the harness a '
            'second opinion rather than a substitute');
  });

  test('clearing the row hands control straight back', () async {
    await store.setSimulatedBackendRaw(
      const SimulatedBackend(outcome: SimulatedReadOutcome.refused).encode(),
    );
    await store.setSimulatedBackendRaw(null);

    final real = _RecordingReader(const FirestoreRead.succeeded());
    final read = await DebugBackendOverride(store: store, real: real).read(mum);

    expect(real.calls, 1);
    expect(read, isA<ReadSucceeded>());
  });

  test('the gate is kDebugMode, and this suite runs inside it', () {
    // Stated rather than assumed, because everything above passes identically
    // whether the gate exists or not: a debug test VM takes the debug branch
    // either way. What a test CANNOT reach is the release branch — `flutter
    // test` runs a debug VM, which is the same limit the Phase 3 review recorded
    // for the harness's own tree-shaking.
    //
    // So the guarantee "a release build never consults the row" rests on
    // `kDebugMode` being a compile-time constant that the tree shaker folds —
    // and on **nothing else**. This paragraph used to also claim "the
    // source-level check in `domain_purity_test.dart` that the branch is written
    // that way", and there is no such check: that file guards imports, clock
    // reads and `close()`, and knows nothing about `kDebugMode` branches
    // anywhere. Corrected at the Phase 4 gate, because a stale claim of coverage
    // inside a comment whose whole purpose is to stop people over-reading the
    // tests above it is the worst possible place for one.
    //
    // This test exists to say that limit out loud.
    var debug = false;
    assert(() {
      debug = true;
      return true;
    }());
    expect(debug, isTrue,
        reason: 'if this ever fails, the suite is running in release mode and '
            'the three tests above are asserting the other branch');
  });
}

/// A reader that records whether it was consulted.
///
/// The count is the assertion that matters: "did the override reach past the
/// harness to the network" is not visible in the returned value.
class _RecordingReader implements CheckInReader {
  _RecordingReader(this.answer);

  final FirestoreRead answer;
  int calls = 0;

  @override
  Future<FirestoreRead> read(Link link) async {
    calls++;
    return answer;
  }
}
