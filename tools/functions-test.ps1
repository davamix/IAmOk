# Runs the Cloud Functions tests against the emulator suite.
#
#   pwsh -File tools/functions-test.ps1
#
# Four runs. Three need different emulators and must not see each other's
# writes; the fourth needs no emulator at all:
#
#   1. `npm test`, which globs `functions/test/*.test.js` — so it picks up new
#      suites automatically, and today that is BOTH `check_in_fan_out.test.js`
#      (the fan-out against a REAL emulated Firestore with a recording sender in
#      place of FCM) and `invites.test.js` (Phase 5's two callables' cores).
#      Firestore only, so no trigger fires and the run is quiet.
#      `--test-concurrency=1` serialises them, which matters because both clear
#      `links/`.
#   2. `functions/test/trigger_fires_once_per_day.mjs` — the §7 premise that a
#      second tap on the same day is an UPDATE and fires nothing. Needs the
#      functions emulator, and its only observable effect is a log line, so the
#      assertion is at the bottom of this file rather than inside the script.
#   3. `functions/test/away_trigger_fires.mjs` — the same shape, for the trigger
#      run 2 does not touch. `onAwayChanged`'s fan-out is well covered by run 1;
#      its REGISTRATION was executed by nothing at all until this run existed,
#      and what that leaves unrun is `event.params.uid` and the delete adapter —
#      the cancellation path. Separate from run 2 rather than folded into it
#      because both scripts write, wait, and assert on a count of log lines, and
#      one run's dispatch latency would show up as the other's missing line.
#   4. `functions/test/deploy_options.mjs` — the deploy-shaping options, read off
#      the BUILT module's `__endpoint`, which is what `firebase deploy` reads.
#      No emulator and no network. It exists because `redeemInvite`'s
#      `concurrency: 1, maxInstances: 3` is a security control that
#      `OPEN-QUESTIONS.md` #11 and `threat-model.md` both rest on, and until the
#      Phase 6 gate nothing anywhere asserted either number.
#
# Nothing here touches the live project. The three emulator runs use
# `demo-i-am-ok`, which the Firebase tooling treats as a guaranteed-offline
# project — no credentials are used and the SDKs will not reach production for
# it — and run 4 loads a module without connecting to anything.
#
# ## THREE scripts now want ports 8080 / 9099 / 5001, and only one may run
#
# `tools/emulators.ps1` (the dev suite), `tools/rules-test.ps1` and this one.
# Stop whichever is running before starting another; the failure is loud —
# *"Port 8080 is not open on localhost"* — but it reads like a broken script
# rather than a busy port.
#
# ## The namespace trap does not apply here, and it is worth saying why
#
# `tools/emulators.ps1` carries a long note about `--project` naming a namespace
# the app never looks in, which produced a false green in Phase 4. That failure
# was about SECURITY RULES: the Firestore emulator loads `firestore.rules` into
# only the project it was started with, and the app takes its project id from
# `google-services.json` rather than from this flag.
#
# Neither half applies to these tests. They authenticate as ADMIN, which bypasses
# rules entirely, and they read their project id out of `GCLOUD_PROJECT` — which
# `emulators:exec` sets from this very flag — so the namespace they write to and
# the namespace the emulator serves cannot disagree. Both scripts assert on that
# variable before writing anything, and refuse to run against a non-`demo-`
# project.
#
# ## Why this script exists rather than a bare `firebase emulators:exec`
#
# **Java.** The Firestore emulator needs a JDK and `java` is NOT on PATH on this
# machine (docs/infrastructure/deploy-notes.md).
#
# **The Functions emulator serves the COMPILED output**, so a stale `lib/` is a
# stale function — and the fan-out tests import `lib/` too, for the same reason:
# testing `src/` would test something neither the emulator nor production runs.

[CmdletBinding()]
param(
    # Point at a different JDK if Android Studio moves.
    [string]$JavaHome = 'D:\Android\Android Studio\jbr'
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path (Join-Path $JavaHome 'bin\java.exe'))) {
    Write-Error "No java.exe under '$JavaHome'. Pass -JavaHome with the path to a JDK."
}

$env:JAVA_HOME = $JavaHome
$env:PATH = (Join-Path $JavaHome 'bin') + [IO.Path]::PathSeparator + $env:PATH

