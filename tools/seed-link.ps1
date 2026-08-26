# Seeds a link into the FIRESTORE EMULATOR, bypassing the security rules.
#
#   pwsh -File tools/seed-link.ps1 -WatchedUid <uid> -WatcherUid <uid>
#
# **This exists because links are Function-written and the client cannot make
# one** (§8, §9). Creation goes through the `redeemInvite` callable so single-use
# and expiry are enforced server-side, and `firestore.rules` denies
# `create` on `links/{id}` outright — a rules test asserts that, including for
# the watched person themselves.
#
# `redeemInvite` shipped in Phase 5, so this is no longer the only way to make a
# link — but it is still the only way to make the device rig's deliberate
# SELF-LINK, which `redeemInviteFor` refuses by name (a link to yourself would
# warn you about your own missed day and name you as your own watcher).
# `functions/src/invites.ts` points back at this script for that reason. Keep it.
#
# It also remains the way to seed a link when a test needs one to exist. So this writes one the way the
# Function will: the same fields, the same deterministic id, `activeFrom` as
# today in the WATCHED person's zone.
#
# ## Why a script against the emulator's REST API, rather than a harness control
#
# A harness control would be a client, and a client is exactly what the rules
# refuse. Adding an exception for it would put a hole in the one authorisation
# boundary this app has, to save writing this file — and the hole would still be
# there in Phase 5, when the Function makes it unnecessary.
#
# The emulator's REST API accepts `Authorization: Bearer owner`, which bypasses
# rules the way the Admin SDK does in production. That is a property of the
# EMULATOR only: the same call against the live project is rejected. So this can
# only ever affect local data, which is the guarantee that makes it safe to keep
# in the repo.
#
# ## What it does NOT do
#
# It writes no `users/{uid}` documents. Sign in on each device first — the
# harness's *Sign in* control writes the user doc — because `watchedName` and
# `watcherName` below should be the names those accounts actually carry, and
# inventing them here would hide a mismatch that Phase 5 will care about.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WatchedUid,
    [Parameter(Mandatory)][string]$WatcherUid,

    [string]$WatchedName = 'Mum',
    [string]$WatcherName = 'Ana',

    # The watched person's zone, denormalised onto the link (§7). This is what a
    # watcher's alarm isolate computes `D` from, with no plugin access at all.
    [string]$WatchedTimezone = 'Europe/Madrid',

    # Watcher-local, per link (§10). The default the app itself uses.
    [string]$WarningLocalTime = '10:00',

    [string]$EmulatorHost = '127.0.0.1',
    [int]$FirestorePort = 8080,
    # The namespace the APP writes into, which comes from
    # `android/app/google-services.json` and not from how the emulator was
    # started. Seeding into any other one produces a link the app cannot see.
    [string]$ProjectId = 'i-am-ok-c74ca'
)

$ErrorActionPreference = 'Stop'

$linkId = "${WatchedUid}_${WatcherUid}"

# Today, as the date component of the local clock. `activeFrom` is a day label in
# the watched person's zone (§7) and this machine is in that zone for the current
# device work; if that ever stops being true, pass the date rather than guessing.
$activeFrom = (Get-Date).ToString('yyyy-MM-dd')
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# Firestore's REST shape: every field is tagged with its type.
$document = @{
    fields = @{
        watchedUid       = @{ stringValue = $WatchedUid }
        watcherUid       = @{ stringValue = $WatcherUid }
        status           = @{ stringValue = 'accepted' }
        watchedName      = @{ stringValue = $WatchedName }
        watcherName      = @{ stringValue = $WatcherName }
        watchedTimezone  = @{ stringValue = $WatchedTimezone }
        activeFrom       = @{ stringValue = $activeFrom }
        warningLocalTime = @{ stringValue = $WarningLocalTime }
        createdAt        = @{ timestampValue = $now }
        acceptedAt       = @{ timestampValue = $now }
    }
} | ConvertTo-Json -Depth 10

$uri = "http://${EmulatorHost}:${FirestorePort}/v1/projects/$ProjectId/databases/(default)/documents/links?documentId=$linkId"

Write-Host "Seeding links/$linkId into the EMULATOR at ${EmulatorHost}:${FirestorePort}" -ForegroundColor Cyan

try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $document `
        -ContentType 'application/json' `
        -Headers @{ Authorization = 'Bearer owner' }
}
catch {
    # A 409 means the link is already there, which is not a failure: the id is
    # deterministic precisely so that redeeming the same invite twice is
    # idempotent (§7). Say so rather than printing a stack trace.
    if ($_.Exception.Response.StatusCode.value__ -eq 409) {
        Write-Host "links/$linkId already exists — nothing to do." -ForegroundColor Yellow
        exit 0
    }
    throw
}

Write-Host ''
Write-Host "  watched   $WatchedUid ($WatchedName, $WatchedTimezone)" -ForegroundColor Green
Write-Host "  watcher   $WatcherUid ($WatcherName, warns at $WarningLocalTime local)" -ForegroundColor Green
Write-Host "  active    from $activeFrom" -ForegroundColor Green
Write-Host ''
Write-Host 'Read it back to confirm, rather than trusting this message:' -ForegroundColor DarkGray
Write-Host "  curl -H 'Authorization: Bearer owner' http://${EmulatorHost}:${FirestorePort}/v1/projects/$ProjectId/databases/(default)/documents/links/$linkId" -ForegroundColor DarkGray

$response.name
