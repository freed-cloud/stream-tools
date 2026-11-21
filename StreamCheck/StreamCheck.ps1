# Stream-check voor playingparentsnl
# Controleert voor het streamen of Windows, OBS en het geluid goed staan.
# Werkt met Windows PowerShell 5.1 (standaard in Windows) en de OBS WebSocket (OBS 28 of nieuwer).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# Onverwachte fout? Laat hem zien in plaats van stil te stoppen.
trap { [System.Windows.Forms.MessageBox]::Show("Er ging iets mis:`n`n$($_.Exception.Message)`n`nRegel $($_.InvocationInfo.ScriptLineNumber)", 'Fout') | Out-Null; break }

# ---------------------------------------------------------------- instellingen
$ConfigDir  = Join-Path $env:APPDATA 'StreamCheck'
$ConfigFile = Join-Path $ConfigDir 'config.json'

function Get-DefaultConfig {
    [pscustomobject]@{
        ObsPort       = 4455
        PasswordEnc   = ''
        HeadsetName   = 'SteelSeries'
        AudioInputs   = @('Desktop-audio', 'Mic/Aux', 'PlayStation')
        CaptureSource = 'PlayStation'
        ObsPath       = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
        LastOkBuild   = ''
    }
}

function Load-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path $ConfigFile) {
        try {
            $saved = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        } catch { }
    }
    return $cfg
}

function Save-Config($cfg) {
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
}

# Het OBS-wachtwoord wordt versleuteld met Windows (DPAPI): alleen jouw Windows-account kan het lezen.
function Protect-Text([string]$plain) {
    if (-not $plain) { return '' }
    return (ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString)
}
function Unprotect-Text([string]$enc) {
    if (-not $enc) { return '' }
    try {
        $sec  = ConvertTo-SecureString $enc
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return '' }
}

$script:Cfg = Load-Config

# ---------------------------------------------------------------- Windows-geluid (standaardapparaten)
$audioCode = @'
using System;
using System.Runtime.InteropServices;
namespace StreamCheck {
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropKey key);
        [PreserveSig] int GetValue(ref PropKey key, out PropVar value);
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PropKey { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Explicit)]
    struct PropVar { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr ptr; }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorCom { }

    public static class WinAudio {
        // flow: 0 = afspelen, 1 = opnemen
        public static string DefaultDeviceName(int flow) {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDevice dev;
            if (en.GetDefaultAudioEndpoint(flow, 0, out dev) != 0 || dev == null) return null;
            IPropertyStore store;
            if (dev.OpenPropertyStore(0, out store) != 0 || store == null) return null;
            PropKey key = new PropKey();
            key.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); // PKEY_Device_FriendlyName
            key.pid = 14;
            PropVar v;
            if (store.GetValue(ref key, out v) != 0 || v.ptr == IntPtr.Zero) return null;
            return Marshal.PtrToStringUni(v.ptr);
        }
    }
}
'@
try { Add-Type -TypeDefinition $audioCode -Language CSharp } catch { }

# ---------------------------------------------------------------- OBS WebSocket (protocol v5)
$script:Ws = $null; $script:RxTask = $null; $script:RxMs = $null
$script:RxBuf = New-Object byte[] 65536
$script:RxSeg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$script:RxBuf)
$script:Peaks = @{}

function Send-Obs($obj) {
    $json  = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg   = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
    $null = $script:Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(5000)
}

# Ontvangt één bericht. Geeft $null terug als er binnen de tijd niets binnenkomt.
function Receive-Obs([int]$timeoutMs) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    if ($null -eq $script:RxMs) { $script:RxMs = New-Object IO.MemoryStream }
    while ($true) {
        if ($null -eq $script:RxTask) {
            $script:RxTask = $script:Ws.ReceiveAsync($script:RxSeg, [Threading.CancellationToken]::None)
        }
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -lt 0) { $left = 0 }
        if (-not $script:RxTask.Wait($left)) { return $null }
        $r = $script:RxTask.Result
        $script:RxTask = $null
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'OBS heeft de verbinding gesloten. Klopt het wachtwoord?' }
        $script:RxMs.Write($script:RxBuf, 0, $r.Count)
        if ($r.EndOfMessage) { break }
    }
    $text = [Text.Encoding]::UTF8.GetString($script:RxMs.ToArray())
    $script:RxMs = $null
    return ($text | ConvertFrom-Json)
}

