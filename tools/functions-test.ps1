# Runs the Cloud Functions tests against the emulator suite.
#
#   pwsh -File tools/functions-test.ps1
#
# Two runs, because they need different emulators and must not see each other's
# writes:
#
#   1. `functions/test/check_in_fan_out.test.js` — the fan-out against a REAL
#      emulated Firestore with a recording sender in place of FCM. Firestore
#      only, so no trigger fires and the run is quiet.
#   2. `functions/test/trigger_fires_once_per_day.mjs` — the §7 premise that a
#      second tap on the same day is an UPDATE and fires nothing. Needs the
#      functions emulator, and its only observable effect is a log line, so the
#      assertion is at the bottom of this file rather than inside the script.
#
# Nothing here touches the live project. Both runs use `demo-i-am-ok`, which the
# Firebase tooling treats as a guaranteed-offline project — no credentials are
# used and the SDKs will not reach production for it.
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
    Write-Host '1/2  fan-out, against the Firestore emulator' -ForegroundColor Cyan
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
    Write-Host '2/2  the trigger fires once per day, not once per tap' -ForegroundColor Cyan

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
}
finally {
    Pop-Location
}
