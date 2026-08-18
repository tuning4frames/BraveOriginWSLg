<#
.SYNOPSIS
    Brave Origin for Windows - Native WSLg setup GUI.

    Checks requirements (WSL2, WSLg, WebView2, disk, internet), installs WSL/WSLg
    only if missing (needs admin + reboot), imports the Ubuntu rootfs, copies the
    app scripts into the distro, runs setup.sh, then launches Brave.exe.

    Progress bar + live log. If WSL/WSLg must be installed it elevates (UAC) and
    asks for a reboot; otherwise it runs fully un-elevated.
#>

param([switch]$Headless)

$ErrorActionPreference = 'Stop'
$trapLog = Join-Path $PSScriptRoot 'Setup.log'
try {
    # Load shared logic (pure functions, no GUI).
    . (Join-Path $PSScriptRoot 'setup-core.ps1')
} catch {
    [System.Windows.Forms.MessageBox]::Show("Failed to load setup-core.ps1: $_", "Error", "OK", "Error")
    exit 1
}

trap {
    $_ | Out-File -Append $trapLog
    if (-not $Headless) {
        [System.Windows.Forms.MessageBox]::Show("Setup error: $_`n`n(see Setup.log)", "Error", "OK", "Error")
    } else {
        [Console]::Error.WriteLine("Setup error: $_")
    }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Catch unhandled exceptions from any WinForms event handler so we get the
# stack trace in Setup.log instead of a silent .NET crash dialog.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    $err = $e.Exception
    $detail = "$err`n$($err.StackTrace)"
    try { Add-Content -Path (Join-Path $PSScriptRoot 'Setup.log') -Value ("UNHANDLED: $detail") } catch {}
    try { [Console]::WriteLine("UNHANDLED: $detail") } catch {}
    if (-not $Headless) {
        [System.Windows.Forms.MessageBox]::Show(
            "Unhandled error: $err`n`n(see Setup.log for full stack trace)",
            "Error", "OK", "Error")
    }
})

# --------------------------------------------------------------------------
# Terminal window + centralized detailed logger
# --------------------------------------------------------------------------
# Pop a real console window (so logs are visible in a terminal, not only the
# GUI box). If a console is already attached (script launched from a terminal)
# AllocConsole returns false but [Console] still works.
$ConsoleWin32 = @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AllocConsole();
'@
try { Add-Type -MemberDefinition $ConsoleWin32 -Name 'AllocConsoleHelper' -Namespace 'Win32' -PassThru | Out-Null } catch {}
try { [Win32.AllocConsoleHelper]::AllocConsole() | Out-Null } catch {}

$script:setupLog = Join-Path $PSScriptRoot 'Setup.log'

# Writes a timestamped, detailed line to Setup.log AND the terminal window.
function Write-LogLine($text, $detail) {
    $ts = Get-Date -Format 'HH:mm:ss'
    $text = ($text -replace "`0", '')
    $line = if ($detail) { ("[{0}]    {1}" -f $ts, $text) } else { ("[{0}] {1}" -f $ts, $text) }
    try { Add-Content -Path $script:setupLog -Value $line } catch {}
    try { [Console]::WriteLine($line) } catch {}
}

# Reports to the GUI AND logs. Logging happens here so it works whether or not
# the GUI ProgressChanged handler is running (e.g. headless/test mode). The
# handler below only updates on-screen controls from the same state.
function Send-Progress($s, $pct, $msg, $isLog) {
    Write-LogLine $msg $isLog
    if ($s) {
        if ($isLog) { $s.ReportProgress($pct, @{ log = $msg }) }
        else        { $s.ReportProgress($pct, @{ status = $msg }) }
    }
}

# --- Live progress state (read by the heartbeat timer to keep the status line
#     alive even during stages that produce no streaming output) ---
$script:installStart = $null
$script:currentStage = ''

function Set-Stage($msg) {
    $script:currentStage = $msg
    Write-LogLine $msg $true
}

# Latest brave-origin-nightly .deb download URL (matches setup.sh's source).
function Get-BraveDebUrl {
    try {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/brave/brave-browser/releases?per_page=30' `
            -Headers @{ 'User-Agent' = 'brave-origin-setup' } -TimeoutSec 30
        foreach ($rel in $releases) {
            foreach ($asset in $rel.assets) {
                if ($asset.name -match 'brave-origin-nightly_[0-9.]+_amd64\.deb$') {
                    return $asset.browser_download_url
                }
            }
        }
    } catch { Write-LogLine ("Get-BraveDebUrl failed: " + $_.Exception.Message) $true }
    return $null
}