Push-Location $repo
try {
    Write-Host 'Building functions...' -ForegroundColor Cyan
    npm --prefix functions run build
    if ($LASTEXITCODE -ne 0) { Write-Error 'functions build failed - not testing a stale lib/' }

    Write-Host ''
    Write-Host '1/3  fan-out, against the Firestore emulator' -ForegroundColor Cyan
    firebase emulators:exec --only firestore --project demo-i-am-ok `
        'npm --prefix functions test' 2>&1 | Tee-Object -Variable fanOutOutput
    $fanOutExit = $LASTEXITCODE

    # CONTENT FIRST, exit code second - CLAUDE.md: on Windows no Firebase CLI
    # exit code is a result. These commands print their work and then die with a
    # libuv assertion in win/async.c, intermittently, on commands well
    # outside `apps:*`. Judging the code first turns a passing suite into a red
    # that sends someone looking for a test failure that is not there.
    $fanOutLines = @($fanOutOutput | ForEach-Object { $_.ToString() })
    $summary = @($fanOutLines | Select-String -Pattern '^\s*.\s*(pass|fail) \d+')
    $failed = @($fanOutLines | Select-String -Pattern '(pass|fail) [1-9]\d*' |
        Where-Object { $_.Line -match 'fail [1-9]' })
    if ($summary.Count -eq 0) {
        Write-Error ("the fan-out suite printed no test summary at all (exit $fanOutExit). " +
            'That is a run that did not happen, not a run that passed.')
    }
    if ($failed.Count -gt 0) {
        Write-Error "fan-out tests FAILED: $($failed[0].Line.Trim())"
    }
    if ($fanOutExit -ne 0) {
        Write-Host ("  note: exit $fanOutExit with a clean summary - the documented Windows " +
            'libuv crash. The output above is the result.') -ForegroundColor DarkYellow
    }

    Write-Host ''
    Write-Host '2/3  the trigger fires once per day, not once per tap' -ForegroundColor Cyan

    # Captured as well as shown, because the ASSERTION IS ON THE OUTPUT. The
    # trigger's only effect with no links seeded is a log line, which is the
    # whole point: no push, no credentials, nothing to misread.
    firebase emulators:exec --only firestore,functions --project demo-i-am-ok `
        'node functions/test/trigger_fires_once_per_day.mjs' 2>&1 |
        Tee-Object -Variable captured
    $triggerExit = $LASTEXITCODE

    $lines = @($captured | ForEach-Object { $_.ToString() })

    # Again: content first. `probe: done` proves the script itself reached the
    # end. Without it, an emulator that never dispatched anything and a script
    # that died on its first write look identical - zero fan-out lines either way.
    if (-not ($lines -match 'probe: done')) {
        Write-Error ("the probe never reached the end (exit $triggerExit) - the counts " +
            'below would be meaningless')
    }
    if ($triggerExit -ne 0) {
        Write-Host ("  note: exit $triggerExit though the probe completed - the documented " +
            'Windows libuv crash.') -ForegroundColor DarkYellow
    }

    $fanned = @($lines | Select-String -SimpleMatch 'onCheckInCreated: fanned out')

    Write-Host ''
    Write-Host "onCheckInCreated ran $($fanned.Count) time(s):" -ForegroundColor DarkGray
    $fanned | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    # THREE writes went in - create day one, tap again on day one, create day
    # two - and exactly TWO of them are creates. A count that came out the same
    # whichever of those the emulator dispatched would prove nothing, so the
    # dates are checked too: this is the mutation check, run every time rather
    # than once by hand.
    $sawDayOne = @($fanned | Select-String -SimpleMatch '2026-08-21').Count
    $sawDayTwo = @($fanned | Select-String -SimpleMatch '2026-08-22').Count

    if ($fanned.Count -ne 2 -or $sawDayOne -ne 1 -or $sawDayTwo -ne 1) {
        Write-Error ("expected onCheckInCreated to run exactly twice - once per CREATE - " +
            "with one line for 2026-08-21 and one for 2026-08-22; " +
            "got $($fanned.Count) line(s), $sawDayOne and $sawDayTwo. " +
            'A third line for 2026-08-21 means the second tap fired the trigger, which is ' +
            'the premise ARCHITECTURE.md section 7 rests on when it says no dedupe logic is needed.')
    }

    # The fourth write is a NON-DAY document id, which the rules would never
    # allow a client to create but an admin write can - `tools/seed-link.ps1` and
    # the console both go through that door.
    #
    # Asserting the fan-out count stayed at two is NOT enough on its own: it
    # would also pass if the write had silently failed, or if the trigger had not
    # fired at all. So the guard's own line has to be there, which is what says
    # the trigger ran AND `isDayKey` is what stopped it.
    $ignored = @($lines | Select-String -SimpleMatch 'ignoring non-day document id')
    if ($ignored.Count -ne 1) {
        Write-Error ("expected exactly one 'ignoring non-day document id' line - the trigger " +
            "fires for ANY document under days/, and isDayKey is what stops a label no " +
            "client could ever read back from waking a fleet of phones. Got $($ignored.Count).")
    }
    Write-Host "the non-day id was rejected by the guard, not by luck:" -ForegroundColor DarkGray
    $ignored | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host 'PASS  once per day, not once per tap; a non-day id fires nothing' -ForegroundColor Green

    Write-Host ''
    Write-Host '3/4  onAwayChanged is wired, and a cancellation reaches it' -ForegroundColor Cyan

    firebase emulators:exec --only firestore,functions --project demo-i-am-ok `
        'node functions/test/away_trigger_fires.mjs' 2>&1 |
        Tee-Object -Variable awayCaptured
    $awayExit = $LASTEXITCODE

    $awayLines = @($awayCaptured | ForEach-Object { $_.ToString() })

    if (-not ($awayLines -match 'probe: done')) {
        Write-Error ("the away probe never reached the end (exit $awayExit) - the counts " +
            'below would be meaningless')
    }
    if ($awayExit -ne 0) {
        Write-Host ("  note: exit $awayExit though the probe completed - the documented " +
            'Windows libuv crash.') -ForegroundColor DarkYellow
    }

    # A COLD START IS NOT A CODE DEFECT, and this run could not tell the two
    # apart. CLAUDE.md records the measurement made the same day this run was
    # written: the Functions emulator's FIRST invocation of a session can die in
    # module resolution after **24 seconds**. Runs 2 and 3 are separate
    # `emulators:exec` invocations, so each pays that cost fresh, against this
    # probe's 6-second settle - four times shorter.
    #
    # When it overruns, the fan-out lines are simply ABSENT, and every assertion
    # below then reports one of two specific code defects - "the trigger is
    # create-only" or "the delete adapter did not run" - for what is a flake.
    # Sending somebody to read a correct registration is exactly the cost this
    # project pays for a harness that cannot distinguish a broken run from a
    # failing one.
    $coldStart = @($awayLines | Select-String -SimpleMatch -Pattern @(
        'Failed to load function', 'Failed to handle request'))
    if ($coldStart.Count -gt 0) {
        Write-Error ("the functions runtime never loaded: '$($coldStart[0].Line.Trim())'. " +
            'That is the documented cold start (CLAUDE.md, measured at 24s), not a code ' +
            'fault - the assertions below would name a defect that is not there. Re-run; ' +
            'the second invocation of a session is warm.')
    }

    $awayFanned = @($awayLines | Select-String -SimpleMatch 'onAwayChanged: fanned out')

    Write-Host ''
    Write-Host "onAwayChanged ran $($awayFanned.Count) time(s):" -ForegroundColor DarkGray
    $awayFanned | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    # THE COUNT ALONE PROVES ALMOST NOTHING, which is the whole reason this run
    # exists. Three writes went in - a create, a truncating update and a delete -
    # and each has its own way of disappearing silently:
    #
    #   `cleared:false` twice   the CREATE and the UPDATE. Switch the
    #                           registration to `onDocumentCreated` - the
    #                           plausible copy-paste from the function above it -
    #                           and the update goes silent while everything still
    #                           looks wired.
    #   `cleared:true` once     the DELETE, through
    #                           `after?.exists === true ? after.data() : undefined`.
    #                           This is the cancellation path, and it had never
    #                           been executed by anything before this run. A
    #                           count of three would pass with the delete
    #                           reported as just another period.
    #
    # The uid is matched rather than assumed: it can only have come from
    # `event.params.uid`, which reads the document PATH. Nothing in the body
    # carries it.
    #
    # Rendering differs between the emulator's structured and plain log output -
    # `"cleared":false` and `cleared: false` - so the separator is matched
    # loosely on purpose. Tightening it to one form is how this assertion starts
    # passing vacuously.
    $cleared = @($awayFanned | Where-Object { $_.Line -match 'cleared\W{1,4}false' })
    $cancelled = @($awayFanned | Where-Object { $_.Line -match 'cleared\W{1,4}true' })
    $named = @($awayFanned | Select-String -SimpleMatch 'uid-away-probe')

    if ($awayFanned.Count -ne 3 -or $cleared.Count -ne 2 -or $cancelled.Count -ne 1) {
        Write-Error ("expected onAwayChanged to run exactly three times - create, update, " +
            "delete - with two 'cleared:false' lines and one 'cleared:true'; got " +
            "$($awayFanned.Count) line(s), $($cleared.Count) and $($cancelled.Count). " +
            'A missing update line means the trigger is create-only, which would silence ' +
            'every truncation; a missing cleared:true means the delete adapter did not run, ' +
            'and that is the cancellation - the one the docstring calls the one that matters ' +
            'most, because until every device hears about it their family stays silent.')
    }
    if ($named.Count -ne 3) {
        Write-Error ("expected all three lines to name uid-away-probe, from event.params.uid " +
            "- the document path is the only place that uid exists. Got $($named.Count).")
    }

    Write-Host ''
    Write-Host 'PASS  the registration dispatches; the update and the delete both arrive' -ForegroundColor Green

    Write-Host ''
    Write-Host '4/4  the deploy options are what the security argument assumes' -ForegroundColor Cyan

    # No emulator: this loads the built module and reads the manifest
    # `firebase deploy` reads. Last, because it needs `lib/` and nothing else,
    # so a failure here is unambiguously about the options rather than about a
    # port, a JDK or a cold start.
    node functions/test/deploy_options.mjs 2>&1 | Tee-Object -Variable optionsCaptured
    $optionsExit = $LASTEXITCODE

    $optionsLines = @($optionsCaptured | ForEach-Object { $_.ToString() })
    if (-not ($optionsLines -match 'probe: done')) {
        Write-Error ("the options probe did not reach its end (exit $optionsExit). Its " +
            'assertions are the only thing anywhere that pins redeemInvite to ' +
            'concurrency 1 / maxInstances 3, which OPEN-QUESTIONS.md #11 rests on.')
    }

    Write-Host ''
    Write-Host 'PASS  redeemInvite is still capped, and every function is still in europe-west1' -ForegroundColor Green
}
finally {
    Pop-Location
}
