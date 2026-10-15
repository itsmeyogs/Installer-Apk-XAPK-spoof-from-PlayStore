[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $InputFile,
    [Parameter(Position = 1)] [string] $Serial
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsRoot = Join-Path $scriptRoot 'tools'
$platformToolsRoot = Join-Path $toolsRoot 'platform-tools'
$platformToolsZip = Join-Path $toolsRoot 'platform-tools-latest-windows.zip'
$buildToolsRoot = Join-Path $toolsRoot 'build-tools'
$vendor = 'com.android.vending'
$downloadUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$tempRoot = $null
$adb = $null
$selectedDeviceName = $null

function Fail([string] $Message) {
    throw $Message
}

function Show-Usage {
    Write-Host 'Usage: install.bat "app.apk|app.xapk" [SERIAL]'
}

function Invoke-Checked([string] $File, [string[]] $Arguments) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $File
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $quotedArguments = foreach ($argument in $Arguments) {
        $value = [string]$argument
        '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    $startInfo.Arguments = $quotedArguments -join ' '
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $code = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($code -ne 0) {
        $text = ($stdout + $stderr).Trim()
        if (-not $text) { $text = "exit code $code" }
        Fail "$File failed: $text"
    }
    return @(($stdout + $stderr) -split "`r?`n" | Where-Object { $_ })
}

function Find-Adb {
    $candidates = @(
        (Join-Path $platformToolsRoot 'adb.exe'),
        (Join-Path $scriptRoot 'adb.exe')
    )
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

function Get-PlatformTools([bool] $ForceDownload = $false) {
    if (-not (Test-Path -LiteralPath $toolsRoot)) { New-Item -ItemType Directory -Path $toolsRoot | Out-Null }
    $candidate = if (-not $ForceDownload) { Find-Adb } else { $null }
    if ($candidate) { return $candidate }
    Write-Host 'Downloading official Android Platform Tools...'
    Invoke-WebRequest -Uri $downloadUrl -OutFile $platformToolsZip -UseBasicParsing
    if (Test-Path -LiteralPath $platformToolsRoot) { Remove-Item -LiteralPath $platformToolsRoot -Recurse -Force }
    Expand-Archive -LiteralPath $platformToolsZip -DestinationPath $toolsRoot -Force
    $candidate = Join-Path $platformToolsRoot 'adb.exe'
    if (-not $candidate) { Fail 'Downloaded Platform Tools did not contain adb.exe.' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { Fail 'Downloaded Platform Tools did not contain adb.exe.' }
    return $candidate
}

function Get-AdbText([string[]] $Arguments) {
    return ((& $adb @Arguments 2>&1) | Out-String).Trim()
}

function Get-DeviceSerial {
    # Reset stale ADB daemon state before reading authorization status.
    try { Invoke-Checked $adb @('kill-server') | Out-Null } catch { }
    Invoke-Checked $adb @('start-server') | Out-Null
    Write-Host "ADB: $adb"
    $version = Invoke-Checked $adb @('version')
    $version | ForEach-Object { if ($_ -match '^Android Debug Bridge') { Write-Host $_ } }
    $lines = Invoke-Checked $adb @('devices', '-l')
    $devices = @()
    foreach ($line in $lines) {
        $text = ([string]$line).Trim()
        if ($text -match '^([^\s]+)\s+(\S+)') {
            $serial = $matches[1]
            $state = $matches[2]
            $model = if ($text -match '\smodel:([^\s]+)') { $matches[1] -replace '_', ' ' } else { $null }
            $product = if ($text -match '\sproduct:([^\s]+)') { $matches[1] -replace '_', ' ' } else { $null }
            $name = if ($model) { $model } elseif ($product) { $product } else { 'Unknown device' }
            $devices += [pscustomobject]@{
                Serial = $serial
                State = $state
                Name = $name
            }
        }
    }
    if ($Serial) {
        $selected = @($devices | Where-Object Serial -eq $Serial)
        if ($selected.Count -eq 0) { Fail "Device '$Serial' not found. Check USB debugging and RSA authorization." }
        if ($selected[0].State -ne 'device') { Fail "Device '$Serial' status is '$($selected[0].State)'. Unlock the device and accept the RSA prompt." }
        $script:selectedDeviceName = $selected[0].Name
        return $Serial
    }
    $ready = @($devices | Where-Object State -eq 'device')
    if ($ready.Count -eq 1) {
        $script:selectedDeviceName = $ready[0].Name
        Write-Host "Detected device: $($ready[0].Name) [$($ready[0].Serial)]"
        return $ready[0].Serial
    }
    if ($ready.Count -gt 1) {
        Write-Host ''
        Write-Host 'Multiple Android devices found:'
        for ($index = 0; $index -lt $ready.Count; $index++) {
            $entry = $ready[$index]
            Write-Host "$($index + 1). $($entry.Name) [$($entry.Serial)]"
        }
        do {
            $choice = Read-Host "Select device [1-$($ready.Count)]"
            $selectedIndex = 0
            $validChoice = [int]::TryParse($choice, [ref]$selectedIndex) -and
                $selectedIndex -ge 1 -and $selectedIndex -le $ready.Count
            if (-not $validChoice) { Write-Host 'Invalid selection.' }
        } while (-not $validChoice)
        $script:selectedDeviceName = $ready[$selectedIndex - 1].Name
        return $ready[$selectedIndex - 1].Serial
    }
    $bad = @($devices | Where-Object State -ne 'device')
    if ($bad.Count -gt 0) { Fail 'Device is unauthorized or offline. Enable USB debugging, unlock it, and accept the RSA prompt.' }
    Fail 'No authorized Android device found. Enable USB debugging and connect a device.'
}

function Get-PackageFromAapt([string] $Apk) {
    $parsers = @()
    $sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
    foreach ($root in $sdkRoots) {
        if ($root) {
            $parsers += Get-ChildItem -LiteralPath (Join-Path $root 'build-tools') -Filter aapt*.exe -Recurse -ErrorAction SilentlyContinue
        }
    }
    $parsers += Get-ChildItem -LiteralPath $buildToolsRoot -Filter aapt*.exe -Recurse -ErrorAction SilentlyContinue
    $parsers += Get-Command aapt.exe -ErrorAction SilentlyContinue
    $parsers += Get-Command aapt2.exe -ErrorAction SilentlyContinue
    foreach ($parser in ($parsers | Where-Object { $_ } | Sort-Object FullName -Descending -Unique)) {
        $path = if ($parser.Path) { $parser.Path } else { $parser.Source }
        $dump = & $path dump badging $Apk 2>$null | Out-String
        if ($dump -match "package: name='([^']+)'") { return $matches[1] }
    }
    return $null
}

function Get-ManifestPackage([string] $ManifestPath) {
    $json = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($json.package_name -is [string] -and $json.package_name -match '^[A-Za-z][A-Za-z0-9_.]+$') { return $json.package_name }
    return $null
}

function Expand-SafeZip([string] $Zip, [string] $Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Fail 'XAPK contains an unsafe ZIP path.' }
            if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            $parent = Split-Path -Parent $target
            if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $archive.Dispose() }
}

function Invoke-PmInstall([string[]] $Apks, [string] $Device, [string] $Name) {
    $remoteApks = @()
    $sessionId = $null
    $sessionCommitted = $false
    try {
        foreach ($apk in $Apks) {
            $remote = "/data/local/tmp/$Name-$([guid]::NewGuid().ToString('N')).apk"
            Write-Host "Pushing $([IO.Path]::GetFileName($apk))"
            Invoke-Checked $adb @('-s', $Device, 'push', $apk, $remote) | ForEach-Object { Write-Host $_ }
            $remoteApks += $remote
        }
        if ($remoteApks.Count -eq 1) {
            Write-Host 'Installing through device package manager...'
            Invoke-Checked $adb (@('-s', $Device, 'shell', 'pm', 'install', '-i', $vendor, '-r') + $remoteApks) | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host 'Creating package install session...'
            $createOutput = Invoke-Checked $adb @('-s', $Device, 'shell', 'pm', 'install-create', '-i', $vendor, '-r')
            $createText = ($createOutput | Out-String)
            if ($createText -notmatch 'Success:\s+created install session\s+\[?(\d+)\]?') { Fail "Could not create install session: $createText" }
            $sessionId = $matches[1]
            for ($index = 0; $index -lt $remoteApks.Count; $index++) {
                Write-Host "Writing split $($index + 1)/$($remoteApks.Count)..."
                Invoke-Checked $adb @('-s', $Device, 'shell', 'pm', 'install-write', '-S', (Get-Item -LiteralPath $Apks[$index]).Length, $sessionId, $index, $remoteApks[$index]) | ForEach-Object { Write-Host $_ }
            }
            Write-Host 'Committing package install session...'
            Invoke-Checked $adb @('-s', $Device, 'shell', 'pm', 'install-commit', $sessionId) | ForEach-Object { Write-Host $_ }
            $sessionCommitted = $true
        }
    } finally {
        if ($sessionId -and -not $sessionCommitted) { & $adb '-s' $Device 'shell' 'pm' 'install-abandon' $sessionId 2>$null | Out-Null }
        foreach ($remote in $remoteApks) {
            & $adb '-s' $Device 'shell' 'rm' '-f' $remote 2>$null | Out-Null
        }
    }
}

try {
    if (-not $InputFile -or -not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
        if ($InputFile) { Write-Error "File not found: $InputFile" }; Show-Usage; exit 2
    }
    if (@($InputFile, $Serial).Count -gt 2) { Show-Usage; exit 2 }
    $extension = [IO.Path]::GetExtension($InputFile).ToLowerInvariant()
    if ($extension -notin @('.apk', '.xapk')) { Fail 'Only .apk and .xapk files are accepted.' }
    $adb = Get-PlatformTools
    try {
        $device = Get-DeviceSerial
    } catch {
        if ($_.Exception.Message -notmatch 'server version|daemon version|doesn.t match') { throw }
        Write-Host 'Restarting the ADB server with the selected legacy Platform Tools.'
        $adb = Get-PlatformTools
        $device = Get-DeviceSerial
    }
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('xapk-installer-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $groups = @{}
    $obbFiles = @()
    if ($extension -eq '.apk') {
        $package = Get-PackageFromAapt $InputFile
        $groups['single'] = @([IO.Path]::GetFullPath($InputFile))
        if ($package) { $groups.Clear(); $groups[$package] = @([IO.Path]::GetFullPath($InputFile)) }
    } else {
        Expand-SafeZip $InputFile $tempRoot
        $manifest = Get-ChildItem -LiteralPath $tempRoot -Filter manifest.json -Recurse -File | Select-Object -First 1
        $manifestPackage = if ($manifest) { Get-ManifestPackage $manifest.FullName } else { $null }
        $apkFiles = @(Get-ChildItem -LiteralPath $tempRoot -Filter *.apk -Recurse -File)
        $obbFiles = @(Get-ChildItem -LiteralPath $tempRoot -Filter *.obb -Recurse -File)
        if ($apkFiles.Count -eq 0) { Fail 'XAPK contains no APK files.' }
        foreach ($apk in $apkFiles) {
            $package = Get-PackageFromAapt $apk.FullName
            if (-not $package) { $package = $manifestPackage }
            if (-not $package) { Fail "Cannot determine package ID for APK '$($apk.Name)'. Install aapt/aapt2 or provide manifest.json package_name." }
            if (-not $groups.ContainsKey($package)) { $groups[$package] = @() }
            $groups[$package] += $apk.FullName
        }
    }
    Write-Host ''
    Write-Host 'Installation target:'
    Write-Host "  Device: $selectedDeviceName"
    Write-Host "  Serial: $device"
    Write-Host "  ADB:    $adb"
    Write-Host ''
    foreach ($package in $groups.Keys) {
        Invoke-PmInstall @($groups[$package]) $device ($package -replace '[^A-Za-z0-9_.-]', '_')
    }
    foreach ($obb in $obbFiles) {
        $package = if ($groups.Count -eq 1) { @($groups.Keys)[0] } else { $null }
        if (-not $package) { Fail "Cannot assign OBB '$($obb.Name)' to a package in a multi-package XAPK." }
        $remote = "/sdcard/Android/obb/$package/"
        Invoke-Checked $adb @('-s', $device, 'shell', 'mkdir', '-p', $remote) | Out-Null
        Write-Host "Pushing $($obb.Name) to $remote"
        Invoke-Checked $adb @('-s', $device, 'push', $obb.FullName, $remote) | ForEach-Object { Write-Host $_ }
    }
    Write-Host 'Installation completed successfully.'
    exit 0
} catch {
    Write-Error ("$($_.Exception.GetType().FullName): $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)")
    exit 1
} finally {
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