function Handle-ObsEvent($d) {
    if ($d.eventType -ne 'InputVolumeMeters') { return }
    foreach ($inp in $d.eventData.inputs) {
        $max = 0.0
        foreach ($ch in $inp.inputLevelsMul) { if ($ch.Count -ge 2 -and [double]$ch[1] -gt $max) { $max = [double]$ch[1] } }
        $name = [string]$inp.inputName
        if (-not $script:Peaks.ContainsKey($name) -or $script:Peaks[$name] -lt $max) { $script:Peaks[$name] = $max }
    }
}

function Get-Sha256Base64([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    return [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))
}

function Connect-Obs {
    Disconnect-Obs
    $script:Ws = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = [Uri]("ws://127.0.0.1:{0}" -f $script:Cfg.ObsPort)
    try { $ok = $script:Ws.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait(4000) }
    catch { throw 'Geen verbinding met OBS. Staat de WebSocket-server aan in OBS (Tools > WebSocket-serverinstellingen)?' }
    if (-not $ok) { throw 'OBS reageert niet op de WebSocket.' }
    $hello = Receive-Obs 4000
    if ($null -eq $hello -or $hello.op -ne 0) { throw 'OBS stuurde geen begroeting.' }
    $identify = @{ rpcVersion = 1; eventSubscriptions = 65536 }   # 65536 = geluidsmeters
    if ($hello.d.authentication) {
        $pw = Unprotect-Text $script:Cfg.PasswordEnc
        if (-not $pw) { throw 'OBS vraagt een wachtwoord. Vul het in via Instellingen.' }
        $secret = Get-Sha256Base64 ($pw + $hello.d.authentication.salt)
        $identify.authentication = Get-Sha256Base64 ($secret + $hello.d.authentication.challenge)
    }
    Send-Obs @{ op = 1; d = $identify }
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    while ([DateTime]::UtcNow -lt $deadline) {
        $m = Receive-Obs 1000
        if ($m -and $m.op -eq 2) { return }
    }
    throw 'OBS heeft de aanmelding niet geaccepteerd. Klopt het wachtwoord?'
}

function Disconnect-Obs {
    if ($script:Ws) { try { $script:Ws.Abort(); $script:Ws.Dispose() } catch { } }
    $script:Ws = $null; $script:RxTask = $null; $script:RxMs = $null
}

function Invoke-Obs([string]$type, $data = $null) {
    $id  = [guid]::NewGuid().ToString()
    $req = @{ requestType = $type; requestId = $id }
    if ($null -ne $data) { $req.requestData = $data }
    Send-Obs @{ op = 6; d = $req }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        $m = Receive-Obs 500
        if ($null -eq $m) { continue }
        if ($m.op -eq 5) { Handle-ObsEvent $m.d; continue }
        if ($m.op -eq 7 -and $m.d.requestId -eq $id) {
            if (-not $m.d.requestStatus.result) { throw ("OBS: {0} mislukt ({1})" -f $type, $m.d.requestStatus.comment) }
            return $m.d.responseData
        }
    }
    throw "OBS antwoordt niet op $type."
}

