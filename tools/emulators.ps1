# Starts the Firebase Emulator Suite for local development.
#
#   pwsh -File tools/emulators.ps1                    # auth + firestore + functions
#   pwsh -File tools/emulators.ps1 -Fresh             # ignore any saved state
#   pwsh -File tools/emulators.ps1 -Device 1720f883   # ...and expose it to that handset
#
# **Nothing here touches the live project.** The suite runs under the project id
# `demo-i-am-ok`; Firebase tooling treats a `demo-` prefix as a
# guaranteed-offline project, so no credentials are used and the SDKs refuse to
# reach production for it even when something is misconfigured. That is the same
# guarantee tools/rules-test.ps1 relies on, for the same reason.
#
# ## Why a script rather than a bare `firebase emulators:start`
#
# **Java.** The Firestore emulator needs a JDK and `java` is NOT on PATH on this
# machine (docs/infrastructure/deploy-notes.md). It lives in the Android Studio
# JBR. A bare start fails with a message about Java that reads like a missing
# install rather than a missing PATH entry.
#
# **The Functions emulator serves the COMPILED output**, so a stale `lib/` is a
# stale function — and one that looks like it is running. This builds first
# rather than trusting whoever last ran `tsc`.
#
# **State survives a restart.** `--import` / `--export-on-exit` keep the signed-in
# users, the links and the check-ins between runs. That matters more here than it
# looks: a link is Function-written, so re-creating one by hand every session is
# how people quietly start testing against production instead. The export
# directory is git-ignored — an export of real check-in history in the repo is a
# threat-model problem, see docs/security/secrets-policy.md.
#
# The rules come from `firestore.rules`, the same file that gets deployed, so
# what you develop against is what the project enforces. If those two diverge, a
# client that works locally gets `permission-denied` in production, which
# ADR-0004 maps to **refused**, which drives the access-lost notification. Not
# letting that reach a family is the whole reason this local loop exists.
#
# ## Reaching it from a device
#
# The emulators bind to **127.0.0.1 only**, deliberately: a database with no
# authentication, listening on every interface of a home network, is not
# something to arrange by accident.
#
#   AVD             `10.0.2.2` is the emulator's alias for the host loopback.
#   Real handset    `-Device <serial>` sets up `adb reverse` over the USB cable,
#                   after which the phone's own `127.0.0.1` reaches this machine.
#
# `adb reverse` is the right tool rather than a LAN bind: it needs no open port,
# it dies with the cable, and this project already drives the POCO over USB for
# everything else. It does **not** survive a reconnect — re-run the script, or
# the reverse command it prints, if the device is unplugged.

[CmdletBinding()]
param(
    # Point at a different JDK if Android Studio moves.
    [string]$JavaHome = 'D:\Android\Android Studio\jbr',

    # Start from empty rather than from the last export.
    [switch]$Fresh,

    # A device serial from `adb devices -l`. Sets up `adb reverse` for the three
    # emulator ports so the handset's 127.0.0.1 reaches this machine.
    # Never a bare `adb` call — with the AVD attached, every one is ambiguous.
    [string]$Device,

    [string]$Adb = 'D:\Android\Sdk\platform-tools\adb.exe'
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$data = Join-Path $repo 'emulator-data'

# Keep these in step with firebase.json. They are listed rather than parsed
# because `adb reverse` needs them one at a time anyway, and a mismatch shows up
# immediately as a connection refused rather than as anything subtle.
$ports = @(9099, 8080, 5001)

if (-not (Test-Path (Join-Path $JavaHome 'bin\java.exe'))) {
    Write-Error "No java.exe under '$JavaHome'. Pass -JavaHome with the path to a JDK."
}

$env:JAVA_HOME = $JavaHome
$env:PATH = (Join-Path $JavaHome 'bin') + [IO.Path]::PathSeparator + $env:PATH

Write-Host 'Building functions...' -ForegroundColor Cyan
npm --prefix (Join-Path $repo 'functions') run build
if ($LASTEXITCODE -ne 0) { Write-Error 'functions build failed - not starting with a stale lib/' }

if ($Device) {
    if (-not (Test-Path $Adb)) { Write-Error "No adb at '$Adb'. Pass -Adb." }
    foreach ($port in $ports) {
        & $Adb -s $Device reverse "tcp:$port" "tcp:$port"
        if ($LASTEXITCODE -ne 0) { Write-Error "adb reverse failed for $port on $Device" }
    }
    Write-Host ''
    Write-Host "$Device now reaches this machine on 127.0.0.1 for ports $($ports -join ', ')" -ForegroundColor Yellow
    Write-Host '  flutter run --dart-define=IAMOK_EMULATOR_HOST=127.0.0.1' -ForegroundColor Yellow
    Write-Host '  (re-run this script if the cable is unplugged - adb reverse does not survive it)' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'From the API 36 AVD:' -ForegroundColor DarkGray
Write-Host '  flutter run --dart-define=IAMOK_EMULATOR_HOST=10.0.2.2' -ForegroundColor DarkGray
Write-Host 'Ctrl-C stops the suite and exports its state.' -ForegroundColor DarkGray
Write-Host ''

$emulatorArgs = @(
    'emulators:start'
    '--only', 'auth,firestore,functions'
    '--project', 'demo-i-am-ok'
    '--export-on-exit', $data
)

if (-not $Fresh -and (Test-Path $data)) {
    $emulatorArgs += @('--import', $data)
    Write-Host "Importing saved state from $data" -ForegroundColor DarkGray
} elseif ($Fresh) {
    Write-Host 'Starting empty (-Fresh)' -ForegroundColor DarkGray
}

Push-Location $repo
try {
    firebase @emulatorArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