# Downloads a file with real byte progress (updates $script:currentStage as
# "Label: 123.4 MB / 600.0 MB (21%)"). Streaming copy on the worker thread so
# progress updates reliably (no reliance on background-thread event callbacks).
function Get-FileWithProgress($url, $dest, $label) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.UserAgent = 'brave-origin-setup'
    $req.AllowAutoRedirect = $true
    $req.Method = 'GET'
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $stream = $resp.GetResponseStream()
    $buf = New-Object byte[] 8192
    $read = 0; $rcv = 0
    $fs = [System.IO.File]::Create($dest)
    try {
        while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $read)
            $rcv += $read
            if ($total -gt 0) {
                $pct = [math]::Round($rcv / $total * 100)
                $script:currentStage = ("{0}: {1} MB / {2} MB ({3}%)" -f $label, [math]::Round($rcv/1MB,1), [math]::Round($total/1MB,1), $pct)
            } else {
                $script:currentStage = ("{0}: {1} MB downloaded" -f $label, [math]::Round($rcv/1MB,1))
            }
        }
    } finally {
        $fs.Close(); $stream.Close(); $resp.Close()
    }
    if (-not (Test-Path $dest) -or ((Get-Item $dest).Length -lt 1MB)) {
        throw ("Download of $url did not complete (file missing or too small).")
    }
}

# --------------------------------------------------------------------------
# GUI
# --------------------------------------------------------------------------

$form = New-Object Windows.Forms.Form
$form.Text = "Brave Origin for Windows - Setup"
$form.Size = New-Object Drawing.Size(560, 430)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$title = New-Object Windows.Forms.Label
$title.Location = New-Object Drawing.Point(16, 12)
$title.Size = New-Object Drawing.Size(528, 20)
$title.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
$title.Text = "Setting up Brave Origin Nightly (native WSLg)"
$form.Controls.Add($title)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(16, 38)
$status.Size = New-Object Drawing.Size(528, 32)
$status.Text = "Checking requirements (this takes a few seconds)..."
$form.Controls.Add($status)

$progress = New-Object Windows.Forms.ProgressBar
$progress.Location = New-Object Drawing.Point(16, 76)
$progress.Size = New-Object Drawing.Size(528, 22)
$progress.Style = "Marquee"
$progress.MarqueeAnimationSpeed = 40
$progress.Minimum = 0
$progress.Maximum = 100
$progress.Value = 0
$form.Controls.Add($progress)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(16, 108)
$logBox.Size = New-Object Drawing.Size(528, 240)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = New-Object Drawing.Font("Consolas", 9)
$form.Controls.Add($logBox)

$btn = New-Object Windows.Forms.Button
$btn.Location = New-Object Drawing.Point(448, 360)
$btn.Size = New-Object Drawing.Size(96, 30)
$btn.Text = "Install"
$btn.Enabled = $false
$form.Controls.Add($btn)

$btnCancel = New-Object Windows.Forms.Button
$btnCancel.Location = New-Object Drawing.Point(344, 360)
$btnCancel.Size = New-Object Drawing.Size(96, 30)
$btnCancel.Text = "Close"
$form.Controls.Add($btnCancel)

$form.CancelButton = $btnCancel

$script:phase = 'init'

# --------------------------------------------------------------------------
# Preflight worker (runs after the window is visible, so UI stays responsive)
# --------------------------------------------------------------------------

$pf = New-Object System.ComponentModel.BackgroundWorker
$pf.WorkerReportsProgress = $true
$pf.Add_DoWork({
    param($s, $e)
    $pfReport = {
        param($pct, $msg, $isLog)
        if ($isLog) { $s.ReportProgress($pct, @{ log = $msg }) }
        else        { $s.ReportProgress($pct, @{ status = $msg }) }
    }
    try {
        & $pfReport 1 "========== PREFLIGHT CHECKS ==========" $true
        $r = Get-Preflight
        & $pfReport 5 ("WSL2 installed:        " + $(if ($r.WSL2) { 'YES' } else { 'NO' })) $true
        & $pfReport 10 ("WSLg (GUI) available:  " + $(if ($r.WSLg) { 'YES' } else { 'NO  (will be installed - needs admin + reboot)' })) $true
        & $pfReport 15 ("WebView2 runtime:      " + $(if ($r.WebView2) { 'YES' } else { 'NO  (install Evergreen runtime)' })) $true
        & $pfReport 20 ("Disk free (C:) >=1.5G: " + $(if ($r.Disk) { 'YES' } else { 'NO' })) $true
        & $pfReport 25 ("Internet (github):     " + $(if ($r.Internet) { 'YES' } else { 'NO' })) $true
        & $pfReport 30 ("-" * 50) $true

        if (-not $r.NeedAdmin) {
            & $pfReport 40 "Ready. Click Install to set up (no admin rights needed)." $false
            $s.ReportProgress(40, @{ preflightDone = $true })
        } elseif (Test-Admin) {
            & $pfReport 40 "Will install WSL/WSLg, then continue. Click Install." $false
            $s.ReportProgress(40, @{ preflightDone = $true })
        } else {
            & $pfReport 40 "WSL/WSLg missing - Install will ask for admin (UAC)." $false
            $s.ReportProgress(40, @{ preflightDone = $true })
        }
    } catch {
        & $pfReport 40 ("preflight error: " + $_.Exception.Message) $true
        $s.ReportProgress(40, @{ preflightDone = $true })
    }
})

