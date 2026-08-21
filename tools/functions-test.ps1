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
        'npm --prefix functions test'
    if ($LASTEXITCODE -ne 0) { Write-Error "fan-out tests failed (exit $LASTEXITCODE)" }

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
    if ($triggerExit -ne 0) { Write-Error "the trigger probe failed (exit $triggerExit)" }

    # `probe: done` proves the script itself reached the end. Without it, an
    # emulator that never dispatched anything and a script that died on its first
    # write look identical: zero fan-out lines either way.
    if (-not ($lines -match 'probe: done')) {
        Write-Error 'the probe never reached the end - the counts below would be meaningless'
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

    Write-Host ''
    Write-Host 'PASS  once per day, not once per tap' -ForegroundColor Green
}
finally {
    Pop-Location
}
