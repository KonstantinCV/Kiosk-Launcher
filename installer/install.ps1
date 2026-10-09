# Kiosk Loader installer for Meta Quest headsets, for Windows.
#
# Does what install.sh does on macOS and Linux: installs the loader on a headset connected over
# USB, makes it start the chosen app on boot and bring it back whenever it closes or crashes, and
# sets the headset up for use without controllers. Run install.bat, or from PowerShell:
#
#   .\install.ps1
#   .\install.ps1 -Target com.example.app -Grace 3 -Serial 2G97C5ZJ0H00YS
#
#   -Target PKG     the app to keep running (must already be installed on the headset)
#   -Grace SECONDS  how long the app may be gone before it is started again, 0 to 60
#   -Serial SERIAL  which headset, when more than one is connected (see: adb devices)
param(
    [string]$Target = "",
    [int]$Grace = -1,
    [string]$Serial = ""
)
# Continue, not Stop: adb writes progress to stderr, which Windows PowerShell would turn into
# terminating errors. Failures are checked by hand instead.
$ErrorActionPreference = "Continue"

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Apk = Join-Path $Dir "kiosk-loader.apk"
$Loader = "com.osamaalek.kiosklauncher"
$Receiver = "$Loader/.receiver.AdminCommandReceiver"
$Action = "$Loader.action"

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "Error: $Message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $Apk)) { Fail "kiosk-loader.apk is missing: keep install.ps1 in the folder it came in" }
if ($Grace -gt 60 -or $Grace -lt -1) { Fail "-Grace takes 0 to 60 seconds, got $Grace" }

# --- adb ---------------------------------------------------------------------------------------

$AdbExe = $null
$found = Get-Command adb -ErrorAction SilentlyContinue
$candidates = @(
    $(if ($found) { $found.Source }),
    (Join-Path $Dir "platform-tools\adb.exe"),
    $(if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME "platform-tools\adb.exe" }),
    $(if ($env:ANDROID_SDK_ROOT) { Join-Path $env:ANDROID_SDK_ROOT "platform-tools\adb.exe" }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe" })
)
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { $AdbExe = $c; break }
}
if (-not $AdbExe) {
    Fail ("adb not found. Download Android platform tools from " +
        "https://developer.android.com/tools/releases/platform-tools, unzip it and put the " +
        "platform-tools folder next to install.ps1")
}

# Runs adb on the chosen headset; returns its output lines with no carriage returns
function Adb([string[]]$AdbArgs) {
    $all = @()
    if ($script:Serial) { $all += @("-s", $script:Serial) }
    $all += $AdbArgs
    $out = & $AdbExe @all 2>&1
    return @($out | ForEach-Object { "$_".TrimEnd("`r") })
}

# --- headset -----------------------------------------------------------------------------------

Write-Host "Looking for the headset..."
$devices = @(& $AdbExe devices | Select-Object -Skip 1 | Where-Object { $_ -match "\S+\s+\S+" } |
    ForEach-Object { $p = $_ -split "\s+"; [pscustomobject]@{ Serial = $p[0]; State = $p[1] } })
if (-not $Serial) {
    if ($devices.Count -eq 0) {
        Fail ("no headset found. Connect it with a USB cable, turn on developer mode in the Meta " +
            "Horizon phone app, put the headset on and allow USB debugging")
    } elseif ($devices.Count -gt 1) {
        Write-Host "More than one device is connected:"
        $devices | ForEach-Object { Write-Host "  $($_.Serial)  $($_.State)" }
        $Serial = Read-Host "Serial of the headset to set up"
    } else {
        $Serial = $devices[0].Serial
    }
}
$device = $devices | Where-Object { $_.Serial -eq $Serial }
if (-not $device) { Fail "no device with serial $Serial (see: adb devices)" }
switch ($device.State) {
    "device" { }
    "unauthorized" {
        Fail ("the headset hasn't allowed this computer yet. Put it on, tick 'Always allow from " +
            "this computer' in the USB debugging prompt (or find it under notifications) and " +
            "allow, then run this again")
    }
    default { Fail "the headset is '$($device.State)'. Reconnect the cable and run this again" }
}
$model = (Adb @("shell", "getprop", "ro.product.model")) -join ""
$os = (Adb @("shell", "getprop", "ro.build.display.id")) -join ""
Write-Host "Headset: $model ($os), serial $Serial"

# --- app to keep running -----------------------------------------------------------------------

$skip = @($Loader, "$Loader.testapp", "$Loader.testapp.vr")
if (-not $Target) {
    $apps = @(Adb @("shell", "pm", "list", "packages", "-3") | ForEach-Object { $_ -replace "^package:", "" } |
        Where-Object { $_ -and ($skip -notcontains $_) } | Sort-Object)
    if ($apps.Count -eq 0) { Fail "no apps installed on the headset besides the loader. Install the app first" }
    Write-Host ""
    Write-Host "Apps installed on the headset:"
    for ($i = 0; $i -lt $apps.Count; $i++) { Write-Host ("  {0,2}. {1}" -f ($i + 1), $apps[$i]) }
    $choice = Read-Host "Number of the app to keep running"
    $n = 0
    if (-not [int]::TryParse($choice, [ref]$n) -or $n -lt 1 -or $n -gt $apps.Count) { Fail "no app number '$choice'" }
    $Target = $apps[$n - 1]
}
if (-not ((Adb @("shell", "pm", "list", "packages", $Target)) -contains "package:$Target")) {
    Fail "$Target is not installed on the headset. Install it first (adb install -g <app>.apk grants its permissions up front)"
}
Write-Host "App to keep running: $Target"