function Measure-Levels([int]$seconds) {
    $script:Peaks = @{}
    $end = [DateTime]::UtcNow.AddSeconds($seconds)
    while ([DateTime]::UtcNow -lt $end) {
        $m = Receive-Obs 200
        if ($m -and $m.op -eq 5) { Handle-ObsEvent $m.d }
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# ---------------------------------------------------------------- venster
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Stream-check - playingparentsnl'
$form.Size = New-Object System.Drawing.Size(620, 760)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Segoe UI', 11)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Klaar om live te gaan?'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 15)
$form.Controls.Add($title)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Check alles'
$btnCheck.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$btnCheck.Size = New-Object System.Drawing.Size(560, 70)
$btnCheck.Location = New-Object System.Drawing.Point(20, 65)
$btnCheck.BackColor = [System.Drawing.Color]::FromArgb(232, 85, 28)
$btnCheck.FlatStyle = 'Flat'
$form.Controls.Add($btnCheck)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Druk op "Check alles".'
$status.Size = New-Object System.Drawing.Size(560, 50)
$status.Location = New-Object System.Drawing.Point(20, 145)
$form.Controls.Add($status)

$list = New-Object System.Windows.Forms.FlowLayoutPanel
$list.Location = New-Object System.Drawing.Point(20, 200)
$list.Size = New-Object System.Drawing.Size(565, 420)
$list.FlowDirection = 'TopDown'
$list.WrapContents = $false
$list.AutoScroll = $true
$form.Controls.Add($list)

$btnObs = New-Object System.Windows.Forms.Button
$btnObs.Text = 'Open OBS'
$btnObs.Size = New-Object System.Drawing.Size(270, 50)
$btnObs.Location = New-Object System.Drawing.Point(20, 635)
$btnObs.FlatStyle = 'Flat'
$form.Controls.Add($btnObs)

$btnSettings = New-Object System.Windows.Forms.Button
$btnSettings.Text = 'Instellingen'
$btnSettings.Size = New-Object System.Drawing.Size(270, 50)
$btnSettings.Location = New-Object System.Drawing.Point(310, 635)
$btnSettings.FlatStyle = 'Flat'
$form.Controls.Add($btnSettings)

$script:Results = @()
function Add-Result([string]$level, [string]$name, [string]$detail) {
    # level: OK, WARN, FAIL, INFO
    $script:Results += [pscustomobject]@{ Level = $level; Name = $name }
    $color = switch ($level) {
        'OK'   { [System.Drawing.Color]::FromArgb(46, 204, 113) }
        'WARN' { [System.Drawing.Color]::FromArgb(243, 156, 18) }
        'FAIL' { [System.Drawing.Color]::FromArgb(231, 76, 60) }
        default { [System.Drawing.Color]::Gray }
    }
    $icon = switch ($level) { 'OK' { 'OK' } 'WARN' { '!' } 'FAIL' { 'X' } default { 'i' } }
    $row = New-Object System.Windows.Forms.Panel
    $row.Size = New-Object System.Drawing.Size(535, 62)
    $dot = New-Object System.Windows.Forms.Label
    $dot.Text = $icon
    $dot.TextAlign = 'MiddleCenter'
    $dot.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $dot.BackColor = $color
    $dot.Size = New-Object System.Drawing.Size(40, 40)
    $dot.Location = New-Object System.Drawing.Point(0, 8)
    $txt = New-Object System.Windows.Forms.Label
    $txt.Text = $name
    $txt.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $txt.Location = New-Object System.Drawing.Point(50, 2)
    $txt.Size = New-Object System.Drawing.Size(480, 22)
    $det = New-Object System.Windows.Forms.Label
    $det.Text = $detail
    $det.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $det.ForeColor = [System.Drawing.Color]::Silver
    $det.Location = New-Object System.Drawing.Point(50, 24)
    $det.Size = New-Object System.Drawing.Size(480, 36)
    $row.Controls.AddRange(@($dot, $txt, $det))
    $list.Controls.Add($row)
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Status([string]$text) { $status.Text = $text; [System.Windows.Forms.Application]::DoEvents() }

# ---------------------------------------------------------------- de checks
function Test-WindowsAudio {
    $hs = $script:Cfg.HeadsetName
    foreach ($f in @(@{ Flow = 0; Name = 'Afspelen' }, @{ Flow = 1; Name = 'Opnemen' })) {
        $dev = $null
        try { $dev = [StreamCheck.WinAudio]::DefaultDeviceName($f.Flow) } catch { }
        if (-not $dev) { Add-Result 'WARN' ("Windows-geluid: {0}" -f $f.Name) 'Kon het standaardapparaat niet uitlezen.'; continue }
        if ($dev -like "*$hs*") { Add-Result 'OK' ("Windows-geluid: {0}" -f $f.Name) $dev }
        else { Add-Result 'FAIL' ("Windows-geluid: {0}" -f $f.Name) ("Standaard is '{0}', niet je {1}. Zet de headset als standaard in Windows-geluid." -f $dev, $hs) }
    }
}

function Test-WindowsUpdate {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $script:Build = '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR
    $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
              (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    if ($reboot) { Add-Result 'WARN' 'Windows-update' 'Windows wacht op een herstart. Herstart eerst, anders kan het tijdens je stream gebeuren.' }
    elseif ($script:Cfg.LastOkBuild -and $script:Cfg.LastOkBuild -ne $script:Build) {
        Add-Result 'WARN' 'Windows is bijgewerkt' ("Van {0} naar {1} sinds je laatste goede check. Test je geluid extra goed (zo ging het op 20 november mis)." -f $script:Cfg.LastOkBuild, $script:Build)
    }
    else { Add-Result 'OK' 'Windows-update' ("Geen herstart nodig (versie {0})." -f $script:Build) }
}

function Test-Internet {
    # Alleen kijken of er een verbinding met Twitch (poort 443) lukt; een webpagina ophalen is niet nodig.
    $ok = $false
    $tcp = New-Object Net.Sockets.TcpClient
    try { $ok = $tcp.ConnectAsync('www.twitch.tv', 443).Wait(5000) -and $tcp.Connected } catch { $ok = $false } finally { $tcp.Close() }
    if ($ok) { Add-Result 'OK' 'Internet' 'Twitch is bereikbaar.' }
    else { Add-Result 'FAIL' 'Internet' 'Twitch is niet bereikbaar. Check je wifi.' }
}

function Test-Obs {
    if (-not (Get-Process -Name obs64 -ErrorAction SilentlyContinue)) {
        Add-Result 'FAIL' 'OBS' 'OBS staat niet aan. Klik op "Open OBS" en check daarna opnieuw.'
        return
    }
    try { Connect-Obs } catch { Add-Result 'FAIL' 'OBS-verbinding' $_.Exception.Message; return }
    Add-Result 'OK' 'OBS' 'OBS draait en de verbinding werkt.'

    $inputs = (Invoke-Obs 'GetInputList').inputs
    $names  = @($inputs | ForEach-Object { $_.inputName })

    # 1. Bestaan de apparaten nog? (de fout van 20 november)
    foreach ($inp in $inputs) {
        $kind = if ($inp.unversionedInputKind) { $inp.unversionedInputKind } else { $inp.inputKind }
        $prop = $null
        if ($kind -eq 'wasapi_input_capture' -or $kind -eq 'wasapi_output_capture') { $prop = 'device_id' }
        elseif ($kind -eq 'dshow_input') { $prop = 'video_device_id' }
        if (-not $prop) { continue }
        try {
            $settings = (Invoke-Obs 'GetInputSettings' @{ inputName = $inp.inputName }).inputSettings
            $current  = [string]$settings.$prop
            if (-not $current -or $current -eq 'default') { Add-Result 'OK' ("Apparaat: {0}" -f $inp.inputName) 'Volgt het standaardapparaat van Windows.'; continue }
            $items = (Invoke-Obs 'GetInputPropertiesListPropertyItems' @{ inputName = $inp.inputName; propertyName = $prop }).propertyItems
            $match = $items | Where-Object { [string]$_.itemValue -eq $current } | Select-Object -First 1
            if ($match) { Add-Result 'OK' ("Apparaat: {0}" -f $inp.inputName) $match.itemName }
            else { Add-Result 'FAIL' ("Apparaat: {0}" -f $inp.inputName) 'Het gekozen apparaat bestaat niet meer. Kies het opnieuw in OBS (rechtsklik > Eigenschappen), of kies "Standaard".' }
        } catch { Add-Result 'WARN' ("Apparaat: {0}" -f $inp.inputName) $_.Exception.Message }
    }

    # 2. Staat er iets gedempt?
    foreach ($a in $script:Cfg.AudioInputs) {
        if ($names -notcontains $a) { Add-Result 'WARN' ("Geluid: {0}" -f $a) 'Deze bron bestaat niet in OBS. Pas de naam aan in Instellingen.'; continue }
        $muted = (Invoke-Obs 'GetInputMute' @{ inputName = $a }).inputMuted
        if ($muted) { Add-Result 'FAIL' ("Gedempt: {0}" -f $a) 'Deze bron staat op stil in OBS. Klik op het luidsprekertje in de mixer.' }
    }

    # 3. Komt er echt geluid binnen?
    Set-Status 'Meten... Praat even en laat de game geluid maken (6 seconden).'
    Measure-Levels 6
    foreach ($a in $script:Cfg.AudioInputs) {
        if ($names -notcontains $a) { continue }
        $peak = 0.0
        if ($script:Peaks.ContainsKey($a)) { $peak = $script:Peaks[$a] }
        if ($peak -gt 0.001) {
            $db = [math]::Round(20 * [math]::Log10($peak), 0)
            Add-Result 'OK' ("Geluid komt binnen: {0}" -f $a) ("Hoogste piek {0} dB." -f $db)
        } else {
            Add-Result 'FAIL' ("Geen geluid: {0}" -f $a) 'De balk bewoog niet. Praat of speel geluid af en check opnieuw. Blijft het stil, kijk dan bij Apparaat hierboven.'
        }
    }

    # 4. Geeft de capture card beeld?
    $cap = $script:Cfg.CaptureSource
    if ($names -contains $cap) {
        try {
            $shot = Invoke-Obs 'GetSourceScreenshot' @{ sourceName = $cap; imageFormat = 'png'; imageWidth = 160 }
            $b64  = $shot.imageData -replace '^data:image/[a-zA-Z]+;base64,', ''
            $imgBytes = [Convert]::FromBase64String($b64)
            $ms   = New-Object IO.MemoryStream -ArgumentList @(,$imgBytes)
            $bmp  = [System.Drawing.Bitmap]::FromStream($ms)
            $sum = 0.0; $n = 0
            for ($x = 0; $x -lt $bmp.Width; $x += 4) { for ($y = 0; $y -lt $bmp.Height; $y += 4) {
                $p = $bmp.GetPixel($x, $y); $sum += ($p.R + $p.G + $p.B) / 3; $n++ } }
            $bmp.Dispose(); $ms.Dispose()
            $avg = if ($n) { $sum / $n } else { 0 }
            if ($avg -gt 8) { Add-Result 'OK' ("Beeld: {0}" -f $cap) 'De capture card geeft beeld.' }
            else { Add-Result 'WARN' ("Beeld: {0}" -f $cap) 'Het beeld is zwart. Staat de PlayStation aan?' }
        } catch { Add-Result 'WARN' ("Beeld: {0}" -f $cap) ('Kon geen beeld ophalen: ' + $_.Exception.Message) }
    } else { Add-Result 'WARN' 'Capture card' ("Bron '{0}' niet gevonden. Pas de naam aan in Instellingen." -f $cap) }

    # 5. Al live?
    try {
        $st = Invoke-Obs 'GetStreamStatus'
        if ($st.outputActive) { Add-Result 'INFO' 'Stream' 'Je bent al live.' }
    } catch { }
    Disconnect-Obs
}

function Start-AllChecks {
    $btnCheck.Enabled = $false
    $list.Controls.Clear()
    $script:Results = @()
    $script:Cfg = Load-Config
    try {
        Set-Status 'Windows controleren...'
        Test-WindowsUpdate
        Test-WindowsAudio
        Test-Internet
        Set-Status 'OBS controleren...'
        Test-Obs
    } catch {
        Add-Result 'FAIL' 'Onverwachte fout' $_.Exception.Message
    } finally {
        Disconnect-Obs
    }
    $fails = @($script:Results | Where-Object { $_.Level -eq 'FAIL' }).Count
    $warns = @($script:Results | Where-Object { $_.Level -eq 'WARN' }).Count
    if ($fails -eq 0) {
        $script:Cfg.LastOkBuild = $script:Build
        Save-Config $script:Cfg
    }
    if ($fails -gt 0) {
        $title.Text = 'Nog niet live gaan'; $title.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
        Set-Status ("{0} probleem/problemen. Los de rode punten op en check opnieuw." -f $fails)
    } elseif ($warns -gt 0) {
        $title.Text = 'Bijna klaar'; $title.ForeColor = [System.Drawing.Color]::FromArgb(243, 156, 18)
        Set-Status ("Geen fouten, wel {0} waarschuwing(en). Lees ze even na." -f $warns)
    } else {
        $title.Text = 'Alles in orde: ga live!'; $title.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        Set-Status 'Open OBS en klik op Start Streaming.'
    }
    $btnCheck.Enabled = $true
}

# ---------------------------------------------------------------- instellingenvenster
function Show-Settings {
    $cfg = Load-Config
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Instellingen'; $f.Size = New-Object System.Drawing.Size(460, 430); $f.StartPosition = 'CenterParent'
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $fields = @(
        @{ Label = 'OBS WebSocket-wachtwoord (leeg laten = niet wijzigen)'; Key = 'pw'; Value = '' },
        @{ Label = 'OBS WebSocket-poort'; Key = 'port'; Value = [string]$cfg.ObsPort },
        @{ Label = 'Naam headset (deel van de naam is genoeg)'; Key = 'hs'; Value = $cfg.HeadsetName },
        @{ Label = 'Geluidsbronnen in OBS (gescheiden door komma)'; Key = 'audio'; Value = ($cfg.AudioInputs -join ', ') },
        @{ Label = 'Naam van de capture card-bron in OBS'; Key = 'cap'; Value = $cfg.CaptureSource }
    )
    $boxes = @{}; $y = 10
    foreach ($fd in $fields) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $fd.Label; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(15, $y)
        $t = New-Object System.Windows.Forms.TextBox; $t.Text = $fd.Value; $t.Size = New-Object System.Drawing.Size(410, 25); $t.Location = New-Object System.Drawing.Point(15, ($y + 22))
        if ($fd.Key -eq 'pw') { $t.UseSystemPasswordChar = $true }
        $f.Controls.AddRange(@($l, $t)); $boxes[$fd.Key] = $t; $y += 62
    }
    $save = New-Object System.Windows.Forms.Button; $save.Text = 'Opslaan'; $save.Size = New-Object System.Drawing.Size(410, 40); $save.Location = New-Object System.Drawing.Point(15, ($y + 5))
    $save.Add_Click({
        if ($boxes.pw.Text) { $cfg.PasswordEnc = Protect-Text $boxes.pw.Text }
        $port = 0; if ([int]::TryParse($boxes.port.Text, [ref]$port)) { $cfg.ObsPort = $port }
        $cfg.HeadsetName = $boxes.hs.Text.Trim()
        $cfg.AudioInputs = @($boxes.audio.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $cfg.CaptureSource = $boxes.cap.Text.Trim()
        Save-Config $cfg
        $f.Close()
    })
    $f.Controls.Add($save)
    [void]$f.ShowDialog($form)
    $script:Cfg = Load-Config
}

function Open-Obs {
    $p = Get-Process -Name obs64 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        $null = (New-Object -ComObject WScript.Shell).AppActivate($p.Id)
        return
    }
    $exe = $script:Cfg.ObsPath
    if (-not (Test-Path $exe)) { [System.Windows.Forms.MessageBox]::Show("OBS niet gevonden op $exe") | Out-Null; return }
    # OBS moet starten vanuit zijn eigen map, anders mist hij bestanden.
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)
}

$btnCheck.Add_Click({ Start-AllChecks })
$btnSettings.Add_Click({ Show-Settings })
$btnObs.Add_Click({ Open-Obs })
$form.Add_Shown({ if (-not $script:Cfg.PasswordEnc) { $status.Text = 'Eerste keer? Vul eerst je OBS WebSocket-wachtwoord in via Instellingen.' } })

[void]$form.ShowDialog()
