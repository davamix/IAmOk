<#
.SYNOPSIS
    Asserts the .gitignore secrets guard is intact, in both directions.

.DESCRIPTION
    Checks two things that are equally easy to get wrong:

      1. Every path that must never be committed IS ignored.
      2. android/app/google-services.json is still TRACKABLE and still TRACKED.
         It is committed on purpose — its API key ships inside the APK and
         authorises nothing on its own. A well-meaning "*.json" rule would
         silently break a fresh clone's build while protecting nothing.

    The reasoning behind each entry is in docs/security/secrets-policy.md.

    Why the two halves use different git invocations:

      `git check-ignore` consults the INDEX by default, and reports any TRACKED
      file as "not ignored" no matter what .gitignore says. For half 1 that is a
      feature — a secret that has already been committed reports as not-ignored
      and fails the run loudly. For half 2 it is fatal: google-services.json is
      tracked, so the default form would report "trackable" unconditionally and
      the check would pass green even with `*.json` in .gitignore. Half 2
      therefore uses --no-index, which asks the question actually being asked:
      would the rules match this path?

    None of the half-1 sample paths need to exist; check-ignore matches on the
    path, not on the file.

.EXAMPLE
    pwsh -File tools/check-secrets-ignored.ps1
#>

# git signals "ignored / not ignored" through its exit code, so native command
# failures must not be promoted to terminating errors.
$PSNativeCommandUseErrorActionPreference = $false

$repo = Split-Path -Parent $PSScriptRoot

$mustBeIgnored = @(
    # The private working area
    '.local/notes.md'
    '.local/upload-keystore.jks'
    '.credentials/serviceAccount.json'
    # Signing
    'android/key.properties'
    'android/app/upload-keystore.jks'
    'release.keystore'
    'upload-key.pepk'
    'cert.pem'
    'keystore.p12'
    # Service accounts and OAuth downloads
    'i-am-ok-c74ca-firebase-adminsdk-ab12c-3d4e5f6789.json'
    'functions/service-account.json'
    'client_secret_744276314021-abc.apps.googleusercontent.com.json'
    'credentials.json'
    # Functions runtime config — where `functions:config:get` output lands
    'functions/.runtimeconfig.json'
    '.runtimeconfig.json'
    # Emulator exports can contain real check-in history
    'firebase-export-1755000000000/firestore_export/x'
    'emulator-data/firestore_export/x'
    # Environment
    '.env'
    '.env.local'
)

# Committed on purpose. See docs/security/secrets-policy.md §2.
$mustBeTrackable = @(
    'android/app/google-services.json'
)

$failures = @()

function Invoke-CheckIgnore {
    param([string] $Path, [switch] $NoIndex)

    if ($NoIndex) { git -C $repo check-ignore -q --no-index -- $Path }
    else          { git -C $repo check-ignore -q -- $Path }

    switch ($LASTEXITCODE) {
        0       { return $true }
        1       { return $false }
        default { throw "git check-ignore failed with exit $LASTEXITCODE for '$Path'" }
    }
}

foreach ($path in $mustBeIgnored) {
    if (Invoke-CheckIgnore -Path $path) {
        Write-Host ("  ignored    {0}" -f $path)
    } else {
        Write-Host ("  EXPOSED    {0}" -f $path) -ForegroundColor Red
        $failures += "must be ignored but is not: $path"
    }
}

foreach ($path in $mustBeTrackable) {
    # --no-index: this file is tracked, and the index-aware form would answer
    # "not ignored" unconditionally, making the assertion vacuous.
    if (Invoke-CheckIgnore -Path $path -NoIndex) {
        Write-Host ("  BLOCKED    {0}" -f $path) -ForegroundColor Red
        $failures += "must stay trackable but a .gitignore rule now matches it: $path"
    } else {
        Write-Host ("  trackable  {0}" -f $path)
    }

    git -C $repo ls-files --error-unmatch -- $path *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  UNTRACKED  {0}" -f $path) -ForegroundColor Red
        $failures += "must be committed but is not tracked: $path"
    }
}

Write-Host ''

if ($failures.Count -gt 0) {
    Write-Host 'FAIL - the secrets guard is not intact:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Fix .gitignore, then see docs/security/secrets-policy.md.'
    exit 1
}

Write-Host ("OK - {0} paths ignored, {1} deliberately tracked." -f $mustBeIgnored.Count, $mustBeTrackable.Count) -ForegroundColor Green
exit 0
