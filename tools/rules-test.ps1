# Runs the Firestore security-rules tests against the emulator suite.
#
#   pwsh -File tools/rules-test.ps1
#
# Nothing here touches the live project. The emulator is started against the
# project id `demo-i-am-ok` — Firebase tooling treats a `demo-` prefix as a
# guaranteed-offline project, so no credentials are used and the SDKs will not
# reach production for it even if something is misconfigured.
#
# ## Why this script exists rather than a bare `firebase emulators:exec`
#
# The Firestore emulator needs a JDK, and `java` is NOT on PATH on this machine
# (docs/infrastructure/deploy-notes.md). It lives in the Android Studio JBR. A
# bare emulator start therefore fails with a message about Java that reads like a
# missing install rather than a missing PATH entry.
#
# ## Reading the result
#
# `emulators:exec` exits with the wrapped command's exit code, so THIS script's
# exit code is real — unlike the Firebase CLI commands that talk to the live
# project, which on Windows print `√ success` and then crash with a libuv
# assertion. That trap is about the network-facing commands; it does not apply
# here. Read the node test summary anyway.

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

if (-not (Test-Path (Join-Path $repo 'rules-tests\node_modules'))) {
    Write-Host 'Installing rules-test dependencies...' -ForegroundColor Cyan
    npm --prefix (Join-Path $repo 'rules-tests') install
}

Push-Location $repo
try {
    firebase emulators:exec --only firestore --project demo-i-am-ok `
        'npm --prefix rules-tests test'
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
