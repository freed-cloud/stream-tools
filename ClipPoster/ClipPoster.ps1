# Clip-poster voor playingparentsnl
# Uploadt clips met tekst naar YouTube (via de officiële YouTube Data API)
# en zet ze klaar voor TikTok en Instagram (tekst gekopieerd, bestand geselecteerd, uploadpagina open).
# Werkt met Windows PowerShell 5.1 (standaard in Windows).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web
[System.Windows.Forms.Application]::EnableVisualStyles()
# Onverwachte fout? Laat hem zien in plaats van stil te stoppen.
trap { [System.Windows.Forms.MessageBox]::Show("Er ging iets mis:`n`n$($_.Exception.Message)`n`nRegel $($_.InvocationInfo.ScriptLineNumber)", 'Fout') | Out-Null; break }

# ---------------------------------------------------------------- bestanden en instellingen
$AppDir      = Join-Path $env:APPDATA 'ClipPoster'
$ConfigFile  = Join-Path $AppDir 'config.json'
$SecretFile  = Join-Path $AppDir 'client_secret.json'
$TokenFile   = Join-Path $AppDir 'token.dat'
$StatusFile  = Join-Path $AppDir 'gepost.json'
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }

$Desktop = [Environment]::GetFolderPath('Desktop')
function Load-Json($path, $default) {
    if (Test-Path $path) { try { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    return $default
}
function Save-Json($path, $obj) { $obj | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8 }

$script:Cfg = Load-Json $ConfigFile ([pscustomobject]@{
    ClipsRoot = (Join-Path $Desktop 'Clips voor socials')
    Privacy   = 'public'
})
$script:Done = @{}
$saved = Load-Json $StatusFile $null
if ($saved) { foreach ($p in $saved.PSObject.Properties) { $script:Done[$p.Name] = $p.Value } }

function Save-Status {
    $o = New-Object psobject
    foreach ($k in $script:Done.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $script:Done[$k] }
    Save-Json $StatusFile $o
}
function Get-State([string]$file) {
    if (-not $script:Done.ContainsKey($file)) { $script:Done[$file] = [pscustomobject]@{ youtube = ''; tiktok = $false; instagram = $false } }
    return $script:Done[$file]
}

# Geheimen (de inlogsleutel van YouTube) worden versleuteld met Windows (DPAPI).
function Protect-Text([string]$plain) { ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString }
function Unprotect-Text([string]$enc) {
    $sec = ConvertTo-SecureString $enc
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# ---------------------------------------------------------------- clips en teksten
function Get-PostFolder {
    $v = Join-Path $script:Cfg.ClipsRoot 'Vandaag posten'
    if (Test-Path $v) { return $v }
    return $script:Cfg.ClipsRoot
}

function Get-ClipText([string]$mp4) {
    $folder = Split-Path $mp4
    $base   = [IO.Path]::GetFileNameWithoutExtension($mp4)
    $name   = ($base -replace '^\d+\s*-\s*', '') -replace '\s*-\s*staand$', ''
    $candidates = @(
        (Join-Path $folder "$base.txt"),
        (Join-Path $folder "$name - tekst.txt"),
        (Join-Path $script:Cfg.ClipsRoot "$name - tekst.txt")
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return ([IO.File]::ReadAllText($c, [Text.Encoding]::UTF8)).Trim() } }
    # Anders: zoek het stuk in "Teksten om te plakken.txt"
    $all = Join-Path $folder 'Teksten om te plakken.txt'
    if (Test-Path -LiteralPath $all) {
        $lines = [IO.File]::ReadAllLines($all, [Text.Encoding]::UTF8)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Contains($name)) {
                $out = New-Object System.Collections.Generic.List[string]
                for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                    if ($lines[$j] -match '^\s*\d+\s*[-.)]\s') { break }
                    $out.Add($lines[$j])
                }
                return (($out -join "`r`n").Trim())
            }
        }
    }
    return ''
}

