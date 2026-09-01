@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/copy/away_copy.dart';
import 'package:i_am_ok/copy/onboarding_copy.dart';
import 'package:i_am_ok/data/auth_repository.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/clock_service.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/permission_service.dart';
import 'package:i_am_ok/presentation/app_theme.dart';
import 'package:i_am_ok/presentation/onboarding_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/zones.dart';

/// **Asking for a name when the account has none.**
///
/// Google Sign-In almost always supplies a display name. When it does not, the
/// app wrote the literal string `'Someone'` into `users/{uid}`, and
/// `redeemInvite` denormalises that onto every link (§7) — so the person read as
/// *"Someone"* on their family's phones for ever after: *"Choose the last day
/// Someone is away"*, *"Someone marked you away"*. `guidelines.md` forbids naming
/// a role, and it is worse than cosmetic, because `AwayRecord.unnameable` is the
/// **same string** used as a sentinel meaning *nobody can be named* — so the
/// placeholder silently suppressed this person's away attribution as well.
///
/// ## Why the screen is pumped on its own rather than through `OnboardingScreen`
///
/// Pumping anything that reaches a real `LocalStore` **hangs**: `WidgetTester`
/// runs in a fake-async zone, `sqflite` does real I/O off it, and the test times
/// out rather than failing. That is not a guess — `app_lifecycle_test.dart`
/// records it in full and is the reason `IAmOkApp` is never pumped, and it was
/// re-confirmed while writing this file. So [AskNameForm] is public and
/// provider-free, and everything it decides is asserted by pumping it with a
/// callback. What that leaves uncovered is one line in `_SignInState.build` —
/// which form to show — and it is covered instead by
/// [AppServices.needsDisplayName], the boolean that line reads.
///
/// ## The assertion that carries the feature is the precedence one
///
/// `AppServices.refreshProfile` runs on **every launch** and rewrites
/// `users/{uid}`. A typed name it did not prefer would be overwritten by the
/// placeholder within minutes — the feature would appear to work, and then
/// forget. That is what `profileDisplayName` exists for, and it is tested
/// directly, because the screen is not where it would break.
class _FakeAuth extends AuthRepository {
  _FakeAuth(super.store, {this.name});

  /// What the account came back with. Null is the case this file is about.
  final String? name;

  @override
  String? get displayName => name;
}

class _SilentNotifications extends NotificationService {
  _SilentNotifications() : super(FlutterLocalNotificationsPlugin());

  @override
  Future<bool> canPost({AndroidNotificationChannel? channel}) async => true;
}

class _NoAlarms implements AlarmScheduler {
  @override
  Future<bool> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
    required bool hasAudience,
  }) async => true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<int> armedAccordingToPlugin() async => 0;
}

class _MadridClockService extends ClockService {
  const _MadridClockService();

  @override
  Future<String?> deviceTimezone() async => 'Europe/Madrid';

  @override
  bool uses24HourClock() => true;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TimeZones.ensureInitialized();
  final madrid = TimeZones.location('Europe/Madrid');

  // ---------------------------------------------------------------- the form

