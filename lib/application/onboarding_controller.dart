import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/local_store.dart';
import '../domain/domain.dart';
import 'providers.dart';

/// Where the onboarding flow currently is.
///
/// Three screens with a Skip on each of the two questions, identical for every
/// user (PLAN.md), plus a sign-in in front of them — every link is keyed by a
/// uid, so nothing after [signIn] is answerable without one.
enum OnboardingStep {
  /// Nobody is signed in.
  signIn,

  /// *"Who should know you're OK?"* — answering makes this user **watched**.
  watchedQuestion,

  /// *"Who are you looking after?"* — answering makes them a **watcher**.
  watcherQuestion,

  /// What was set up, and what happens next.
  summary,
}

/// The flow's state. Deliberately small.
///
/// It holds **where the flow is and what was answered**, and nothing about the
/// invite or the code being typed. Those are per-screen and transient — a code
/// half-entered is not a fact about this user — and `WatchedStateNotifier`
/// already records the rule this follows: `tapFailed` is *"transient screen
/// state rather than something stored"*.
class OnboardingState {
  const OnboardingState({required this.step, required this.choices});

  final OnboardingStep step;
  final OnboardingChoices choices;

  OnboardingState copyWith({OnboardingStep? step, OnboardingChoices? choices}) =>
      OnboardingState(
        step: step ?? this.step,
        choices: choices ?? this.choices,
      );

  @override
  bool operator ==(Object other) =>
      other is OnboardingState &&
      other.step == step &&
      other.choices == choices;

  @override
  int get hashCode => Object.hash(step, choices);

  @override
  String toString() => 'OnboardingState(${step.name}, $choices)';
}

/// Drives the three screens, and records what they answered.
///
/// ## What this owns, and what it deliberately does not
///
/// It owns the **step** and the **two answers**, because those decide where the
/// app opens for ever afterwards ([HomeRoute]). It does not own the invite code,
/// the text in the code field, or any error message — those belong to the screen
/// showing them and die with it.
///
/// ## Advancing is not the same as recording
///
/// [answeredWatched] and [answeredWatcher] take a bool, so a **skip is an
/// answer** rather than an absence. That is what stops the flow re-running every
/// launch, and `HomeRoute.decide` depends on it: a user who skipped both is
/// `completed` with neither role, which routes to the Tap screen rather than
/// back into these questions.
class OnboardingController extends Notifier<OnboardingState> {
  /// **`ref.read`, never `ref.watch`, and that is a fix rather than a style
  /// choice.**
  ///
  /// [_persist] invalidates [onboardingChoicesProvider] so the **router** sees
  /// the new answers — that is the whole reason the flow can ever end. Watching
  /// the same provider here made every answer rebuild this notifier, which reset
  /// `step` to its initial value: answering the first question persisted the
  /// answer, rebuilt, and put the reader **back on the first question**. An
  /// infinite loop on screen one of a flow whose entire job is to be finished
  /// once.
  ///
  /// Reading is safe here rather than merely convenient, and the ordering is a
  /// real invariant: `Home` renders a spinner until `homeRouteProvider` is
  /// non-null, and that provider cannot answer without
  /// [onboardingChoicesProvider] having a value. So by the time an onboarding
  /// screen exists to build this controller, the answers are loaded.
  ///
  /// Identity is read for the same reason. Signing in moves the step explicitly
  /// in [signedIn]; a rebuild driven by `appServicesProvider` would be a second
  /// mechanism doing the same job, and the two would race.
  @override
  OnboardingState build() {
    final services = ref.read(appServicesProvider);
    return OnboardingState(
      step: services.signedIn
          ? OnboardingStep.watchedQuestion
          : OnboardingStep.signIn,
      // Seeded from whatever is on disk rather than assumed empty: the flow can
      // be re-entered from a main screen, and re-entering must not silently
      // clear an answer this user already gave.
      choices: ref.read(onboardingChoicesProvider).value ??
          const OnboardingChoices.none(),
    );
  }