# ---------------------------------------------------------------- inloggen bij YouTube (OAuth met PKCE)
function ConvertTo-Base64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function New-RandomString([int]$bytes) {
    $buf = New-Object byte[] $bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return (ConvertTo-Base64Url $buf)
}

function Get-ClientSecret {
    if (-not (Test-Path $SecretFile)) { throw 'Nog geen client_secret.json. Klik op "YouTube instellen" (zie de handleiding).' }
    $j = Get-Content $SecretFile -Raw | ConvertFrom-Json
    if ($j.installed) { return $j.installed }
    throw 'client_secret.json is niet van het type "Desktop-app". Maak in Google Cloud een OAuth-client van het type Desktop-app.'
}

function Invoke-Login($client) {
    $verifier  = New-RandomString 48
    $sha       = [Security.Cryptography.SHA256]::Create()
    $challenge = ConvertTo-Base64Url ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    $state     = New-RandomString 16
    $tcp = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $port = $tcp.LocalEndpoint.Port
    $redirect = "http://127.0.0.1:$port"
    $q = @{
        client_id = $client.client_id; redirect_uri = $redirect; response_type = 'code'
        scope = 'https://www.googleapis.com/auth/youtube.upload'; code_challenge = $challenge
        code_challenge_method = 'S256'; access_type = 'offline'; prompt = 'consent'; state = $state
    }
    $qs = ($q.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
    Start-Process ('https://accounts.google.com/o/oauth2/v2/auth?' + $qs)
    Set-Status 'Log in bij Google in je browser en geef toestemming...'
    $first = $null
    $end = [DateTime]::UtcNow.AddMinutes(3)
    try {
        # Browsers openen soms een lege verbinding vooraf; die slaan we over tot het echte antwoord van Google binnenkomt.
        while (-not $first) {
            $acc = $tcp.AcceptTcpClientAsync()
            while (-not $acc.Wait(200)) {
                [System.Windows.Forms.Application]::DoEvents()
                if ([DateTime]::UtcNow -gt $end) { throw 'Inloggen duurde te lang.' }
            }
            $client2 = $acc.Result
            $client2.ReceiveTimeout = 3000
            $line = $null
            try {
                $stream = $client2.GetStream()
                $reader = New-Object IO.StreamReader($stream)
                $line = $reader.ReadLine()
                if ($line -and ($line -match '[?&](code|error)=')) {
                    $first = $line
                    $html = '<html><body style="font-family:Segoe UI"><h2>Klaar! Je kunt dit tabblad sluiten.</h2></body></html>'
                    $resp = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nConnection: close`r`n`r`n$html"
                    $bytes = [Text.Encoding]::UTF8.GetBytes($resp)
                    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
                }
            } catch { } finally { $client2.Close() }
        }
    } finally { $tcp.Stop() }
    $path = ($first -split ' ')[1]
    $query = [Web.HttpUtility]::ParseQueryString(($path -split '\?', 2)[1])
    if ($query['error']) { throw ('Google gaf geen toestemming: ' + $query['error']) }
    if ($query['state'] -ne $state) { throw 'Onverwacht antwoord van Google (state klopt niet).' }
    $tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
        code = $query['code']; client_id = $client.client_id; client_secret = $client.client_secret
        redirect_uri = $redirect; grant_type = 'authorization_code'; code_verifier = $verifier
    }
    if ($tok.refresh_token) { Set-Content -Path $TokenFile -Value (Protect-Text $tok.refresh_token) }
    return $tok.access_token
}

function Get-AccessToken {
    $client = Get-ClientSecret
    if (Test-Path $TokenFile) {
        try {
            $refresh = Unprotect-Text (Get-Content $TokenFile -Raw).Trim()
            $tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
                client_id = $client.client_id; client_secret = $client.client_secret
                refresh_token = $refresh; grant_type = 'refresh_token'
            }
            return $tok.access_token
        } catch { Remove-Item $TokenFile -ErrorAction SilentlyContinue }
    }
    return (Invoke-Login $client)
}

