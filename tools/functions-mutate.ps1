# Runs the Cloud Functions mutation harness.
#
#   pwsh -File tools/functions-mutate.ps1
#
# A three-line wrapper around `node tools/mutate-invites.mjs`, and it exists for
# the same reason `tools/functions-test.ps1` does: **the Firestore emulator needs
# a JDK and `java` is NOT on PATH on this machine** (docs/infrastructure/
# deploy-notes.md). Without it the harness's very first run — the no-op control —
# fails, and the harness correctly refuses to score anything, which looks like a
# broken harness rather than a missing JDK.
#
# > **Only one emulator script at a time.** `tools/emulators.ps1`,
# > `tools/rules-test.ps1`, `tools/functions-test.ps1` and this all want ports
# > 8080 / 9099 / 5001. The second one to start fails with *"Port 8080 is not
# > open on localhost"*, which reads like a broken script rather than a busy port.
#
# This is SLOW by construction — one `firebase emulators:exec` per mutation,
# plus a `tsc` build before each, plus the no-op control. Expect minutes, not
# seconds. Run it when `functions/src/invites.ts` changes, not on every commit.
#
# Exit code is the harness's own: non-zero if any mutation SURVIVED or did not
# compile. Read the table it prints rather than the code — and when a mutation
# survives, check whether the MUTATION is bad before concluding the test is.

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
    node tools/mutate-invites.mjs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