# --------------------------------------------------------------------------
# Install worker
# --------------------------------------------------------------------------

$bw = New-Object System.ComponentModel.BackgroundWorker
$bw.WorkerReportsProgress = $true
$installScript = {
    param($s, $e)
    $Report = {
        param($pct, $msg, $isLog)
        Send-Progress $s $pct $msg $isLog
    }

    try {
        Set-Stage "Install started"
        & $Report 5 "========== INSTALL WORKER STARTED ($(Get-Date)) ==========" $true
        # --- WSL / WSLg: install only if missing (needs admin + reboot) ---
        Set-Stage "Checking WSL2 / WSLg requirements"
        $wsl2 = Test-WSL2
        $wslg = Test-WSLg
        if (-not $wsl2) {
            Set-Stage "Installing WSL + Ubuntu (downloading ~600MB - this takes several minutes)"
            & $Report 10 "CMD: wsl --install" $true
            & wsl --install 2>&1 | ForEach-Object { & $Report 15 $_ $true }
            & $Report 100 "WSL installed. A REBOOT is required. Please reboot and run Setup.ps1 again."
            $s.ReportProgress(100, @{ done = $true; reboot = $true })
            return
        }
        if (-not $wslg) {
            Set-Stage "Installing WSLg (Windows GUI support for WSL - admin)"
            & $Report 10 "CMD: wsl --update" $true
            & wsl --update 2>&1 | ForEach-Object { & $Report 15 $_ $true }
            & wsl --shutdown 2>$null
            if (-not (Test-WSLg)) {
                & $Report 100 "WSLg still not active. A REBOOT is required. Please reboot and run Setup.ps1 again."
                $s.ReportProgress(100, @{ done = $true; reboot = $true })
                return
            }
        }
        Set-Stage "Requirements OK (WSL2 + WSLg present)"

        # --- Import rootfs (if not already imported) ---
        if (Distro-Exists) {
            Set-Stage ("Distro '{0}' already imported; skipping import" -f $distroName)
        } else {
            if (-not (Test-Path $rootfs)) {
                Set-Stage "Ubuntu rootfs missing - downloading (with progress)"
                & $Report 25 ("Rootfs not found at {0}; downloading official Ubuntu 22.04 WSL rootfs..." -f $rootfs) $true
                try {
                    # Fallback only: the shipped package normally contains
                    # linux\ubuntu-base.tar.gz. cloud-images publishes the rootfs
                    # only as .tar.xz, but `wsl --import` requires gzip, so download
                    # the xz and repack to gzip via a WSL distro (wsl --install
                    # creates one). If no WSL distro can do the repack, the user
                    # must use the full package instead.
                    $xzPath = Join-Path $appDir 'ubuntu-22.04-server-cloudimg-amd64-root.tar.xz'
                    Get-FileWithProgress 'https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-root.tar.xz' $xzPath "Downloading Ubuntu rootfs"
                    $wslXz = '/mnt/c' + ($xzPath.Substring(2) -replace '\\', '/')
                    $wslGz = '/mnt/c' + ($rootfs.Substring(2) -replace '\\', '/')
                    & wsl -e bash -c "xz -dc `"$wslXz`" | gzip -9 > `"$wslGz`"" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $rootfs)) {
                        throw "repack failed"
                    }
                    Remove-Item $xzPath -Force -ErrorAction SilentlyContinue
                } catch {
                    throw ("Ubuntu rootfs not found / could not be prepared. Please use the full Brave.zip package (contains linux\ubuntu-base.tar.gz). " + $_.Exception.Message)
                }
            }
            Set-Stage ("Importing Ubuntu rootfs as '{0}' (extracting, please wait)..." -f $distroName)
            & $Report 25 ("CMD: wsl --import {0} {1} {2} --version 2" -f $distroName, $installLoc, $rootfs) $true
            & wsl --import $distroName $installLoc $rootfs --version 2 2>&1 | ForEach-Object { & $Report 30 $_ $true }
        }

        # --- Copy app scripts into the distro ---
        Set-Stage "Copying app files into the distro (/opt/app)"
        $wslApp = ConvertTo-WslPath $appDir
        $files = @('setup.sh', 'start.sh', 'stop.sh', 'update.sh', 'launch-brave.sh', 'ensure-shm.sh', 'control.py', 'bridge.py', 'index.html')
        $quoted = ($files | ForEach-Object { "'$wslApp/$_'" }) -join ' '
        & $Report 40 "CMD: cp app files -> /opt/app/" $true
        Invoke-WslInDistro "mkdir -p /opt/app && cp $quoted /opt/app/ && chmod +x /opt/app/*.sh" 2>&1 | ForEach-Object { & $Report 45 $_ $true }

        # --- Download Brave .deb on the WINDOWS side (real MB progress) ---
        Set-Stage "Downloading Brave browser (real progress: MB / MB)"
        $debUrl = Get-BraveDebUrl
        if ($debUrl) {
            $debDest = Join-Path $env:TEMP 'brave-browser-latest-amd64.deb'
            & $Report 55 ("Downloading Brave .deb: {0}" -f $debUrl) $true
            Get-FileWithProgress $debUrl $debDest "Downloading Brave"
            if (Test-Path $debDest) {
                & $Report 63 "Brave .deb downloaded; copying into distro /opt/app..." $true
                $wslDeb = ConvertTo-WslPath $debDest
                Invoke-WslInDistro ("mkdir -p /opt/app && cp {0} /opt/app/ && ls -la /opt/app/*.deb" -f $wslDeb) 2>&1 | ForEach-Object { & $Report 65 $_ $true }
            }
        } else {
            & $Report 55 "Could not resolve Brave download URL; setup.sh will install via apt instead." $true
        }

        # --- Run setup.sh (installs Brave + deps; streams output) ---
        Set-Stage "Installing Brave + dependencies in WSL (apt - streaming)"
        & $Report 70 ("CMD: wsl -d {0} -e bash /opt/app/setup.sh" -f $distroName) $true
        & wsl -d $distroName -e bash /opt/app/setup.sh 2>&1 | ForEach-Object { & $Report 75 $_ $true }

        & $Report 90 "Setup complete."

        # --- Launch the manager via the Windows-side launcher, which applies the
        #     WSLg shared-memory fix before starting Brave.exe. Also drop a Desktop
        #     shortcut to it so the fix runs on every normal launch. ---
        $launcher = Join-Path $appDir 'Start-BraveOrigin.cmd'
        if (Test-Path $launcher) {
            Set-Stage "Launching Brave Origin (native window + manager UI)"
            & $Report 95 "Launching Brave Origin..." $true
            try {
                $ws = New-Object -ComObject WScript.Shell
                $link = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Brave Origin.lnk'))
                $link.TargetPath = $launcher
                $link.WorkingDirectory = $appDir
                $link.Description = 'Brave Origin (native WSLg)'
                $link.Save()
            } catch { Write-LogLine ("Desktop shortcut creation failed: " + $_.Exception.Message) $true }
            Start-Process -FilePath $launcher
        } elseif (Test-Path $braveExe) {
            Set-Stage "Launching Brave.exe (native window + manager UI)"
            & $Report 95 "Launching Brave.exe..." $true
            Start-Process -FilePath $braveExe
        } else {
            & $Report 95 "Brave.exe not in this folder - run it manually after building the package." $true
        }

        & $Report 100 "All done!"
        $s.ReportProgress(100, @{ done = $true })
    } catch {
        Write-LogLine ("INSTALL ERROR: " + $_.Exception.Message) $true
        $s.ReportProgress(100, @{ done = $true; error = ("Setup failed: " + $_.Exception.Message) })
    }
}