# ---------------------------------------------------------------- uploaden (op de achtergrond, zodat het venster blijft reageren)
$UploadJob = {
    param($token, $path, $metaJson)
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $size = (Get-Item -LiteralPath $path).Length
        $init = Invoke-WebRequest -UseBasicParsing -Method Post `
            -Uri 'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status' `
            -Headers @{ Authorization = "Bearer $token"; 'X-Upload-Content-Type' = 'video/mp4'; 'X-Upload-Content-Length' = "$size" } `
            -ContentType 'application/json; charset=UTF-8' -Body ([Text.Encoding]::UTF8.GetBytes($metaJson))
        $location = [string]$init.Headers['Location']
        $video = Invoke-RestMethod -Method Put -Uri $location -InFile $path -ContentType 'video/mp4' -Headers @{ Authorization = "Bearer $token" }
        "OK|$($video.id)|$($video.status.privacyStatus)"
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        "FOUT|$detail"
    }
}

# ---------------------------------------------------------------- venster
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Clip-poster - playingparentsnl'
$form.Size = New-Object System.Drawing.Size(980, 680)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$lst = New-Object System.Windows.Forms.ListBox
$lst.Location = New-Object System.Drawing.Point(15, 45); $lst.Size = New-Object System.Drawing.Size(440, 520)
$lst.HorizontalScrollbar = $true
$form.Controls.Add($lst)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Location = New-Object System.Drawing.Point(15, 12); $lblFolder.Size = New-Object System.Drawing.Size(440, 28)
$form.Controls.Add($lblFolder)

$lblTitle = New-Object System.Windows.Forms.Label; $lblTitle.Text = 'Titel (YouTube, max. 100 tekens)'
$lblTitle.Location = New-Object System.Drawing.Point(475, 12); $lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)
$txtTitle = New-Object System.Windows.Forms.TextBox
$txtTitle.Location = New-Object System.Drawing.Point(475, 35); $txtTitle.Size = New-Object System.Drawing.Size(470, 25); $txtTitle.MaxLength = 100
$form.Controls.Add($txtTitle)

$lblText = New-Object System.Windows.Forms.Label; $lblText.Text = 'Tekst met hashtags (wordt gekopieerd en als beschrijving gebruikt)'
$lblText.Location = New-Object System.Drawing.Point(475, 68); $lblText.AutoSize = $true
$form.Controls.Add($lblText)
$txt = New-Object System.Windows.Forms.TextBox
$txt.Multiline = $true; $txt.ScrollBars = 'Vertical'
$txt.Location = New-Object System.Drawing.Point(475, 90); $txt.Size = New-Object System.Drawing.Size(470, 200)
$form.Controls.Add($txt)

$cmbPrivacy = New-Object System.Windows.Forms.ComboBox
$cmbPrivacy.DropDownStyle = 'DropDownList'
[void]$cmbPrivacy.Items.AddRange(@('openbaar', 'verborgen (unlisted)', 'privé'))
$cmbPrivacy.Location = New-Object System.Drawing.Point(475, 300); $cmbPrivacy.Size = New-Object System.Drawing.Size(200, 25)
$privacyMap = @{ 'openbaar' = 'public'; 'verborgen (unlisted)' = 'unlisted'; 'privé' = 'private' }
$cmbPrivacy.SelectedIndex = [array]::IndexOf(@('public', 'unlisted', 'private'), [string]$script:Cfg.Privacy)
if ($cmbPrivacy.SelectedIndex -lt 0) { $cmbPrivacy.SelectedIndex = 0 }
$form.Controls.Add($cmbPrivacy)

function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 45)
    if ($color) { $b.BackColor = $color; $b.ForeColor = [System.Drawing.Color]::White; $b.FlatStyle = 'Flat' }
    $form.Controls.Add($b); return $b
}
$btnYt    = New-Btn '1. Upload naar YouTube'      475 340 470 ([System.Drawing.Color]::FromArgb(204, 0, 0))
$btnTt    = New-Btn '2. Klaarzetten voor TikTok'  475 392 470 ([System.Drawing.Color]::FromArgb(20, 20, 20))
$btnIg    = New-Btn '3. Klaarzetten voor Instagram' 475 444 470 ([System.Drawing.Color]::FromArgb(193, 53, 132))
$btnDone  = New-Btn 'Klaar: verplaats naar "Gepost"' 475 496 470 ([System.Drawing.Color]::FromArgb(39, 174, 96))
$btnSetup = New-Btn 'YouTube instellen'   15 575 215 $null
$btnFolder= New-Btn 'Andere map kiezen'  240 575 215 $null

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(475, 550); $status.Size = New-Object System.Drawing.Size(470, 75)
$form.Controls.Add($status)
function Set-Status([string]$t) { $status.Text = $t; [System.Windows.Forms.Application]::DoEvents() }

$script:Files = @()
function Refresh-List {
    $sel = $lst.SelectedIndex
    $folder = Get-PostFolder
    $lblFolder.Text = "Map: $folder"
    $lst.Items.Clear()
    $script:Files = @(Get-ChildItem -LiteralPath $folder -Filter *.mp4 -File -ErrorAction SilentlyContinue | Sort-Object { if ($_.Name -match '^(\d+)') { [int]$Matches[1] } else { 99999 } }, Name)
    foreach ($f in $script:Files) {
        $s = Get-State $f.Name
        $mark = '[YT {0}] [TT {1}] [IG {2}]  ' -f ($(if ($s.youtube) { 'v' } else { '-' })), ($(if ($s.tiktok) { 'v' } else { '-' })), ($(if ($s.instagram) { 'v' } else { '-' }))
        [void]$lst.Items.Add($mark + $f.Name)
    }
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = [math]::Min([math]::Max($sel, 0), $lst.Items.Count - 1) }
    else { $txt.Text = ''; $txtTitle.Text = ''; Set-Status 'Geen clips gevonden in deze map.' }
}

function Get-Selected {
    if ($lst.SelectedIndex -lt 0) { [System.Windows.Forms.MessageBox]::Show('Kies eerst een clip in de lijst.') | Out-Null; return $null }
    return $script:Files[$lst.SelectedIndex]
}

$lst.Add_SelectedIndexChanged({
    if ($lst.SelectedIndex -lt 0) { return }
    $f = $script:Files[$lst.SelectedIndex]
    $t = Get-ClipText $f.FullName
    $txt.Text = $t
    $first = ($t -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $first) { $first = ($f.BaseName -replace '^\d+\s*-\s*', '') }
    $first = ($first -replace '#\S+', '' -replace '[<>]', '').Trim()
    if ($first.Length -gt 100) { $first = $first.Substring(0, 100) }
    $txtTitle.Text = $first
    $s = Get-State $f.Name
    if ($s.youtube) { Set-Status ("Al op YouTube: https://youtube.com/shorts/{0}" -f $s.youtube) } else { Set-Status '' }
})

$script:Job = $null; $script:JobFile = $null
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000
$timer.Add_Tick({
    if (-not $script:Job) { $timer.Stop(); return }
    if ($script:Job.State -eq 'Running') { Set-Status ("Uploaden naar YouTube... ({0} sec)" -f [int]((Get-Date) - $script:Job.PSBeginTime).TotalSeconds); return }
    $timer.Stop()
    $out = [string](Receive-Job $script:Job | Select-Object -Last 1)
    Remove-Job $script:Job -Force; $script:Job = $null
    $btnYt.Enabled = $true
    if ($out -like 'OK|*') {
        $parts = $out.Split('|')
        $s = Get-State $script:JobFile
        $s.youtube = $parts[1]; Save-Status
        Set-Status ("Op YouTube gezet ({0}): https://youtube.com/shorts/{1}" -f $parts[2], $parts[1])
        Refresh-List
    } else {
        Set-Status ('Upload mislukt: ' + ($out -replace '^FOUT\|', ''))
    }
})

$btnYt.Add_Click({
    $f = Get-Selected; if (-not $f) { return }
    if ((Get-State $f.Name).youtube) {
        $a = [System.Windows.Forms.MessageBox]::Show('Deze clip staat al op YouTube. Nog een keer uploaden?', 'Let op', 'YesNo')
        if ($a -ne 'Yes') { return }
    }
    if (-not $txtTitle.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('Vul een titel in.') | Out-Null; return }
    try { $token = Get-AccessToken } catch { Set-Status ('Inloggen mislukt: ' + $_.Exception.Message); return }
    $privacy = $privacyMap[[string]$cmbPrivacy.SelectedItem]
    $script:Cfg.Privacy = $privacy; Save-Json $ConfigFile $script:Cfg
    $tags = @([regex]::Matches($txt.Text, '#(\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 15)
    $meta = @{
        snippet = @{ title = $txtTitle.Text.Trim(); description = $txt.Text; categoryId = '20'; tags = $tags }
        status  = @{ privacyStatus = $privacy; selfDeclaredMadeForKids = $false }
    } | ConvertTo-Json -Depth 5 -Compress
    $btnYt.Enabled = $false
    $script:JobFile = $f.Name
    $script:Job = Start-Job -ScriptBlock $UploadJob -ArgumentList $token, $f.FullName, $meta
    $timer.Start()
})

function Prepare-Manual($f, [string]$site, [string]$url) {
    $text = $txt.Text
    if ($text) { Set-Clipboard -Value $text }
    Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $f.FullName)
    Start-Process $url
    $s = Get-State $f.Name
    $s.$site = $true; Save-Status
    Set-Status 'Tekst staat op je klembord en de video is geselecteerd in Verkenner. Sleep de video naar de uploadpagina en plak de tekst (Ctrl+V).'
    Refresh-List
}
$btnTt.Add_Click({ $f = Get-Selected; if ($f) { Prepare-Manual $f 'tiktok' 'https://www.tiktok.com/tiktokstudio/upload' } })
$btnIg.Add_Click({ $f = Get-Selected; if ($f) { Prepare-Manual $f 'instagram' 'https://www.instagram.com/' } })

$btnDone.Add_Click({
    $f = Get-Selected; if (-not $f) { return }
    $dest = Join-Path $script:Cfg.ClipsRoot 'Gepost'
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
    Move-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $f.Name) -Force
    $own = Join-Path $f.DirectoryName ($f.BaseName + '.txt')
    if (Test-Path -LiteralPath $own) { Move-Item -LiteralPath $own -Destination (Join-Path $dest ($f.BaseName + '.txt')) -Force }
    Set-Status ("Verplaatst naar {0}" -f $dest)
    Refresh-List
})

$btnSetup.Add_Click({
    $msg = "Kies het bestand client_secret.json dat je in Google Cloud hebt gedownload (OAuth-client, type Desktop-app).`n`nDaarna log je één keer in bij Google."
    [System.Windows.Forms.MessageBox]::Show($msg, 'YouTube instellen') | Out-Null
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    Copy-Item -LiteralPath $dlg.FileName -Destination $SecretFile -Force
    Remove-Item $TokenFile -ErrorAction SilentlyContinue
    try { $null = Get-AccessToken; Set-Status 'YouTube is gekoppeld.' } catch { Set-Status ('Koppelen mislukt: ' + $_.Exception.Message) }
})

$btnFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Kies de map "Clips voor socials"'
    $dlg.SelectedPath = $script:Cfg.ClipsRoot
    if ($dlg.ShowDialog() -eq 'OK') { $script:Cfg.ClipsRoot = $dlg.SelectedPath; Save-Json $ConfigFile $script:Cfg; Refresh-List }
})

$form.Add_Shown({ Refresh-List })
$form.Add_FormClosing({ if ($script:Job) { Stop-Job $script:Job -ErrorAction SilentlyContinue } })
[void]$form.ShowDialog()