  /// After a successful sign-in.
  ///
  /// The uid is handed to [SignedInUid] so `appServicesProvider` rebuilds —
  /// which is what lets the rest of the flow act as the new account without the
  /// restart the debug harness could ask a developer for.
  void signedIn(String uid) {
    ref.read(signedInUidProvider.notifier).signedInAs(uid);
    state = state.copyWith(step: OnboardingStep.watchedQuestion);
  }

  /// Screen 1 answered — [wants] is false when they skipped.
  Future<void> answeredWatched({required bool wants}) async {
    final choices = state.choices.copyWith(wantsToBeWatched: wants);
    await _persist(choices);
    state = OnboardingState(
      step: OnboardingStep.watcherQuestion,
      choices: choices,
    );
  }

  /// Screen 2 answered — [wants] is false when they skipped.
  Future<void> answeredWatcher({required bool wants}) async {
    final choices = state.choices.copyWith(wantsToWatch: wants);
    await _persist(choices);
    state = OnboardingState(step: OnboardingStep.summary, choices: choices);
  }

  /// Back to the previous question, without losing what was answered.
  void back() {
    state = state.copyWith(
      step: switch (state.step) {
        OnboardingStep.summary => OnboardingStep.watcherQuestion,
        OnboardingStep.watcherQuestion => OnboardingStep.watchedQuestion,
        OnboardingStep.signIn ||
        OnboardingStep.watchedQuestion =>
          state.step,
      },
    );
  }

  /// The summary's *Finish*: the flow has run, so it does not run again.
  ///
  /// **Marked complete even when both questions were skipped**, which is the
  /// whole reason `completed` is a separate flag from the two answers. Without
  /// it, someone who wants neither role is asked the same two questions every
  /// single launch — the app nagging the one user `guidelines.md` says it must
  /// never nag.
  Future<void> finish() async {
    final choices = state.choices.copyWith(completed: true);
    await _persist(choices);
    state = state.copyWith(choices: choices);
    // **The one place the router is told, and that is the fix.** See [_persist].
    ref.invalidate(onboardingChoicesProvider);
    // The links too: a pairing made during the flow is what decides which main
    // screen this user lands on, and `linkRolesProvider` read the store before
    // it existed.
    ref.invalidate(linkRolesProvider);
  }

  /// Records a pairing that just happened, so the flow's own answers match the
  /// links it produced.
  ///
  /// Called by the pairing screens rather than inferred, because the screens are
  /// where the outcome is known. It matters for the **re-entry** route: somebody
  /// who skipped screen 1 and later adds a watcher from the Tap screen has
  /// changed their mind, and their stored answer should say so rather than being
  /// carried for ever by the link alone.
  Future<void> recordPairing({bool? asWatched, bool? asWatcher}) async {
    final choices = state.choices.copyWith(
      wantsToBeWatched: asWatched == true ? true : null,
      wantsToWatch: asWatcher == true ? true : null,
    );
    if (choices == state.choices) return;
    await _persist(choices);
    state = state.copyWith(choices: choices);
  }

  /// Writes the answers, and **deliberately does not tell the router.**
  ///
  /// ## Measured on two phones, 2026-08-26 — the summary screen was unreachable
  ///
  /// This used to invalidate [onboardingChoicesProvider] on every write, which
  /// is what `homeRouteProvider` watches. So the moment a question was answered
  /// **affirmatively**, the route recomputed with a role, found one, and left
  /// onboarding — putting the reader straight onto a main screen. Screen 3 is a
  /// deliverable of this phase and no user ever saw it: both endpoints of the
  /// pairing run went from *"Skip for now"* to the Tap screen and the watcher
  /// list respectively, with the summary skipped in between.
  ///
  /// Nothing in the suite could see it. The route is right, the answers are
  /// right, and each piece is individually correct — the defect is only visible
  /// as a *screen a person never reaches*, which is what a device run is for.
  ///
  /// So the router is told **once**, by [finish], which is the only moment the
  /// flow is actually over. The intermediate writes still land on disk, so a
  /// flow abandoned half way is not lost.
  Future<void> _persist(OnboardingChoices choices) async {
    await ref.read(appServicesProvider).store.setOnboardingChoices(choices);
  }
}