$bw.Add_DoWork($installScript)

# --------------------------------------------------------------------------
# Shared ProgressChanged (preflight + install)
# --------------------------------------------------------------------------

$pf.Add_ProgressChanged({
    param($s, $e)
    $st = $e.UserState
    if ($st -is [hashtable]) {
        if ($st.log)          { $logBox.AppendText($st.log + "`r`n"); $logBox.ScrollToCaret(); Write-LogLine $st.log $true }
        if ($st.status)       { $status.Text = $st.status; Write-LogLine $st.status $false }
        if ($st.preflightDone) {
            $progress.Style = "Blocks"
            $progress.Value = 0
            $btn.Enabled = $true
            $script:phase = 'idle'
        }
    }
})

$pf.Add_RunWorkerCompleted({
    $progress.Style = "Blocks"
    $progress.Value = 0
    if ($script:phase -eq 'init') {
        $btn.Enabled = $true
        $script:phase = 'idle'
    }
})

$bw.Add_ProgressChanged({
    param($s, $e)
    # Keep the bar in Marquee (indeterminate) the whole time we're working, so
    # it's always visibly animating even during the multi-minute setup.sh stage
    # where the percentage is static. Only snap to a solid 100% when done.
    $st = $e.UserState
    if ($st -is [hashtable]) {
        if ($st.status)   { $status.Text = $st.status }
        if ($st.log)      { $logBox.AppendText($st.log + "`r`n"); $logBox.ScrollToCaret() }
        if ($st.done) {
            $heartbeat.Stop()
            $progress.Style = "Blocks"
            $progress.Value = 100
            $btn.Enabled = $true
            $btn.Text = "Close"
            if ($st.reboot) {
                [System.Windows.Forms.MessageBox]::Show($st.status, "Reboot required", "OK", "Information")
            } elseif ($st.error) {
                [System.Windows.Forms.MessageBox]::Show($st.error, "Setup failed", "OK", "Error")
            }
        }
    } elseif ($st -is [string]) {
        $status.Text = $st
    }
})

