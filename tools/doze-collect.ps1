# Collects the evidence for the overnight Doze run.
#
# Run it in the morning, after plugging the phone back in:
#
#   pwsh -File tools/doze-collect.ps1
#
# It only reads. Nothing here writes to the device, changes app state, or
# touches the live Firebase project.
#
# ## What it is looking for
#
# A warning alarm was armed for 05:00 with `warnings_shown` deliberately not
# containing the day that alarm asks about, so a warning is genuinely owed. Three
# independent channels say whether the alarm isolate ran:
#
#   1. `warnings_shown` gains a row for the day the alarm decided about
#   2. `last_reconcile_at` advances past the baseline stamped at setup
#   3. two notifications are in the tray, posted around 05:00
#
# Three rather than one because they fail differently: the ledger is only written
# when something was *delivered*, `last_reconcile_at` is only stamped when the
# read *succeeded*, and the tray can be cleared by the reader or by the OEM. A
# result that moves all three is unambiguous; one that moves some is the
# interesting case and is why they are printed separately rather than reduced to
# a pass/fail.

$ErrorActionPreference = 'Continue'
$adb = 'D:\Android\Sdk\platform-tools\adb.exe'
$pkg = 'io.github.davamix.i_am_ok'
$out = Join-Path $env:TEMP 'doze'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# The baseline written at setup, so "advanced" is measured rather than eyeballed.
$baselineReconcileAt = '2026-08-19 23:11:50'
$armedFor            = '2026-08-20 05:00:00'

Write-Host "=== device ===" -ForegroundColor Cyan
& $adb devices -l | Select-Object -Skip 1
"device time : " + (& $adb shell "date '+%Y-%m-%d %H:%M:%S %Z'")
"armed for   : $armedFor Madrid"
"baseline    : last_reconcile_at $baselineReconcileAt"

Write-Host "`n=== 1. did the device actually spend the night in Doze? ===" -ForegroundColor Cyan
# Without this the whole run proves nothing: an alarm firing on a phone that
# never idled is not evidence about Doze. `deviceidle` keeps a step history.
& $adb shell "dumpsys deviceidle > /sdcard/dozestate.txt" | Out-Null
& $adb pull /sdcard/dozestate.txt "$out\dozestate.txt" | Out-Null
$dz = Get-Content "$out\dozestate.txt"
"current deep state : " + (& $adb shell dumpsys deviceidle get deep)
"current light state: " + (& $adb shell dumpsys deviceidle get light)
$dz | Select-String -Pattern "Idling history|IDLE|STEP|state=" | Select-Object -First 25 |
  ForEach-Object { "  " + $_.Line.Trim() }

Write-Host "`n=== 2. the store — the app's own record, written at fire time ===" -ForegroundColor Cyan
& $adb exec-out run-as $pkg cat databases/i_am_ok.db > "$out\store.db"
$py = @"
import sqlite3, datetime, sys
c = sqlite3.connect(r'$out\store.db')
def mad(ms):
    if not ms: return None
    return (datetime.datetime.fromtimestamp(ms/1000, datetime.timezone.utc)
            + datetime.timedelta(hours=2)).strftime('%Y-%m-%d %H:%M:%S')
print('warnings_shown:')
rows = list(c.execute('SELECT link_id, day, outcome FROM warnings_shown ORDER BY day'))
for r in rows: print('   ', r)
if not rows: print('    (empty)')
print()
print('watcher_cache:')
for lid, lr, lc in c.execute('SELECT link_id, last_reconcile_at, last_confirmed_day FROM watcher_cache'):
    print(f'    {lid:32} last_reconcile_at={mad(lr)} last_confirmed_day={lc}')
print()
days = {d for _, d, _ in rows}
print('VERDICT (ledger): 2026-08-19 recorded?', '2026-08-19' in days,
      '-> the isolate ran AND delivered' if '2026-08-19' in days else '-> nothing was delivered for that day')
"@
$py | Out-File -FilePath "$out\q.py" -Encoding utf8
python "$out\q.py"

Write-Host "`n=== 3. the tray ===" -ForegroundColor Cyan
& $adb shell "dumpsys notification --noredact > /sdcard/dozenotif.txt" | Out-Null
& $adb pull /sdcard/dozenotif.txt "$out\notif.txt" | Out-Null
$hits = Get-Content "$out\notif.txt" | Select-String -Pattern "android.text=String \((No check-in|Can't check)"
if ($hits) { $hits | ForEach-Object { "  " + $_.Line.Trim() } } else { "  (none of ours)" }

Write-Host "`n=== 4. the platform's alarm record ===" -ForegroundColor Cyan
# Pending alarms are the `RTC_WAKEUP #n: Alarm{... <pkg>}` lines, whose FOLLOWING
# line carries the receiver tag. Grepping the receiver name alone matches the
# App Alarm history section instead and reports armed alarms on an app that has
# none — that mistake was made once already, on 2026-08-19.
& $adb shell "dumpsys alarm > /sdcard/dozealarm.txt" | Out-Null
& $adb pull /sdcard/dozealarm.txt "$out\alarm.txt" | Out-Null
$py2 = @"
import re, datetime
lines = open(r'$out\alarm.txt', encoding='utf-8', errors='replace').read().splitlines()
pkg = 'io.github.davamix.i_am_ok'
warn, rem = [], []
for i, l in enumerate(lines):
    if re.search(r'Alarm\{.*' + re.escape(pkg), l) and i + 1 < len(lines):
        m = re.search(r'origWhen (\d+)', l)
        if not m: continue
        t = (datetime.datetime.fromtimestamp(int(m.group(1))/1000, datetime.timezone.utc)
             + datetime.timedelta(hours=2)).strftime('%Y-%m-%d %H:%M')
        if 'AlarmBroadcastReceiver' in lines[i+1]: warn.append(t)
        elif 'ScheduledNotificationReceiver' in lines[i+1]: rem.append(t)
print(f'pending: warnings={len(warn)} reminders={len(rem)}')
print('soonest warnings:', sorted(warn)[:3])
print()
print('If the 05:00 alarm is GONE from pending, it was delivered.')
print('If it is still there and overdue, Doze deferred it.')
"@
$py2 | Out-File -FilePath "$out\q2.py" -Encoding utf8
python "$out\q2.py"

Write-Host "`n=== 5. logcat: was the broadcast delivered, and did Dart run? ===" -ForegroundColor Cyan
# The decisive line. On 2026-08-19 under FORCED Doze the broadcast was delivered
# and the app was returned to idle 3s later with no Dart having run, so these two
# questions have to be asked separately.
& $adb logcat -d -v time > "$out\logcat.txt" 2>&1
$lc = Get-Content "$out\logcat.txt"
"AlarmManager deliveries to us:"
$lc | Select-String -Pattern "AlarmManager.*davamix|davamix.*alarm start" | ForEach-Object { "  " + $_.Line } | Select-Object -Last 10
"flutter / Dart activity:"
$f = $lc | Select-String -Pattern "flutter|Dart|i_am_ok.*(Exception|Error)"
if ($f) { $f | ForEach-Object { "  " + $_.Line } | Select-Object -Last 10 } else { "  (nothing — the engine did not log)" }

Write-Host "`nRaw captures in $out" -ForegroundColor DarkGray