  group('the question, pumped on its own', () {
    /// The names the form handed back, so the negative cases can assert that it
    /// handed back nothing at all.
    late List<String> submitted;

    Future<void> pumpForm(
      WidgetTester tester, {
      bool busy = false,
      String? error,
      double textScale = 1,
      Size surface = const Size(400, 800),
    }) async {
      submitted = [];
      tester.view.physicalSize = surface * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(
                body: AskNameForm(
                  busy: busy,
                  error: error,
                  onSubmit: submitted.add,
                ),
              ),
            ),
          ),
        ),
      );
      // Two plain pumps rather than `pumpAndSettle`: the busy state renders a
      // `CircularProgressIndicator`, which animates for ever, so settling can
      // never return there. The same reason `app_lifecycle_test.dart` gives for
      // never using `pumpAndSettle` on the Tap screen.
      await tester.pump();
      await tester.pump();
    }

    testWidgets('says what happened and what to do', (tester) async {
      // `guidelines.md`'s rule for anything that interrupts somebody. The blurb
      // is one sentence of each.
      await pumpForm(tester);

      expect(find.text(OnboardingCopy.nameTitle), findsOneWidget);
      expect(find.text(OnboardingCopy.nameBlurb), findsOneWidget);
      expect(find.text(OnboardingCopy.nameFieldLabel), findsOneWidget,
          reason: 'a label, not a hint: a hint is not read as one');
      expect(find.text(OnboardingCopy.nameAction), findsOneWidget);
    });

    testWidgets('a typed name comes back trimmed', (tester) async {
      await pumpForm(tester);

      await tester.enterText(find.byKey(nameFieldKey), '  Mum  ');
      await tester.tap(find.byKey(nameSubmitKey));
      await tester.pumpAndSettle();

      expect(submitted, ['Mum'],
          reason: 'the rules bound displayName 1-100 AFTER trimming');
    });

    testWidgets('an empty name is refused, and nothing is handed back',
        (tester) async {
      // The negative, and the one that matters: an empty `displayName` is not
      // merely unhelpful, it is a `permission-denied` on the one write that
      // makes pairing possible — and the refusal would surface on somebody
      // else's phone, as a code that will not work.
      await pumpForm(tester);

      await tester.tap(find.byKey(nameSubmitKey));
      await tester.pumpAndSettle();

      expect(submitted, isEmpty);
      expect(find.text(OnboardingCopy.nameEmpty), findsOneWidget);
    });

    testWidgets('and so is one that is only spaces', (tester) async {
      await pumpForm(tester);

      await tester.enterText(find.byKey(nameFieldKey), '   ');
      await tester.tap(find.byKey(nameSubmitKey));
      await tester.pumpAndSettle();

      expect(submitted, isEmpty);
      expect(find.text(OnboardingCopy.nameEmpty), findsOneWidget);
    });

    testWidgets('the refusal clears once a real name is typed', (tester) async {
      await pumpForm(tester);
      await tester.tap(find.byKey(nameSubmitKey));
      await tester.pumpAndSettle();
      expect(find.text(OnboardingCopy.nameEmpty), findsOneWidget);

      await tester.enterText(find.byKey(nameFieldKey), 'Pop');
      await tester.tap(find.byKey(nameSubmitKey));
      await tester.pumpAndSettle();

      expect(submitted, ['Pop']);
      expect(find.text(OnboardingCopy.nameEmpty), findsNothing,
          reason: 'a refusal that outlives what it refused is a stale claim');
    });

    testWidgets('a name longer than the rules allow cannot be typed at all',
        (tester) async {
      // Enforced by the field rather than by a message: a limit somebody cannot
      // exceed beats a refusal they could not see coming.
      await pumpForm(tester);

      await tester.enterText(find.byKey(nameFieldKey), 'a' * 250);
      await tester.tap(find.byKey(nameSubmitKey));
      await tester.pumpAndSettle();

      expect(submitted.single.length, 100);
    });

    testWidgets('while a write is in flight nothing can be submitted twice',
        (tester) async {
      // One press must not become two `users/{uid}` writes.
      await pumpForm(tester, busy: true);

      await tester.tap(find.byKey(nameSubmitKey), warnIfMissed: false);
      await tester.pump();

      expect(submitted, isEmpty);
    });

    testWidgets('a write failure is shown without blaming the field',
        (tester) async {
      // `errorText` turns the field red and relabels it invalid. The profile
      // write failing says nothing about what was typed — the same distinction
      // `pairing_screens.dart` draws for the code field.
      await pumpForm(tester, error: OnboardingCopy.profileFailed);

      expect(find.text(OnboardingCopy.profileFailed), findsOneWidget);
      expect(find.text(OnboardingCopy.nameEmpty), findsNothing);
    });

    testWidgets('the floors: 48dp, and reachable at the largest scale',
        (tester) async {
      await pumpForm(tester);
      expect(tester.getSize(find.byKey(nameSubmitKey)).height,
          greaterThanOrEqualTo(48));

      await pumpForm(
        tester,
        surface: const Size(320, 480),
        textScale: 2,
      );
      expect(tester.takeException(), isNull,
          reason: 'the page scrolls; nothing here may overflow');
      // REACHABLE, not merely present: the Phase 6 gate found an away control
      // below the fold at this scale, measured by a test that could not fail
      // because it called `getSize` on a widget outside the viewport.
      await tester.ensureVisible(find.byKey(nameFieldKey));
      await tester.ensureVisible(find.byKey(nameSubmitKey));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  // ------------------------------------------------- who gets asked, and what
  // ------------------------------------------------- ends up in the document

  group('who is asked', () {
    late LocalStore store;

    setUp(() async {
      store = await LocalStore.open(path: inMemoryDatabasePath);
    });
    tearDown(() => store.close());

    AppServices servicesWith(String? accountName) {
      final notifications = _SilentNotifications();
      return AppServices(
        store: store,
        clock: FixedClock(at(madrid, 2026, 9, 1, 9)),
        notifications: notifications,
        alarms: _NoAlarms(),
        permissions: PermissionService(notifications),
        clockService: const _MadridClockService(),
        selfUid: LocalStore.signedOutUid,
        auth: _FakeAuth(store, name: accountName),
      );
    }

    test('an account with a name is never asked', () async {
      expect(servicesWith('Ana').needsDisplayName, isFalse);
    });

    test('an account without one is', () async {
      expect(servicesWith(null).needsDisplayName, isTrue);
    });

    test('and so is one whose name is only spaces', () async {
      // The rules require 1-100 characters after trimming, so '   ' is not a
      // name the profile write would be allowed to carry.
      expect(servicesWith('   ').needsDisplayName, isTrue);
      expect(servicesWith('').needsDisplayName, isTrue);
    });

    group('what is written to users/{uid}', () {
      test('a typed name beats the account name, and the placeholder', () async {
        // **The assertion the whole feature rests on.** `refreshProfile` runs on
        // every launch; preferring `auth.displayName` here would overwrite a
        // typed name with the placeholder within minutes of somebody entering
        // it, and the bug would look like the feature never worked.
        await store.setChosenDisplayName('Mum');

        expect(await servicesWith(null).profileDisplayName(), 'Mum');
        expect(await servicesWith('Ana').profileDisplayName(), 'Mum');
      });

      test('the account name is used when nothing was typed', () async {
        expect(await servicesWith('Ana').profileDisplayName(), 'Ana');
      });

      test('and the placeholder is the last resort, not the first', () async {
        // Still reachable — somebody who has never been asked, on a build from
        // before this existed — so it stays, and `AwayRecord.nameToShowFor`
        // still suppresses it. It is no longer what an ordinary new user gets.
        expect(await servicesWith(null).profileDisplayName(),
            AwayCopy.unnamedWriter);
      });

      test('the stored name survives a round trip through the store', () async {
        expect(await store.chosenDisplayName(), isNull);
        await store.setChosenDisplayName('Pop');
        expect(await store.chosenDisplayName(), 'Pop');
      });
    });
  });
}