$bw.Add_RunWorkerCompleted({ $btn.Enabled = $true; $btn.Text = "Close" })

# --------------------------------------------------------------------------
# Heartbeat: keep the status line alive with stage + elapsed time so the user
# always sees progress, even during stages that produce no streaming output.
# --------------------------------------------------------------------------
$heartbeat = New-Object Windows.Forms.Timer
$heartbeat.Interval = 1000
$heartbeat.Add_Tick({
    if ($script:phase -eq 'install' -and $script:installStart) {
        $el = (Get-Date) - $script:installStart
        $txt = if ($script:currentStage) { $script:currentStage } else { 'Working' }
        $status.Text = ("{0}   [elapsed {1:mm}:{1:ss}]" -f $txt, $el)
    }
})

# --------------------------------------------------------------------------
# Button events
# --------------------------------------------------------------------------

$btn.Add_Click({
    if ($bw.IsBusy) { return }
    $btn.Enabled = $false
    $btn.Text = "Working..."
    $script:phase = 'install'

    # Instant, unmistakable "it's running" feedback: animate the bar (marquee),
    # start the live heartbeat, and write status text right now.
    $progress.Style = "Marquee"
    $progress.MarqueeAnimationSpeed = 40
    $script:installStart = Get-Date
    $script:currentStage = 'Starting...'
    $heartbeat.Start()
    $status.Text = "Install started - this can take several minutes, please wait..."
    $logBox.AppendText("=== Install started ===`r`n")
    $logBox.ScrollToCaret()
    Write-LogLine "Install button clicked" $true

    # The install worker itself detects WSL2/WSLg and handles admin needs
    # (it runs wsl --install which prompts UAC when required), so we just run it.
    if (-not $bw.IsBusy) { $bw.RunWorkerAsync() }
})

$btnCancel.Add_Click({ $form.Close() })

# Start preflight from the Shown event so the form's message loop (and
# SynchronizationContext) is already running. Starting the BackgroundWorker
# before ShowDialog causes ProgressChanged to update controls from the wrong
# thread, which throws and silently swallows the updates (window looks stuck,
# no log lines).
$form.Add_Shown({ $pf.RunWorkerAsync() })

if ($Headless) {
    # Run the real install worker directly (no GUI), for testing / CI.
    # Stub the BackgroundWorker so $s.ReportProgress() calls are harmless.
    $stub = New-Object PSObject
    $stub | Add-Member ScriptMethod ReportProgress { param($p, $st) } -Force
    Write-LogLine "=== HEADLESS INSTALL MODE ===" $true
    $script:phase = 'install'
    $script:installStart = Get-Date
    & $installScript $stub $null
    Write-LogLine "=== HEADLESS INSTALL FINISHED ===" $true
} else {
    [void]$form.ShowDialog()
}
