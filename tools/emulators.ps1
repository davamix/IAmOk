# Starts the Firebase Emulator Suite for local development.
#
#   pwsh -File tools/emulators.ps1                    # auth + firestore + functions
#   pwsh -File tools/emulators.ps1 -Fresh             # ignore any saved state
#   pwsh -File tools/emulators.ps1 -Device 1720f883   # ...and expose it to that handset
#
# **Nothing here touches the live project.** Emulators are local processes; the
# `--project` flag below names a *namespace*, not a destination.
#
# ## Why that flag is `i-am-ok-c74ca` and not `demo-i-am-ok` — measured 2026-08-21
#
# It was `demo-i-am-ok` first, on the reasoning that Firebase treats a `demo-`
# prefix as guaranteed-offline. **That reasoning did not apply to the app**, and
# assuming it did produced a false green.
#
# The app takes its project id from `android/app/google-services.json` — it has
# to, that is how `Firebase.initializeApp()` finds anything — so it writes into
# the emulator under **`i-am-ok-c74ca`** whatever this flag says. The Firestore
# emulator serves every project id it is asked for, in separate namespaces, and
# **loads `firestore.rules` into only the one it was started with.**
#
# So with `demo-i-am-ok` here, the app's reads and writes were being judged by
# the emulator's permissive default rules. Proved rather than suspected: opening
# `invites/` in `firestore.rules` and re-probing changed the answer under
# `demo-i-am-ok` and changed nothing under `i-am-ok-c74ca`. Every device run in
# that configuration would have confirmed the write path and told us nothing
# about authorisation — while looking exactly like a pass.
#
# What actually keeps the app off production is not this flag. It is
# `FirebaseBootstrap` calling `useAuthEmulator` and `useFirestoreEmulator`, which
# only happens when `IAMOK_EMULATOR_HOST` was set at compile time, plus the
# debug-only cleartext grant without which those calls cannot connect at all.
# `tools/rules-test.ps1` still uses `demo-i-am-ok`, and there it is a real
# guarantee: that suite supplies its own project id to
# `initializeTestEnvironment`, so the rules and the namespace cannot disagree.
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
# **State survives a CLEAN EXIT.** `--import` / `--export-on-exit` keep the
# signed-in users, the links and the check-ins between runs. That matters more
# here than it looks: a link is Function-written, so re-creating one by hand every
# session is how people quietly start testing against production instead. The
# export directory is git-ignored — an export of real check-in history in the repo
# is a threat-model problem, see docs/security/secrets-policy.md.
#
# **`--export-on-exit` runs ONLY on a clean Ctrl-C.** A kill, a crash, or a
# `Stop-Process` discards everything since the last export **with no message at
# all** — and the next run then prints "Importing saved state" over a stale
# directory and looks entirely successful. That happened at the end of Phase 5:
# the suite was killed, so the pairing created that day is not in `emulator-data/`
# while the AVD's local store still references those uids. The import line below
# now prints the export's DATE for exactly this reason; if it is older than the
# device you are about to test with, re-pair rather than trying to reconcile them.
#
# Note the tension with `docs/phases/phase-5-brief.md`, which says to start the
# suite **detached with output redirected** to avoid an EPIPE hang. Detached is
# what makes Ctrl-C unavailable. If you start it detached, accept that the export
# will not run, or stop it with a real Ctrl-C into its own console.
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
    Write-Host '  flutter run --dart-define=IAMOK_EMULATOR_HOST=127.0.0.1 `' -ForegroundColor Yellow
    Write-Host '              --dart-define=IAMOK_EMULATOR_USER=emulator-ana `' -ForegroundColor Yellow
    Write-Host '              --dart-define=IAMOK_EMULATOR_NAME=Ana' -ForegroundColor Yellow
    Write-Host '  (re-run this script if the cable is unplugged - adb reverse does not survive it)' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'From the API 36 AVD:' -ForegroundColor DarkGray
Write-Host '  flutter run --dart-define=IAMOK_EMULATOR_HOST=10.0.2.2 `' -ForegroundColor DarkGray
Write-Host '              --dart-define=IAMOK_EMULATOR_USER=emulator-mum `' -ForegroundColor DarkGray
Write-Host '              --dart-define=IAMOK_EMULATOR_NAME=Mum' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'TWO DEVICES NEED TWO SUBJECTS. Without IAMOK_EMULATOR_USER both sign in as' -ForegroundColor Yellow
Write-Host 'the same person, and redeemInvite correctly refuses the self-link — which was' -ForegroundColor Yellow
Write-Host "a blocker for Phase 5's exit criterion until it was parameterised." -ForegroundColor Yellow
Write-Host 'Ctrl-C stops the suite and exports its state.' -ForegroundColor DarkGray
Write-Host ''

$emulatorArgs = @(
    'emulators:start'
    '--only', 'auth,firestore,functions'
    # The namespace the app itself uses. See the note at the top of this file:
    # anything else and the rules load somewhere the app never looks.
    '--project', 'i-am-ok-c74ca'
    '--export-on-exit', $data
)

if (-not $Fresh -and (Test-Path $data)) {
    $emulatorArgs += @('--import', $data)
    # The DATE, not just the path. A stale import looks identical to a fresh one
    # otherwise, and a kill produces no export at all — see the header.
    $exported = (Get-Item (Join-Path $data 'firebase-export-metadata.json') -ErrorAction SilentlyContinue).LastWriteTime
    Write-Host ("Importing saved state from $data" +
        $(if ($exported) { " (exported $exported)" } else { ' (no metadata — date unknown)' })) -ForegroundColor DarkGray
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