# --- install and set up (what provision-quest.sh does) -----------------------------------------

Write-Host ""
Write-Host "Installing the loader..."
$install = (Adb @("install", "-r", "-g", $Apk)) -join "`n"
if ($install -notmatch "Success") {
    # An older loader signed with another key can't be updated in place
    Write-Host "Replacing the loader already on the headset (its settings are reset)..."
    Adb @("uninstall", $Loader) | Out-Null
    $install = (Adb @("install", "-r", "-g", $Apk)) -join "`n"
    if ($install -notmatch "Success") { Fail "installing the loader failed: $install" }
}

Write-Host "Granting background launch and usage access..."
Adb @("shell", "appops", "set", $Loader, "SYSTEM_ALERT_WINDOW", "allow") | Out-Null
Adb @("shell", "appops", "set", $Loader, "GET_USAGE_STATS", "allow") | Out-Null
# Android saves app-op changes ~10 s later: a reboot or power cut before that would lose them
Adb @("shell", "appops", "write-settings") | Out-Null
Adb @("shell", "dumpsys", "deviceidle", "whitelist", "+$Loader") | Out-Null

# Crash and not-responding dialogs wait for a tap nobody can give without a controller
Write-Host "Hiding crash and not-responding dialogs..."
Adb @("shell", "settings", "put", "global", "hide_error_dialogs", "1") | Out-Null

# Without a PIN or password Android still shows a lock screen after a restart, waiting for a tap
Write-Host "Turning the lock screen off..."
Adb @("shell", "locksettings", "set-disabled", "true") | Out-Null

Write-Host "Setting the app to keep running..."
$set = (Adb @("shell", "am", "broadcast", "-n", $Receiver, "-a", "$Action.SET_TARGET", "--es", "package", $Target)) -join " "
if ($set -notmatch 'data="OK"') { Fail "the loader did not accept $Target as its app: $set" }
if ($Grace -ge 0) {
    Write-Host "Setting the relaunch delay to $Grace s..."
    $g = (Adb @("shell", "am", "broadcast", "-n", $Receiver, "-a", "$Action.SET_GRACE", "--ei", "seconds", "$Grace")) -join " "
    if ($g -notmatch 'data="OK"') { Write-Host "Warning: could not set the relaunch delay; set it on the loader's screen" -ForegroundColor Yellow }
}

# Opening the loader once lets it receive BOOT_COMPLETED from now on, and starts the watchdog
Write-Host "Starting the loader..."
Adb @("shell", "am", "start", "-n", "$Loader/.ui.MainActivity") | Out-Null
# Android saves the battery-saving exemption ~5 s after it is set
Write-Host "Waiting for the headset to save the settings..."
Start-Sleep -Seconds 6

# --- check -------------------------------------------------------------------------------------

Write-Host ""
Write-Host "Checking..."
$ok = $true
function Check([string]$What, [bool]$Passed, [string]$Got) {
    if ($Passed) { Write-Host "  ok    $What" }
    else { Write-Host "  FAIL  $What (got: $Got)" -ForegroundColor Red; $script:ok = $false }
}
$appops = (Adb @("shell", "appops", "get", $Loader)) -join "`n"
Check "start apps from the background" ($appops -match "SYSTEM_ALERT_WINDOW: allow") $appops
Check "see which app is in front" ($appops -match "GET_USAGE_STATS: allow") $appops
$idle = (Adb @("shell", "dumpsys", "deviceidle", "whitelist")) -join "`n"
Check "not stopped by battery saving" ($idle -match [regex]::Escape(",$Loader,")) "not listed"
$dialogs = (Adb @("shell", "settings", "get", "global", "hide_error_dialogs")) -join ""
Check "no crash dialogs" ($dialogs -eq "1") $dialogs
$lock = (Adb @("shell", "locksettings", "get-disabled")) -join ""
Check "no lock screen" ($lock -eq "true") "$lock (remove the headset's PIN, pattern or password)"
$services = (Adb @("shell", "dumpsys", "activity", "services", $Loader)) -join "`n"
Check "watchdog running" ($services -match "WatchdogService") "not running"

Write-Host @"

On the headset, once:
  - Settings: turn the boundary (Guardian) off, so the app isn't held up after the headset wakes
  - Settings: hand tracking off and controllers away, if users get it that way
  - The first time it asks, tick "Always allow from this computer" for USB debugging

Test it: restart the headset (hold the power button until it turns off, then turn it on).
$Target should start by itself, and come back within a few seconds whenever it closes.
"@
if (-not $ok) {
    Write-Host ""
    Write-Host "Some checks failed (above). Run the installer again; if they still fail, keep this output."
    exit 1
}