final onboardingControllerProvider =
    NotifierProvider<OnboardingController, OnboardingState>(
  OnboardingController.new,
);

/// The answers as `LocalStore` holds them.
///
/// Separate from [onboardingControllerProvider] because **`main.dart` needs them
/// before any onboarding screen is built** — [HomeRoute.decide] takes them to
/// choose which screen the app opens on at all, and building the flow's
/// controller to answer that would be the routing depending on the thing it is
/// routing away from.
final onboardingChoicesProvider = FutureProvider<OnboardingChoices>(
  (ref) => ref.watch(appServicesProvider).store.onboardingChoices(),
);

/// Which links this user actually has, as evidence for [HomeRoute.decide].
///
/// Read from `LocalStore` rather than from Firestore: `main()` and every resume
/// already run `syncLinks()` before anything reconciles, so the store is the
/// fresh copy, and a router that made its own network call would put a round
/// trip in front of the first frame of the app.
final linkRolesProvider = FutureProvider<({bool watched, bool watcher})>((
  ref,
) async {
  final services = ref.watch(appServicesProvider);
  if (!services.signedIn) return (watched: false, watcher: false);

  // **`LocalStore`'s two names read the opposite way round to these**, and
  // getting them the wrong way here would route every watcher to the Tap screen
  // and every watched person to a list of nobody. Spelled out rather than
  // inlined:
  //
  //   linksWatching(uid)   → watched_uid = uid → somebody is watching ME
  //   linksWatchedBy(uid)  → watcher_uid = uid → I am watching somebody
  final somebodyWatchesMe = await services.store.linksWatching(services.selfUid);
  final iWatchSomebody = await services.store.linksWatchedBy(services.selfUid);

  // **Accepted only.** A revoked link is not a role, it is a role that ended,
  // and `WatchedAudience` records at length why this app renders no such thing.
  return (
    watched: somebodyWatchesMe.any((link) => link.isAccepted),
    watcher: iWatchSomebody.any((link) => link.isAccepted),
  );
});

/// The two device facts a screen needs to render an instant the reader
/// recognises: their own zone, and whether they read 12- or 24-hour times.
///
/// **Read from `LocalStore`, never from a plugin**, which is ADR-0002's rule
/// applied at a third call site. `ClockService` discovers both and the UI caches
/// them on launch and on every resume; everything downstream — notification,
/// watcher row, and now the code's expiry — renders from that one pair, which is
/// what stops two surfaces disagreeing about the same instant.
///
/// The UTC fallbacks are ADR-0002's documented ones. On this screen the cost of
/// taking them is a code expiry rendered in the wrong zone, which is cosmetic —
/// unlike the alarm path, where the same fallback armed a whole window at UTC
/// wall times on the POCO F3.
final deviceFactsProvider =
    FutureProvider<({tz.Location zone, bool uses24Hour})>((ref) async {
  final store = ref.watch(appServicesProvider).store;
  final zoneName = await store.deviceTimezone();
  return (
    zone: zoneName == null
        ? TimeZones.utc
        : TimeZones.tryLocation(zoneName) ?? TimeZones.utc,
    uses24Hour: await store.uses24HourClock(),
  );
});

/// Where the app opens. The pure decision is [HomeRoute.decide]; this only
/// gathers its inputs.
///
/// Returns null while the inputs are still loading, which the shell renders as
/// the loading state rather than guessing — routing to the wrong main screen and
/// correcting it a frame later would move the tap target, and
/// `guidelines.md` calls a layout that reflows a bug.
final homeRouteProvider = Provider<HomeRoute?>((ref) {
  final services = ref.watch(appServicesProvider);
  final choices = ref.watch(onboardingChoicesProvider);
  final roles = ref.watch(linkRolesProvider);

  final choicesValue = choices.value;
  final rolesValue = roles.value;
  if (choicesValue == null || rolesValue == null) return null;

  return HomeRoute.decide(
    signedIn: services.selfUid != LocalStore.signedOutUid,
    choices: choicesValue,
    hasAcceptedWatchedLinks: rolesValue.watched,
    hasAcceptedWatcherLinks: rolesValue.watcher,
  );
});
