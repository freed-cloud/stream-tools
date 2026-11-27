# Clip-poster voor playingparentsnl (versie 4)
#
# Wat hij doet:
# - Maakt zelf een wachtrij van alle clips die klaar zijn om te posten:
#     * Bureaublad\Clips voor socials\Vandaag posten   (met .txt: YOUTUBE-TITEL / TEKST)
#     * Bureaublad\Clips voor socials\Replay ... - staand.mp4  (met "- tekst.txt")
#   De titel komt uit de .txt, anders uit de naam in Videos\AI-clips\<game>, anders uit de tekst.
# - Controleert de volgorde (oud naar nieuw per game), dubbele clips, ontbrekende teksten,
#   en GTA-clips van de stream met echo die nog muziek nodig hebben (die worden overgeslagen).
# - Post om en om GTA 6 en Arma Reforger (andere games, zoals Fall Guys, schuiven mee in de rij).
# - Eén knop "Post volgende": uploadt naar YouTube en zet TikTok klaar.
# - Automatisch posten: een Windows-taak die op vaste tijden de volgende clip op YouTube zet,
#   ook als dit venster dicht is. TikTok blijft handwerk (TikTok laat geen automatisch posten toe
#   zonder goedgekeurde app); de clips die nog naar TikTok moeten staan in een eigen lijst.
# - Klaar op YouTube en TikTok: video en tekst gaan naar de map "Gepost". Er wordt niets verwijderd.
# Instagram zit er bewust niet in: dat post Freddy apart met de hand, anders blokkeert Instagram hem.
# Werkt met Windows PowerShell 5.1 (standaard in Windows).
#
# Opstarten zonder venster (voor de Windows-taak):  ClipPoster.ps1 -Auto
# Alleen kijken wat er gepost zou worden:              ClipPoster.ps1 -Auto -Proef

param([switch]$Auto, [switch]$Proef, [switch]$GeenVenster)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$script:HasGui = -not ($Auto -or $GeenVenster)
if ($script:HasGui) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
# Onverwachte fout? Laat hem zien (venster) of schrijf hem in het logboek (automatisch), in plaats van stil te stoppen.
trap {
    $m = "Er ging iets mis: $($_.Exception.Message) (regel $($_.InvocationInfo.ScriptLineNumber))"
    if ($script:HasGui) { [System.Windows.Forms.MessageBox]::Show($m, 'Fout') | Out-Null }
    else { try { Write-Log $m } catch { Write-Output $m } }
    break
}
Add-Type -AssemblyName System.Web

# ---------------------------------------------------------------- mappen
# (CLIPPOSTER_TESTROOT is alleen voor testen: dan worden alle mappen daaronder gezocht.)
if ($env:CLIPPOSTER_TESTROOT) {
    $Desktop  = Join-Path $env:CLIPPOSTER_TESTROOT 'Desktop'
    $VideosDir = Join-Path $env:CLIPPOSTER_TESTROOT 'Videos'
    $AppDir   = Join-Path $env:CLIPPOSTER_TESTROOT 'AppData\ClipPoster'
} else {
    $Desktop  = [Environment]::GetFolderPath('Desktop')
    $VideosDir = [Environment]::GetFolderPath('MyVideos')
    $AppDir   = Join-Path $env:APPDATA 'ClipPoster'
}
$SocialsDir = Join-Path $Desktop 'Clips voor socials'
$VandaagDir = Join-Path $SocialsDir 'Vandaag posten'
$GepostDir  = Join-Path $SocialsDir 'Gepost'
$AiDir      = Join-Path $VideosDir 'AI-clips'
$MuziekDir  = Join-Path $SocialsDir 'Muziek'
$InstaDir   = Join-Path $SocialsDir 'Instagram posten'
$ConfigFile = Join-Path $AppDir 'config.json'
$SecretFile = Join-Path $AppDir 'client_secret.json'
$TokenFile  = Join-Path $AppDir 'token.dat'
$StatusFile = Join-Path $AppDir 'gepost-v4.json'
$LogFile    = Join-Path $AppDir 'log.txt'
$TaskName   = 'Clip-poster automatisch'
if (-not (Test-Path -LiteralPath $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }

function Write-Log([string]$t) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    if (-not $script:HasGui) { Write-Host $line }
}

function Load-Json($path, $default) {
    if (Test-Path -LiteralPath $path) { try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    return $default
}
# Veilig opslaan: eerst naar een tijdelijk bestand, dan in één keer vervangen (met reservekopie .bak).
# Valt de stroom uit tijdens het opslaan, dan blijft het oude bestand heel.
function Save-Json($path, $obj) {
    $tmp = $path + '.tmp'
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, $path + '.bak') }
    else { Move-Item -LiteralPath $tmp -Destination $path }
}
function Set-Prop($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# ---------------------------------------------------------------- instellingen
$DefaultCfg = [pscustomobject]@{
    Versie        = 4
    Privacy       = 'public'
    # Vaste posttijden voor automatisch posten (4 per dag). Niet precies op het hele uur: minder druk bij YouTube.
    Tijden        = @('12:07', '16:04', '19:06', '21:03')
    # Om en om posten in deze volgorde. Andere games schuiven er achteraan bij.
    Rotatie       = @('GTA 6', 'Arma Reforger')
    # Streams met echo: GTA-clips van deze datum alleen posten als er muziek onder zit (map "Vandaag posten").
    EchoDatums    = @('2026-11-19')
    # Het YouTube-kanaal van playingparentsnl. Gaat een upload naar een ander kanaal, dan stopt automatisch posten.
    KanaalId      = 'UC0EU7Am-oiUnpg_yv9FHJkQ'
    LaatsteGame   = ''
    # Aantal posts uit de hoofdrotatie sinds de laatste "andere" game (bijv. Fall Guys).
    SindsExtra    = 0
    # Regel die onder elke YouTube-beschrijving komt.
    TwitchRegel   = 'Live op Twitch: https://twitch.tv/playingparentsnl'
    # Pushmeldingen op de telefoon via de gratis app ntfy (onderwerp wordt bij de eerste start gemaakt).
    NtfyTopic     = ''
    # Muziek onder GTA-clips met echo: volume van het spelgeluid en van de muziek.
    GameVolume    = 0.35
    MuziekVolume  = 0.85
    MuziekIndex   = 0
    # Zoveel GTA-clips met muziek wil de taak minstens klaar hebben staan; anders maakt hij er zelf bij.
    MinGtaKlaar   = 3
    # Laatst voorgestelde TikTok-inplantijd.
    TikTokLaatsteSlot = ''
    AutoGepauzeerd = $false
    AutoReden     = ''
}
$script:Cfg = Load-Json $ConfigFile $null
if (-not $script:Cfg -or -not ($script:Cfg.PSObject.Properties.Name -contains 'Versie') -or [int]$script:Cfg.Versie -lt 4) {
    $old = $script:Cfg
    $script:Cfg = $DefaultCfg
    if ($old -and ($old.PSObject.Properties.Name -contains 'Privacy') -and $old.Privacy) { $script:Cfg.Privacy = [string]$old.Privacy }
    Save-Json $ConfigFile $script:Cfg
}
function Complete-Cfg { foreach ($p in $DefaultCfg.PSObject.Properties) { if (-not ($script:Cfg.PSObject.Properties.Name -contains $p.Name)) { Set-Prop $script:Cfg $p.Name $p.Value } } }
Complete-Cfg
function Save-Cfg { Save-Json $ConfigFile $script:Cfg }
if (-not $script:Cfg.NtfyTopic) {
    $chars = 'abcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
    $rnd = New-Object byte[] 12; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
    $script:Cfg.NtfyTopic = 'playingparentsnl-' + (-join ($rnd | ForEach-Object { $chars[$_ % $chars.Length] }))
    Save-Cfg
}

$script:PhoneLog = @()
# Pushmelding naar de telefoon (app "ntfy", abonneer op het onderwerp uit de knop "Telefoon").
# Er gaan alleen korte meldingen heen (titel van de clip, fout), geen inloggegevens.
function Send-PhoneCore([string]$title, [string]$msg, [string]$prio = 'default') {
    if (-not $script:Cfg.NtfyTopic) { return $false }
    if ($env:CLIPPOSTER_TESTROOT) { $script:PhoneLog += ,('{0}: {1}' -f $title, $msg); return $true }   # testen: niet echt versturen
    try {
        $t = ($title -replace '[^\x20-\x7E]', '')   # kopteksten mogen alleen gewone tekens bevatten
        Invoke-RestMethod -Method Post -Uri ('https://ntfy.sh/' + $script:Cfg.NtfyTopic) -Body ([Text.Encoding]::UTF8.GetBytes($msg)) `
            -Headers @{ Title = $t; Priority = $prio; Tags = 'clapper' } -ContentType 'text/plain; charset=utf-8' -TimeoutSec 15 | Out-Null
        return $true
    } catch { return $false }
}
# Opnieuw inlezen: het venster en de automatische taak kunnen allebei iets veranderd hebben.
function Reload-Cfg {
    $c = Load-Json $ConfigFile $null
    if ($c -and ($c.PSObject.Properties.Name -contains 'Versie') -and [int]$c.Versie -ge 4) { $script:Cfg = $c; Complete-Cfg }
}

# ---------------------------------------------------------------- wat al gepost is (per moment uit de stream)
# Momenten die al vóór versie 4 op YouTube stonden (handmatig of met de oude versie gepost).
$AlEerderGepost = @(
    '2026-11-08 20-14-16',      # Wachten in de rij... positie 15
    '2026-11-08 22-14-12',      # Papa verdedigt het veldhospitaal
    '2026-11-19 16-47-23 m02',  # Roadtrip naar de tolpoort
    '2026-11-19 16-47-23 m04',  # Kroegavond in GTA 6
    '2026-11-19 16-47-23 m05',  # Poolen in GTA 6
    '2026-11-19 16-47-23 m06'   # Nachtwandeling op het strand
)
# De status wordt steeds vers uit het bestand gelezen (Reload-State), vlak voordat iets wordt bekeken
# of veranderd. Zo kunnen het venster en de automatische taak elkaars werk niet overschrijven.
function Load-Status {
    foreach ($p in @($StatusFile, ($StatusFile + '.bak'))) {
        if (Test-Path -LiteralPath $p) { try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    }
    if (Test-Path -LiteralPath $StatusFile) { throw 'Het bestand met geposte clips (gepost-v4.json) is onleesbaar. Uit veiligheid wordt er niets gepost.' }
    return $null
}
function Reload-State {
    $script:Done = @{}
    $saved = Load-Status
    if ($saved) { foreach ($p in $saved.PSObject.Properties) { $script:Done[$p.Name] = $p.Value } }
    foreach ($k in $AlEerderGepost) {
        if (-not $script:Done.ContainsKey($k)) { $script:Done[$k] = [pscustomobject]@{ youtube = 'al eerder gepost'; kanaal = ''; tiktok = $true; datum = ''; verkeerd = '' } }
    }
}
Reload-State
function Save-Status {
    $o = New-Object psobject
    foreach ($k in ($script:Done.Keys | Sort-Object)) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $script:Done[$k] }
    Save-Json $StatusFile $o
}
function Get-State([string]$key) {
    if (-not $script:Done.ContainsKey($key)) { $script:Done[$key] = [pscustomobject]@{ youtube = ''; kanaal = ''; tiktok = $false; datum = ''; verkeerd = ''; fouten = 0 } }
    $s = $script:Done[$key]
    foreach ($n in 'youtube', 'kanaal', 'tiktok', 'datum', 'verkeerd', 'fouten', 'muziekFouten') {
        if (-not ($s.PSObject.Properties.Name -contains $n)) { Set-Prop $s $n $(if ($n -eq 'tiktok') { $false } elseif ($n -like '*outen') { 0 } else { '' }) }
    }
    return $s
}

# Slot: er kan maar één upload tegelijk lopen (venster of automatische taak).
$LockFile = Join-Path $AppDir 'upload.lock'
function Enter-UploadLock {
    if (Test-Path -LiteralPath $LockFile) {
        $age = (Get-Date) - (Get-Item -LiteralPath $LockFile).LastWriteTime
        if ($age.TotalMinutes -lt 60) { return $false }   # ouder dan een uur: vastgelopen, opnieuw pakken
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }
    try {
        $fs = [IO.File]::Open($LockFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        $b = [Text.Encoding]::UTF8.GetBytes(("{0} {1}" -f $PID, (Get-Date -Format s)))
        $fs.Write($b, 0, $b.Length); $fs.Close()
        return $true
    } catch { return $false }
}
function Exit-UploadLock { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue }

# Geheimen (de inlogsleutel van YouTube) worden versleuteld met Windows (DPAPI).
function Protect-Text([string]$plain) { ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString }
function Unprotect-Text([string]$enc) {
    $sec = ConvertTo-SecureString $enc
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Send-Phone([string]$title, [string]$msg, [string]$prio = 'default') { [void](Send-PhoneCore $title $msg $prio) }

# ---------------------------------------------------------------- clips herkennen
# Sleutel van een moment: "Replay 2026-11-19 16-47-23 moment 15" -> "2026-11-19 16-47-23 m15"
function Get-MomentKey([string]$s) {
    if ($s -match 'Replay (\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2})(?: moment (\d+))?') {
        if ($Matches[2]) { return ('{0} m{1:D2}' -f $Matches[1], [int]$Matches[2]) }
        return $Matches[1]
    }
    return ''
}

# Titel uit een bestandsnaam: zonder volgnummer en zonder "- MUZIEK" / "- staand" / "- tekst".
function Get-CleanTitle([string]$base) {
    $t = $base -replace '^\d+\s*-\s*', ''
    for ($i = 0; $i -lt 3; $i++) { $t = $t -replace '\s*-\s*(MUZIEK|staand|tekst)\s*$', '' }
    return $t.Trim()
}

function Get-GameFromText([string]$text) {
    if ($text -match '(?i)#armareforger\b|#arma\b') { return 'Arma Reforger' }
    if ($text -match '(?i)#gta6\b|#gtavi\b') { return 'GTA 6' }
    if ($text -match '(?i)#fallguys\b') { return 'Fall Guys' }
    return ''
}

# Korte titel uit de eerste zin van de tekst (zonder emoji en hashtags), met de game erachter.
function Get-TitleFromText([string]$text, [string]$game) {
    $first = ''
    foreach ($l in ($text -split "`r?`n")) { $c = ($l -replace '#\S+', '').Trim(); if ($c) { $first = $c; break } }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $first.ToCharArray()) {
        $code = [int]$ch
        if ([char]::IsSurrogate($ch) -or ($code -ge 0x2190 -and $code -le 0x2BFF) -or $code -eq 0xFE0F -or $code -eq 0x200D) { [void]$sb.Append([char]0x1F); continue }
        [void]$sb.Append($ch)
    }
    # Een emoji tussen twee zinnen ("struik [emoji] Niemand ziet ons") werkt als zinseinde.
    $t = $sb.ToString() -replace ('([^.!?\s])\s*' + [char]0x1F + '[\s' + [char]0x1F + ']*(?=[A-Z])'), '$1. '
    $t = ($t -replace [string][char]0x1F, ' ' -replace '\s+', ' ').Trim()
    # Aanhalingstekens (ook de schuine varianten, als tekencode) aan begin en eind weghalen.
    $q = "'" + '"' + [char]0x2018 + [char]0x2019 + [char]0x201C + [char]0x201D
    $t = $t.TrimStart($q.ToCharArray())
    $ell = [string][char]0x2026
    $t = $t.Replace($ell, '...')
    # Zinnen tot er minstens 25 tekens zijn ("..." hoort bij de grap, dus daar loopt de zin door).
    $zinnen = [regex]::Matches($t, '.+?(?:(?<!\.)[.!?](?!\.)[' + [regex]::Escape($q) + ']?(?=\s|$)|$)')
    $res = ''
    foreach ($m in $zinnen) {
        $z = $m.Value.Trim(); if (-not $z) { continue }
        $kandidaat = ($res + ' ' + $z).Trim()
        if ($res -and $kandidaat.Length -gt 70) { break }
        $res = $kandidaat
        if ($res.Length -ge 25) { break }
    }
    if ($res) { $t = $res }
    # Te lang: afkappen bij een heel woord, met "..." erachter.
    if ($t.Length -gt 70) {
        # Liefst afkappen na "..." of bij een komma, dan pas bij een heel woord.
        $head = $t.Substring(0, 70)
        $e3 = $head.LastIndexOf('...')
        $cm = $head.LastIndexOf(', ')
        if ($e3 -ge 20) { $t = $head.Substring(0, $e3 + 3) }
        elseif ($cm -ge 25) { $t = $head.Substring(0, $cm) }
    }
    if ($t.Length -gt 70) {
        $cut = $t.Substring(0, 70)
        $sp = $cut.LastIndexOf(' ')
        if ($sp -gt 30) { $cut = $cut.Substring(0, $sp) }
        $t = $cut.TrimEnd(' ,;:-'.ToCharArray()) + '...'
    }
    # Een losse punt aan het eind weg (vraag- en uitroeptekens en "..." blijven staan).
    if ($t -match '[^.]\.$') { $t = $t.Substring(0, $t.Length - 1) }
    $t = $t.Trim((' -,:;' + [char]0x2013 + $q).ToCharArray())
    if (-not $t) { $t = 'Clip' }
    if ($game) { $t = '{0} | {1}' -f $t, $game }
    return $t
}

# Een .txt in het vaste formaat (YOUTUBE-TITEL: ... / TEKST (...): ... / --- voetnoot) opsplitsen.
function Split-ClipTxt([string]$raw) {
    $res = @{ Title = ''; Text = ''; Origineel = ''; Structured = $false }
    if ($raw -match '(?im)^\s*Origineel\s*:\s*(.+?)\s*$') { $res.Origineel = $Matches[1] }
    if ($raw -notmatch '(?im)^\s*YOUTUBE-TITEL\s*:') { $res.Text = $raw.Trim(); return $res }
    $res.Structured = $true
    $title = ''; $body = New-Object System.Collections.Generic.List[string]; $mode = ''
    foreach ($l in ($raw -split "`r?`n")) {
        if ($l -match '^\s*YOUTUBE-TITEL\s*:\s*(.*)$') { $mode = 'titel'; if ($Matches[1].Trim()) { $title = $Matches[1].Trim() }; continue }
        if ($l -match '^\s*TEKST\b.*:\s*$') { $mode = 'tekst'; continue }
        if ($l -match '^\s*---\s*$') { break }
        if ($mode -eq 'titel' -and -not $title -and $l.Trim()) { $title = $l.Trim(); continue }
        if ($mode -eq 'tekst') { $body.Add($l) }
    }
    $res.Title = $title
    $res.Text = (($body -join "`r`n").Trim())
    return $res
}

function Read-Text([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)).Trim([char]0xFEFF).Trim()
}

# Titels uit Videos\AI-clips\<game>\NN - Titel.mp4, gekoppeld aan het moment via de bestandsgrootte
# van het origineel (Videos\AI-clips\Replay ... moment NN.mp4). Kleine verschillen (< 0,1%) mogen.
function Get-AiTitleIndex {
    $index = @{}
    if (-not (Test-Path -LiteralPath $AiDir)) { return $index }
    $named = New-Object System.Collections.Generic.List[object]
    foreach ($d in (Get-ChildItem -LiteralPath $AiDir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -like '_*') { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d.FullName -Filter *.mp4 -File -ErrorAction SilentlyContinue)) {
            $named.Add([pscustomobject]@{ Size = [double]$f.Length; Title = (Get-CleanTitle $f.BaseName); Game = $d.Name; Used = $false })
        }
    }
    $origs = @()
    foreach ($dir in @($AiDir, (Join-Path $AiDir '_Originelen'))) {
        $origs += @(Get-ChildItem -LiteralPath $dir -Filter 'Replay *.mp4' -File -ErrorAction SilentlyContinue)
    }
    # Eerst de beste (kleinste verschil) koppelingen, zodat elke titel maar één keer gebruikt wordt.
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($o in $origs) {
        $key = Get-MomentKey $o.BaseName; if (-not $key) { continue }
        foreach ($n in $named) {
            $diff = [math]::Abs($n.Size - [double]$o.Length) / [math]::Max(1, [double]$o.Length)
            if ($diff -le 0.001) { $pairs.Add([pscustomobject]@{ Key = $key; N = $n; Diff = $diff }) }
        }
    }
    foreach ($p in ($pairs | Sort-Object Diff)) {
        if ($index.ContainsKey($p.Key) -or $p.N.Used) { continue }
        $p.N.Used = $true
        $index[$p.Key] = @{ Title = $p.N.Title; Game = $p.N.Game }
    }
    return $index
}

function New-Clip {
    return [pscustomobject]@{
        Key = ''; Game = ''; Title = ''; Text = ''; Mp4 = ''; Txt = ''; Bron = ''; Nr = 0
        Probleem = ''; MuziekNodig = $false; Gepost = $false; TikTok = $false; YouTubeId = ''
    }
}

# Alle clips die er nu klaarstaan (nog niet in "Gepost").
function Get-AllClips {
    Reload-State
    Reload-Cfg
    $list = New-Object System.Collections.Generic.List[object]
    $keys = @{}
    $ai = Get-AiTitleIndex
    $echo = @($script:Cfg.EchoDatums)

    # 1. Vandaag posten (deze hebben voorrang: daar zit muziek onder en een eigen titel)
    foreach ($f in (Get-ChildItem -LiteralPath $VandaagDir -Filter *.mp4 -File -ErrorAction SilentlyContinue)) {
        $c = New-Clip
        $c.Mp4 = $f.FullName; $c.Bron = 'Vandaag posten'
        if ($f.BaseName -match '^(\d+)') { $c.Nr = [int]$Matches[1] }
        $c.Txt = Join-Path $f.DirectoryName ($f.BaseName + '.txt')
        $raw = Read-Text $c.Txt
        if ($null -eq $raw) { $c.Probleem = 'geen .txt met tekst'; $raw = '' }
        $parts = Split-ClipTxt $raw
        $c.Text = $parts.Text
        $c.Key = Get-MomentKey $parts.Origineel
        if (-not $c.Key) { $c.Key = Get-MomentKey $f.BaseName }
        if (-not $c.Key) { $c.Key = 'vandaag:' + $f.BaseName; $c.Probleem = 'geen regel "Origineel: Replay ..." in de .txt (anders kan hij dubbel gepost worden)' }
        $c.Game = Get-GameFromText $c.Text
        if (-not $c.Game) { if ($f.BaseName -match '(?i)arma') { $c.Game = 'Arma Reforger' } elseif ($f.BaseName -match '(?i)gta') { $c.Game = 'GTA 6' } }
        $c.Title = $parts.Title
        if (-not $c.Title -and $ai.ContainsKey($c.Key)) { $c.Title = '{0} | {1}' -f $ai[$c.Key].Title, $ai[$c.Key].Game }
        if (-not $c.Title) { $c.Title = Get-CleanTitle $f.BaseName }
        if (-not $c.Text -and -not $c.Probleem) { $c.Probleem = 'tekst is leeg' }
        if (-not $c.Game -and -not $c.Probleem) { $c.Probleem = 'game onbekend (geen #gta6 of #armareforger in de tekst)' }
        $list.Add($c); $keys[$c.Key] = $true
    }

    # 2. Staande clips in Clips voor socials
    foreach ($f in (Get-ChildItem -LiteralPath $SocialsDir -Filter 'Replay * - staand.mp4' -File -ErrorAction SilentlyContinue)) {
        $c = New-Clip
        $c.Mp4 = $f.FullName; $c.Bron = 'Clips voor socials'
        $c.Key = Get-MomentKey $f.BaseName
        if (-not $c.Key -or $keys.ContainsKey($c.Key)) { continue }   # dubbel: de versie in Vandaag posten wint
        $c.Txt = Join-Path $f.DirectoryName (($f.BaseName -replace '\s*-\s*staand$', '') + ' - tekst.txt')
        $raw = Read-Text $c.Txt
        if ($null -eq $raw) { $c.Probleem = 'geen tekst.txt'; $raw = '' }
        $c.Text = (Split-ClipTxt $raw).Text
        $c.Game = Get-GameFromText $c.Text
        if (-not $c.Game -and $ai.ContainsKey($c.Key)) { $c.Game = $ai[$c.Key].Game }
        # De titel komt uit dezelfde tekst als de beschrijving, zodat ze altijd bij elkaar passen.
        # Alleen als er geen tekst is, wordt de naam uit Videos\AI-clips gebruikt.
        if ($c.Text) { $c.Title = Get-TitleFromText $c.Text $c.Game }
        elseif ($ai.ContainsKey($c.Key)) { $c.Title = '{0} | {1}' -f $ai[$c.Key].Title, $c.Game }
        if (-not $c.Game -and -not $c.Probleem) { $c.Probleem = 'game onbekend (geen #gta6 of #armareforger in de tekst)' }
        if (-not $c.Text -and -not $c.Probleem) { $c.Probleem = 'tekst is leeg' }
        $datum = $c.Key.Substring(0, [math]::Min(10, $c.Key.Length))
        # Echo-stream: GTA-clips, en voor de zekerheid ook clips waarvan de game niet uit de tekst blijkt.
        if ($echo -contains $datum -and ($c.Game -eq 'GTA 6' -or -not (Get-GameFromText $c.Text))) { $c.MuziekNodig = $true }
        $list.Add($c); $keys[$c.Key] = $true
    }

    foreach ($c in $list) {
        $s = Get-State $c.Key
        $c.YouTubeId = [string]$s.youtube
        $c.Gepost = [bool]([string]$s.youtube)
        if ([int]$s.fouten -ge 3 -and -not $c.Probleem -and -not $c.Gepost) { $c.Probleem = 'upload 3 keer mislukt' }
        $c.TikTok = [bool]$s.tiktok
        if ($c.Title.Length -gt 100) { $c.Title = $c.Title.Substring(0, 100).Trim() }
    }
    return $list.ToArray()
}

$script:ExtraElke = 6
function Get-SortKey($c) { return ('{0}|{1:D4}' -f $c.Key, $c.Nr) }

# De wachtrij voor YouTube: oud naar nieuw per game, om en om volgens de rotatie.
function Get-Queue($all) {
    $ok = @($all | Where-Object { -not $_.Gepost -and -not $_.Probleem -and -not $_.MuziekNodig })
    $perGame = [ordered]@{}
    foreach ($c in ($ok | Sort-Object { Get-SortKey $_ })) {
        if (-not $perGame.Contains($c.Game)) { $perGame[$c.Game] = New-Object System.Collections.Generic.Queue[object] }
        $perGame[$c.Game].Enqueue($c)
    }
    # Hoofdrotatie (GTA 6 en Arma Reforger om en om). Andere games (bijv. Fall Guys) komen
    # er af en toe tussen: één na elke $ExtraElke posts uit de hoofdrotatie.
    $ExtraElke = $script:ExtraElke
    $rot = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($script:Cfg.Rotatie)) { if ($perGame.Contains($g)) { $rot.Add($g) } }
    $extra = New-Object System.Collections.Generic.Queue[object]
    foreach ($g in $perGame.Keys) { if (-not $rot.Contains($g)) { foreach ($c in $perGame[$g]) { $extra.Enqueue($c) } } }
    $main = New-Object System.Collections.Generic.List[object]
    if ($rot.Count -gt 0) {
        # Begin met de game na de laatst geposte, zodat het ook over dagen heen om en om blijft.
        $start = 0
        $last = [string]$script:Cfg.LaatsteGame
        if ($last -and $rot.Contains($last)) { $start = ($rot.IndexOf($last) + 1) % $rot.Count }
        $total = 0; foreach ($g in $rot) { $total += $perGame[$g].Count }
        $i = $start
        while ($main.Count -lt $total) {
            $g = $rot[$i % $rot.Count]
            if ($perGame[$g].Count -gt 0) { $main.Add($perGame[$g].Dequeue()) }
            $i++
        }
    }
    $out = New-Object System.Collections.Generic.List[object]
    $n = [int]$script:Cfg.SindsExtra
    if ($n -ge $ExtraElke -and $extra.Count -gt 0) { $out.Add($extra.Dequeue()); $n = 0 }
    foreach ($c in $main) {
        $out.Add($c); $n++
        if ($n % $ExtraElke -eq 0 -and $extra.Count -gt 0) { $out.Add($extra.Dequeue()) }
    }
    while ($extra.Count -gt 0) { $out.Add($extra.Dequeue()) }
    return $out.ToArray()
}

# Controle: klopt de volgorde, zijn er dubbele of kapotte clips?
function Get-Checks($all) {
    $msgs = New-Object System.Collections.Generic.List[string]
    # Volgorde in Vandaag posten: oplopende nummers moeten ook oud-naar-nieuw zijn.
    $v = @($all | Where-Object { $_.Bron -eq 'Vandaag posten' -and $_.Nr -gt 0 } | Sort-Object Nr)
    for ($i = 1; $i -lt $v.Count; $i++) {
        if ($v[$i].Nr -eq $v[$i - 1].Nr) { $msgs.Add(('Vandaag posten: nummer {0} komt twee keer voor.' -f $v[$i].Nr)) }
        elseif ($v[$i].Game -eq $v[$i - 1].Game -and $v[$i].Key -notlike 'vandaag:*' -and $v[$i - 1].Key -notlike 'vandaag:*' -and $v[$i].Key -lt $v[$i - 1].Key) {
            $msgs.Add(('Vandaag posten: nummer {0} is eerder opgenomen dan nummer {1}. De Clip-poster post ze in de goede volgorde.' -f $v[$i].Nr, $v[$i - 1].Nr))
        }
    }
    foreach ($g in (@($all | Where-Object { $_.Bron -eq 'Vandaag posten' }) | Group-Object Key | Where-Object { $_.Count -gt 1 })) {
        $msgs.Add(('Vandaag posten: hetzelfde moment staat er {0} keer in ({1}). Haal er een weg; er wordt er maar één gepost.' -f $g.Count, (($g.Group | ForEach-Object { Split-Path $_.Mp4 -Leaf }) -join ', ')))
    }
    foreach ($c in ($all | Where-Object { $_.Probleem })) { $msgs.Add(('Overgeslagen: {0} ({1})' -f (Split-Path $c.Mp4 -Leaf), $c.Probleem)) }
    $m = @($all | Where-Object { $_.MuziekNodig -and -not $_.Gepost })
    if ($m.Count) { $msgs.Add(('{0} GTA-clips van een stream met echo worden overgeslagen tot er muziek onder zit (zet ze met muziek in Vandaag posten).' -f $m.Count)) }
    $per = @{}
    foreach ($c in @(Get-Queue $all)) { if (-not $per.ContainsKey($c.Game)) { $per[$c.Game] = 0 }; $per[$c.Game]++ }
    $perDag = [math]::Max(1, @($script:Cfg.Tijden).Count)
    foreach ($g in @($script:Cfg.Rotatie)) {
        $n = 0; if ($per.ContainsKey($g)) { $n = $per[$g] }
        $dagen = [math]::Floor($n * @($script:Cfg.Rotatie).Count / $perDag)
        if ($n -eq 0) { $msgs.Add(('Er staan geen {0}-clips meer klaar. Er wordt nu alleen de andere game gepost.' -f $g)) }
        elseif ($dagen -le 3) { $msgs.Add(('Nog maar {0} {1}-clips klaar (ongeveer {2} dagen). Zet op tijd nieuwe clips klaar.' -f $n, $g, [math]::Max(1, $dagen))) }
    }
    $klaar = @($all | Where-Object { $_.Gepost -and $_.TikTok })
    if ($klaar.Count) { $msgs.Add(('{0} clips staan al op YouTube en TikTok. Klik "Opruimen" om ze naar de map Gepost te verplaatsen.' -f $klaar.Count)) }
    if (-not $msgs.Count) { $msgs.Add('Alles in orde: geen dubbele clips, volgorde klopt, alle teksten aanwezig.') }
    return $msgs.ToArray()
}

# ---------------------------------------------------------------- inloggen bij YouTube (OAuth met PKCE)
function ConvertTo-Base64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function New-RandomString([int]$bytes) {
    $buf = New-Object byte[] $bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return (ConvertTo-Base64Url $buf)
}

function Get-ClientSecret {
    if (-not (Test-Path -LiteralPath $SecretFile)) { throw 'Nog geen client_secret.json. Klik op "YouTube instellen".' }
    $j = Get-Content -LiteralPath $SecretFile -Raw | ConvertFrom-Json
    if ($j.installed) { return $j.installed }
    throw 'client_secret.json is niet van het type "Desktop-app". Maak in Google Cloud een OAuth-client van het type Desktop-app.'
}

function Invoke-Login($client) {
    if (-not $script:HasGui) { throw 'Opnieuw inloggen nodig: open de Clip-poster en klik op "YouTube instellen".' }
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
        scope = 'https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly'; code_challenge = $challenge
        code_challenge_method = 'S256'; access_type = 'offline'; prompt = 'consent select_account'; state = $state
    }
    $qs = ($q.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
    Start-Process ('https://accounts.google.com/o/oauth2/v2/auth?' + $qs)
    Set-Status 'Log in bij Google in je browser. Kies het kanaal playingparentsnl en geef toestemming...'
    $first = $null
    $end = [DateTime]::UtcNow.AddMinutes(5)
    try {
        # Browsers openen soms een lege verbinding vooraf; die slaan we over tot het echte antwoord van Google binnenkomt.
        while (-not $first) {
            $acc = $tcp.AcceptTcpClientAsync()
            while (-not $acc.Wait(200)) {
                [System.Windows.Forms.Application]::DoEvents()
                if ([DateTime]::UtcNow -gt $end) { throw 'Inloggen duurde te lang (5 minuten). Probeer het opnieuw.' }
            }
            $client2 = $acc.Result
            $client2.ReceiveTimeout = 3000
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
    if ([string]$tok.scope -notmatch 'youtube\.upload') { throw 'Je hebt bij Google het vinkje voor "video''s uploaden" uitgezet. Klik opnieuw op YouTube instellen en laat alle vinkjes aan staan.' }
    if ($tok.refresh_token) { Set-Content -LiteralPath $TokenFile -Value (Protect-Text $tok.refresh_token) }
    return $tok.access_token
}

function Get-AccessToken {
    $client = Get-ClientSecret
    if (Test-Path -LiteralPath $TokenFile) {
        try {
            $refresh = Unprotect-Text (Get-Content -LiteralPath $TokenFile -Raw).Trim()
            $tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
                client_id = $client.client_id; client_secret = $client.client_secret
                refresh_token = $refresh; grant_type = 'refresh_token'
            }
            return $tok.access_token
        } catch {
            # Alleen bij een echte afwijzing de inlog weggooien (niet bij geen internet).
            $msg = [string]$_.ErrorDetails.Message
            if ($msg -match 'invalid_grant|unauthorized_client|invalid_client') { Remove-Item -LiteralPath $TokenFile -ErrorAction SilentlyContinue }
            else { throw ('Geen verbinding met Google: ' + $_.Exception.Message) }
        }
    }
    return (Invoke-Login $client)
}

# ---------------------------------------------------------------- uploaden
$UploadJob = {
    param($token, $path, $metaJson)
    $ProgressPreference = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        $size = (Get-Item -LiteralPath $path).Length
        $init = Invoke-WebRequest -UseBasicParsing -Method Post `
            -Uri 'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status' `
            -Headers @{ Authorization = "Bearer $token"; 'X-Upload-Content-Type' = 'video/mp4'; 'X-Upload-Content-Length' = "$size" } `
            -ContentType 'application/json; charset=UTF-8' -Body ([Text.Encoding]::UTF8.GetBytes($metaJson))
        $location = [string]$init.Headers['Location']
        $video = Invoke-RestMethod -Method Put -Uri $location -InFile $path -ContentType 'video/mp4' -Headers @{ Authorization = "Bearer $token" }
        "OK|$($video.id)|$($video.status.privacyStatus)|$($video.snippet.channelId)|$($video.snippet.channelTitle)"
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        "FOUT|$($detail -replace '[\r\n|]+', ' ')"
    }
}

function Add-TwitchLine([string]$text) {
    $r = [string]$script:Cfg.TwitchRegel
    if (-not $r -or $text -match 'twitch\.tv/') { return $text }
    return ($text.TrimEnd() + "`r`n`r`n" + $r)
}
function New-UploadMeta([string]$title, [string]$text, [string]$privacy) {
    $text = Add-TwitchLine $text
    $tags = @([regex]::Matches($text, '#(\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 15)
    $title = ($title -replace '[<>]', '').Trim()
    if ($title.Length -gt 100) { $title = $title.Substring(0, 100) }
    return (@{
        snippet = @{ title = $title; description = ($text -replace '[<>]', ''); categoryId = '20'; tags = $tags }
        status  = @{ privacyStatus = $privacy; selfDeclaredMadeForKids = $false }
    } | ConvertTo-Json -Depth 5 -Compress)
}

# Verwerk het antwoord van een upload. Geeft een tekst terug voor de status.
function Complete-Upload([string]$key, [string]$game, [string]$out, [string]$wantPrivacy = 'public') {
    if ($out -notlike 'OK|*') {
        $msg = 'Upload mislukt: ' + ($out -replace '^FOUT\|', '')
        if ($msg -match 'quotaExceeded|uploadLimitExceeded') { $msg += ' (YouTube-limiet voor vandaag bereikt; morgen gaat het vanzelf verder.)' }
        elseif ($key) {
            # Telt mee: na 3 mislukte pogingen wordt de clip overgeslagen, zodat de rest gewoon doorgaat.
            Reload-State; $s = Get-State $key; $s.fouten = [int]$s.fouten + 1; Save-Status
        }
        Write-Log $msg
        Send-Phone 'Clip-poster: upload mislukt' $msg 'high'
        return $msg
    }
    $parts = $out.Split('|')
    Reload-State; Reload-Cfg
    $s = Get-State $key
    if ($script:Cfg.KanaalId -and $parts[3] -and $parts[3] -ne $script:Cfg.KanaalId) {
        # Verkeerd kanaal: NIET als gepost tellen, zodat de clip in de wachtrij blijft voor playingparentsnl.
        $s.verkeerd = $parts[1]; Save-Status
        $script:Cfg.AutoGepauzeerd = $true
        $script:Cfg.AutoReden = ('Upload ging naar kanaal "{0}" in plaats van playingparentsnl (video https://youtube.com/shorts/{1}). Klik op YouTube instellen en kies het goede kanaal.' -f $parts[4], $parts[1])
        Save-Cfg
        $msg = 'LET OP: ' + $script:Cfg.AutoReden + ' Posten staat op pauze.'
        Write-Log $msg
        Send-Phone 'Clip-poster: verkeerd kanaal, op pauze' $msg 'high'
        return $msg
    }
    $s.youtube = $parts[1]; $s.kanaal = $parts[3]; $s.datum = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Save-Status
    if (@($script:Cfg.Rotatie) -contains $game) { $script:Cfg.LaatsteGame = $game; $script:Cfg.SindsExtra = [int]$script:Cfg.SindsExtra + 1 }
    else { $script:Cfg.SindsExtra = 0 }
    Save-Cfg
    $msg = 'Op YouTube gezet ({0}) op kanaal "{1}": https://youtube.com/shorts/{2}' -f $parts[2], $parts[4], $parts[1]
    if ($wantPrivacy -ne 'private' -and $parts[2] -eq 'private') {
        $script:Cfg.AutoGepauzeerd = $true
        $script:Cfg.AutoReden = 'YouTube heeft de video op privé gezet (dat doet YouTube bij uploads via een niet-geverifieerde app). Zet hem in YouTube Studio op openbaar. Om dit te voorkomen moet de app bij Google geverifieerd worden.'
        Save-Cfg
        $msg += "`nLET OP: " + $script:Cfg.AutoReden + ' Posten staat op pauze.'
        Send-Phone 'Clip-poster: video op prive, op pauze' $msg 'high'
    } else {
        Send-Phone 'Clip-poster: gepost op YouTube' ('[{0}] https://youtube.com/shorts/{1}  -  zet hem ook op TikTok (TikTok-ronde).' -f $game, $parts[1]) 'low'
    }
    Write-Log $msg
    return $msg
}

# ---------------------------------------------------------------- automatisch posten (Windows-taak)
# Is het bestand klaar (niet net neergezet en niet meer in gebruik door bijv. kopiëren)?
function Test-FileReady([string]$path) {
    try {
        $fi = Get-Item -LiteralPath $path
        if ($fi.CreationTime -gt (Get-Date).AddMinutes(-3) -or $fi.LastWriteTime -gt (Get-Date).AddMinutes(-3)) { return $false }
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None); $fs.Close()
        return $true
    } catch { return $false }
}

function Invoke-AutoPost {
    Reload-Cfg
    if ($script:Cfg.AutoGepauzeerd) { Write-Log ('Automatisch posten staat op pauze: ' + $script:Cfg.AutoReden); return }
    # Bijna geen GTA-clips met muziek meer? Dan eerst twee echo-clips van muziek voorzien.
    try {
        $gtaKlaar = @(Get-Queue (Get-AllClips) | Where-Object { $_.Game -eq 'GTA 6' }).Count
        if ($gtaKlaar -lt [int]$script:Cfg.MinGtaKlaar -and -not $Proef -and (Find-Ffmpeg)) {
            $n = Invoke-MusicBatch 2
            if ($n) { Write-Log ('{0} GTA-clips van muziek voorzien.' -f $n) }
        }
    } catch { Write-Log ('Muziek toevoegen mislukt: ' + $_.Exception.Message) }
    $all = Get-AllClips
    $q = @(Get-Queue $all)
    if ($script:Cfg.AutoGepauzeerd) { Write-Log ('Automatisch posten staat op pauze: ' + $script:Cfg.AutoReden); return }
    if (-not $q.Count) {
        Write-Log 'Geen clips meer in de wachtrij. Zet nieuwe clips klaar.'
        $vandaag = Get-Date -Format 'yyyy-MM-dd'
        if ([string]$script:Cfg.LeegGemeld -ne $vandaag) { Send-Phone 'Clip-poster: wachtrij leeg' 'Er staan geen clips meer klaar om te posten. Zet nieuwe clips klaar.' 'high'; Set-Prop $script:Cfg 'LeegGemeld' $vandaag; Save-Cfg }
        return
    }
    $c = $q[0]
    if ($Proef) { Write-Log ('PROEF: zou nu posten: [{0}] {1}  ({2})' -f $c.Game, $c.Title, (Split-Path $c.Mp4 -Leaf)); return }
    if (-not (Enter-UploadLock)) { Write-Log 'Er loopt al een upload (venster of taak). Deze beurt wordt overgeslagen.'; return }
    try {
        # Vlak voor de upload nog een keer kijken of de clip intussen al gepost is.
        $all = Get-AllClips; $q = @(Get-Queue $all)
        if (-not $q.Count) { Write-Log 'Geen clips meer in de wachtrij.'; return }
        $c = $q[0]
        if (-not (Test-FileReady $c.Mp4)) { Write-Log ('Clip wordt nog gekopieerd of is in gebruik, deze beurt overgeslagen: ' + (Split-Path $c.Mp4 -Leaf)); return }
        try { $token = Get-AccessToken } catch { Write-Log ('Inloggen mislukt: ' + $_.Exception.Message); Send-Phone 'Clip-poster: inloggen mislukt' ('Automatisch posten lukt niet: ' + $_.Exception.Message) 'high'; return }
        $priv = [string]$script:Cfg.Privacy
        $meta = New-UploadMeta $c.Title $c.Text $priv
        Write-Log ('Uploaden: [{0}] {1}' -f $c.Game, $c.Title)
        $out = [string](& $UploadJob $token $c.Mp4 $meta | Select-Object -Last 1)
        [void](Complete-Upload $c.Key $c.Game $out $priv)
    } finally { Exit-UploadLock }
}

function Get-AutoTask { try { return (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop) } catch { return $null } }

function Set-AutoTask([bool]$on) {
    if (-not $on) {
        if (Get-AutoTask) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
        Write-Log 'Automatisch posten uitgezet.'
        return
    }
    $scriptPath = $PSCommandPath
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Auto' -f $scriptPath)
    $triggers = @()
    foreach ($t in @($script:Cfg.Tijden)) {
        $at = [datetime]::ParseExact(([string]$t).Trim(), [string[]]@('HH:mm', 'H:mm'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
        $triggers += New-ScheduledTaskTrigger -Daily -At $at
    }
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Description 'Zet op vaste tijden de volgende clip van playingparentsnl op YouTube.' -Force | Out-Null
    $script:Cfg.AutoGepauzeerd = $false; $script:Cfg.AutoReden = ''; Save-Cfg
    Write-Log ('Automatisch posten aangezet: ' + (@($script:Cfg.Tijden) -join ', '))
}

# Video en tekst naar de map Gepost (alleen als hij op YouTube én TikTok staat).
function Move-ToGepost($c) {
    if (-not (Test-Path -LiteralPath $GepostDir)) { New-Item -ItemType Directory -Path $GepostDir -Force | Out-Null }
    $paths = @($c.Mp4, $c.Txt)
    # Bij een clip uit Vandaag posten staat de staande versie (zonder muziek) van hetzelfde moment
    # vaak nog in Clips voor socials. Die gaat mee, zodat hij niet blijft slingeren.
    if ($c.Key -match '^(\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2})(?: m(\d+))?$') {
        $base = 'Replay ' + $Matches[1]; if ($Matches[2]) { $base += (' moment {0}' -f $Matches[2]) }
        $paths += (Join-Path $SocialsDir ($base + ' - staand.mp4'))
        $paths += (Join-Path $SocialsDir ($base + ' - tekst.txt'))
    }
    foreach ($p in ($paths | Select-Object -Unique)) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            $dest = Join-Path $GepostDir (Split-Path $p -Leaf)
            if (Test-Path -LiteralPath $dest) {
                $dest = Join-Path $GepostDir ('{0} ({1}){2}' -f [IO.Path]::GetFileNameWithoutExtension($p), (Get-Date -Format 'yyyyMMdd-HHmmss'), [IO.Path]::GetExtension($p))
            }
            Move-Item -LiteralPath $p -Destination $dest
        }
    }
}


# ---------------------------------------------------------------- muziek onder GTA-clips met echo (ffmpeg)
function Find-Ffmpeg {
    foreach ($n in 'ffmpeg.exe', 'ffmpeg') { $cmd = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($cmd) { return $cmd.Source } }
    $roots = @()
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'); $roots += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links') }
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            $f = Get-ChildItem -LiteralPath $r -Recurse -Filter 'ffmpeg.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return $null
}

# ffmpeg installeren via winget (de officiële pakketbron van Windows, pakket Gyan.FFmpeg).
function Install-Ffmpeg {
    $w = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $w) { throw 'winget ontbreekt op deze pc. Installeer "App Installer" uit de Microsoft Store en probeer het opnieuw.' }
    $p = Start-Process -FilePath $w.Source -ArgumentList 'install --id Gyan.FFmpeg -e --silent --accept-source-agreements --accept-package-agreements' -Wait -PassThru -WindowStyle Hidden
    $f = Find-Ffmpeg
    if (-not $f) { throw ('ffmpeg is niet gevonden na installatie (code {0}). Herstart de pc en probeer het opnieuw.' -f $p.ExitCode) }
    Write-Log ('ffmpeg geïnstalleerd: ' + $f)
    return $f
}

# Een extern programma (ffmpeg/ffprobe) starten. In Windows PowerShell 5.1 wordt elke regel die zo'n
# programma als waarschuwing schrijft anders als fout gezien; daarom hier tijdelijk 'Continue'.
function Invoke-Native([string]$exe, [string[]]$argList) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe @argList 2>&1
        $code = $LASTEXITCODE
        return @{ Code = $code; Out = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
    } finally { $ErrorActionPreference = $old }
}

function Find-Ffprobe([string]$ffmpeg) {
    foreach ($n in 'ffprobe.exe', 'ffprobe') { $p = Join-Path (Split-Path $ffmpeg) $n; if (Test-Path -LiteralPath $p) { return $p } }
    foreach ($n in 'ffprobe.exe', 'ffprobe') { $cmd = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($cmd) { return $cmd.Source } }
    return $null
}

function Get-MediaDuration([string]$ffmpeg, [string]$path) {
    $probe = Find-Ffprobe $ffmpeg
    if ($probe) {
        $r = Invoke-Native $probe @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', $path)
        $v = 0.0
        if ([double]::TryParse(([string]$r.Out).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
    }
    return 0.0
}

# Heeft de video een geluidsspoor? ($null = onbekend, want geen ffprobe)
function Test-HasAudio([string]$ffmpeg, [string]$path) {
    $probe = Find-Ffprobe $ffmpeg
    if (-not $probe) { return $null }
    $r = Invoke-Native $probe @('-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=index', '-of', 'csv=p=0', $path)
    return [bool](([string]$r.Out).Trim())
}

# Volgende vrije nummer voor "Vandaag posten" (kijkt ook in Gepost en Instagram posten).
function Get-NextVandaagNr {
    $max = 0
    foreach ($d in @($VandaagDir, $GepostDir, $InstaDir)) {
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter '*.mp4' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -match '^(\d+)\s*-') { $max = [math]::Max($max, [int]$Matches[1]) }
        }
    }
    return ($max + 1)
}

function Get-SafeFileName([string]$t) {
    $bad = [IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) { if ($bad -contains $ch) { [void]$sb.Append(' ') } else { [void]$sb.Append($ch) } }
    $r = ($sb.ToString() -replace '\|', '-' -replace '\s+', ' ').Trim().TrimEnd('.')
    if ($r.Length -gt 80) { $r = $r.Substring(0, 80).Trim() }
    return $r
}

function Get-OriginalName([string]$key) {
    if ($key -match '^(\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2})(?: m(\d+))?$') {
        $n = 'Replay ' + $Matches[1]; if ($Matches[2]) { $n += (' moment {0}' -f $Matches[2]) }; return $n
    }
    return $key
}

# Zet muziek onder één staande clip en zet hem met tekst in "Vandaag posten".
function Add-MusicToClip($c, [string]$ffmpeg) {
    Reload-Cfg
    $tracks = @(Get-ChildItem -LiteralPath $MuziekDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(mp3|m4a|wav)$' } | Sort-Object Name)
    if (-not $tracks.Count) { throw ('Geen muziek gevonden in ' + $MuziekDir) }
    $i = [int]$script:Cfg.MuziekIndex % $tracks.Count
    $track = $tracks[$i]
    $nr = Get-NextVandaagNr
    $game = if ($c.Game) { $c.Game } else { 'GTA 6' }
    $title = $c.Title -replace ('\s*\|\s*' + [regex]::Escape($game) + '\s*$'), ''
    $base = '{0} - {1} - {2}' -f $nr, (Get-SafeFileName $title), $game
    $out = Join-Path $VandaagDir ($base + '.mp4')
    $tmpOut = Join-Path $SocialsDir ($base + '.bezig.mp4')   # buiten Vandaag posten, zodat een half bestand nooit in de rij komt
    $gv = ([double]$script:Cfg.GameVolume).ToString([Globalization.CultureInfo]::InvariantCulture)
    $mv = ([double]$script:Cfg.MuziekVolume).ToString([Globalization.CultureInfo]::InvariantCulture)
    $dur = Get-MediaDuration $ffmpeg $c.Mp4
    $fade = ''
    if ($dur -gt 4) { $fade = (',afade=t=out:st={0}:d=1.5' -f ($dur - 1.5).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) }
    $hasAudio = Test-HasAudio $ffmpeg $c.Mp4
    $common = @('-hide_banner', '-loglevel', 'error', '-y', '-i', $c.Mp4, '-stream_loop', '-1', '-i', $track.FullName)
    $tail = @('-map', '0:v', '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart', $tmpOut)
    $mix = "[0:a]volume=$gv[g];[1:a]volume=$mv$fade[m];[g][m]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]"
    $onlyMusic = "[1:a]volume=$mv$fade[a]"
    try {
        $r = $null
        if ($hasAudio -ne $false) { $r = Invoke-Native $ffmpeg ($common + @('-filter_complex', $mix) + $tail) }
        # Alleen muziek als de clip zeker geen geluid heeft (of als ffprobe ontbreekt en het mengen mislukte).
        if (($hasAudio -eq $false) -or ($null -eq $hasAudio -and ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $tmpOut)))) {
            $r = Invoke-Native $ffmpeg ($common + @('-filter_complex', $onlyMusic) + $tail)
        }
        if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $tmpOut)) { throw ('ffmpeg kon geen muziek onder ' + (Split-Path $c.Mp4 -Leaf) + ' zetten: ' + ([string]$r.Out).Trim()) }
        # Eerst de tekst, dan pas de video in Vandaag posten (dan staat er nooit een video zonder tekst).
        $txt = "YOUTUBE-TITEL:`r`n{0}`r`n`r`nTEKST (YouTube-beschrijving, TikTok en Instagram):`r`n{1}`r`n`r`n---`r`nMuziek: {2} (automatisch toegevoegd)`r`nOrigineel: {3}`r`n" -f $c.Title, $c.Text, $track.BaseName, (Get-OriginalName $c.Key)
        [IO.File]::WriteAllText((Join-Path $VandaagDir ($base + '.txt')), $txt, (New-Object System.Text.UTF8Encoding($true)))
        $old = (Get-Date).AddMinutes(-10); (Get-Item -LiteralPath $tmpOut).CreationTime = $old; (Get-Item -LiteralPath $tmpOut).LastWriteTime = $old
        Move-Item -LiteralPath $tmpOut -Destination $out
    } finally { Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue }
    Reload-Cfg; $script:Cfg.MuziekIndex = $i + 1; Save-Cfg
    Write-Log ('Muziek toegevoegd: {0}  ({1})' -f $base, $track.BaseName)
    return $out
}

# Muziek onder de volgende echo-clips (oud naar nieuw). $max = hoeveel er maximaal gemaakt worden.
$MusicLockFile = Join-Path $AppDir 'muziek.lock'
function Invoke-MusicBatch([int]$max) {
    $ff = Find-Ffmpeg
    if (-not $ff) { throw 'ffmpeg is nog niet geïnstalleerd. Klik op "Muziek eronder" in het venster om het te installeren.' }
    # Slot: het venster en de taak maken nooit tegelijk muziek (anders ontstaan dubbele clips).
    if (Test-Path -LiteralPath $MusicLockFile) {
        if (((Get-Date) - (Get-Item -LiteralPath $MusicLockFile).LastWriteTime).TotalMinutes -lt 60) { throw 'Er wordt al muziek toegevoegd (venster of taak). Probeer het later opnieuw.' }
        Remove-Item -LiteralPath $MusicLockFile -Force -ErrorAction SilentlyContinue
    }
    try { $fs = [IO.File]::Open($MusicLockFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write); $fs.Close() } catch { throw 'Er wordt al muziek toegevoegd (venster of taak). Probeer het later opnieuw.' }
    $n = 0
    try {
        $keys = @(Get-AllClips | Where-Object { $_.MuziekNodig -and -not $_.Gepost -and -not $_.Probleem } | Sort-Object Key | ForEach-Object { $_.Key })
        $total = [math]::Min($max, $keys.Count)
        foreach ($k in $keys) {
            if ($n -ge $max) { break }
            # Vers kijken: misschien is deze clip intussen al gemaakt of gepost.
            $c = @(Get-AllClips | Where-Object { $_.Key -eq $k -and $_.MuziekNodig -and -not $_.Gepost -and -not $_.Probleem }) | Select-Object -First 1
            if (-not $c) { continue }
            $st = Get-State $k
            if ([int]$st.muziekFouten -ge 2) { continue }   # deze lukt niet; de rest gaat gewoon door
            try {
                [void](Add-MusicToClip $c $ff); $n++
                if ($script:HasGui) { Set-Status ('Muziek eronder zetten... {0} van {1}' -f $n, $total) }
            } catch {
                Reload-State; $st = Get-State $k; Set-Prop $st 'muziekFouten' ([int]$st.muziekFouten + 1); Save-Status
                Write-Log ('Muziek mislukt, clip overgeslagen: ' + $_.Exception.Message)
            }
        }
    } finally { Remove-Item -LiteralPath $MusicLockFile -Force -ErrorAction SilentlyContinue }
    return $n
}

# ---------------------------------------------------------------- cijfers van YouTube
function Get-YouTubeStats {
    Reload-State
    $ids = @{}
    foreach ($k in $script:Done.Keys) {
        $s = $script:Done[$k]
        $id = [string]$s.youtube
        if ($id -and $id -ne 'al eerder gepost' -and $id -notlike 'sim*') { $ids[$id] = $k }
    }
    if (-not $ids.Count) { return @() }
    $token = Get-AccessToken
    $rows = New-Object System.Collections.Generic.List[object]
    $all = @($ids.Keys)
    for ($i = 0; $i -lt $all.Count; $i += 50) {
        $chunk = $all[$i..([math]::Min($i + 49, $all.Count - 1))] -join ','
        $r = Invoke-RestMethod -Uri ('https://www.googleapis.com/youtube/v3/videos?part=statistics,snippet&id=' + $chunk) -Headers @{ Authorization = "Bearer $token" }
        foreach ($v in $r.items) {
            $s = $script:Done[$ids[$v.id]]
            $uur = -1; $dag = ''
            if ($s.datum) { try { $dt = [datetime]::ParseExact([string]$s.datum, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture); $uur = $dt.Hour; $dag = $dt.ToString('ddd', [Globalization.CultureInfo]'nl-NL') } catch { } }
            $game = Get-GameFromText ([string]$v.snippet.description)
            $rows.Add([pscustomobject]@{ Titel = $v.snippet.title; Game = $game; Uur = $uur; Dag = $dag; Views = [int]$v.statistics.viewCount; Likes = [int]$v.statistics.likeCount; Id = $v.id })
        }
    }
    return $rows.ToArray()
}

function Format-Stats($rows) {
    if (-not $rows -or -not @($rows).Count) { return 'Nog geen cijfers: er zijn nog geen clips met deze Clip-poster gepost.' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('Cijfers van {0} clips die met de Clip-poster zijn gepost:' -f @($rows).Count)); [void]$sb.AppendLine()
    [void]$sb.AppendLine('Gemiddeld aantal weergaven per game:')
    foreach ($g in ($rows | Group-Object Game | Sort-Object Name)) {
        $avg = [math]::Round((($g.Group | Measure-Object Views -Average).Average), 0)
        [void]$sb.AppendLine(('  {0}: {1} ({2} clips)' -f $(if ($g.Name) { $g.Name } else { 'onbekend' }), $avg, $g.Count))
    }
    [void]$sb.AppendLine(); [void]$sb.AppendLine('Gemiddeld per posttijd:')
    $best = $null
    foreach ($h in ($rows | Where-Object { $_.Uur -ge 0 } | Group-Object Uur | Sort-Object { [int]$_.Name })) {
        $avg = [math]::Round((($h.Group | Measure-Object Views -Average).Average), 0)
        [void]$sb.AppendLine(('  rond {0}:00 uur: {1} ({2} clips)' -f $h.Name, $avg, $h.Count))
        if ($h.Count -ge 3 -and (-not $best -or $avg -gt $best.Avg)) { $best = @{ Uur = $h.Name; Avg = $avg } }
    }
    [void]$sb.AppendLine(); [void]$sb.AppendLine('Best bekeken:')
    foreach ($r in ($rows | Sort-Object Views -Descending | Select-Object -First 5)) { [void]$sb.AppendLine(('  {0} weergaven  -  {1}' -f $r.Views, $r.Titel)) }
    [void]$sb.AppendLine()
    if ($best) { [void]$sb.AppendLine(('Advies: rond {0}:00 uur doen je clips het best (gemiddeld {1} weergaven).' -f $best.Uur, $best.Avg)) }
    else { [void]$sb.AppendLine('Advies volgt zodra er per posttijd minstens 3 clips zijn (na ongeveer een week automatisch posten).') }
    return $sb.ToString()
}

# ---------------------------------------------------------------- TikTok inplannen
# Volgende tijdstip om op TikTok in te plannen: zelfde tijden als YouTube, vanaf morgen, max 10 dagen vooruit.
function Get-NextTikTokSlot {
    $times = @($script:Cfg.Tijden | ForEach-Object { [datetime]::ParseExact(([string]$_).Trim(), [string[]]@('HH:mm', 'H:mm'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None).TimeOfDay } | Sort-Object)
    $last = $null
    if ($script:Cfg.TikTokLaatsteSlot) { try { $last = [datetime]::ParseExact([string]$script:Cfg.TikTokLaatsteSlot, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { } }
    $min = (Get-Date).AddMinutes(30)
    if ($last -and $last -gt $min) { $min = $last.AddMinutes(1) }
    for ($d = 0; $d -lt 30; $d++) {
        foreach ($t in $times) {
            $cand = (Get-Date).Date.AddDays($d).Add($t)
            if ($cand -ge $min) {
                if ($cand -gt (Get-Date).AddDays(10)) { return $null }
                return $cand
            }
        }
    }
    return $null
}

if ($Auto) { Invoke-AutoPost; return }
if ($GeenVenster) { return }   # alleen de functies laden (voor testen)

# ---------------------------------------------------------------- venster
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Clip-poster - playingparentsnl'
$form.Size = New-Object System.Drawing.Size(1060, 770)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$cmbView = New-Object System.Windows.Forms.ComboBox
$cmbView.DropDownStyle = 'DropDownList'
[void]$cmbView.Items.AddRange(@('Wachtrij YouTube (in volgorde)', 'Nog naar TikTok', 'Overgeslagen (muziek nodig / probleem)', 'Alles'))
$cmbView.Location = New-Object System.Drawing.Point(15, 12); $cmbView.Size = New-Object System.Drawing.Size(480, 28)
$form.Controls.Add($cmbView)

$lst = New-Object System.Windows.Forms.ListBox
$lst.Location = New-Object System.Drawing.Point(15, 45); $lst.Size = New-Object System.Drawing.Size(480, 500)
$lst.HorizontalScrollbar = $true
$form.Controls.Add($lst)

$lblTitle = New-Object System.Windows.Forms.Label; $lblTitle.Text = 'Titel (YouTube, max. 100 tekens)'
$lblTitle.Location = New-Object System.Drawing.Point(515, 12); $lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)
$txtTitle = New-Object System.Windows.Forms.TextBox
$txtTitle.Location = New-Object System.Drawing.Point(515, 35); $txtTitle.Size = New-Object System.Drawing.Size(510, 25); $txtTitle.MaxLength = 100
$form.Controls.Add($txtTitle)

$lblText = New-Object System.Windows.Forms.Label; $lblText.Text = 'Tekst met hashtags (beschrijving op YouTube, gekopieerd voor TikTok)'
$lblText.Location = New-Object System.Drawing.Point(515, 68); $lblText.AutoSize = $true
$form.Controls.Add($lblText)
$txt = New-Object System.Windows.Forms.TextBox
$txt.Multiline = $true; $txt.ScrollBars = 'Vertical'
$txt.Location = New-Object System.Drawing.Point(515, 90); $txt.Size = New-Object System.Drawing.Size(510, 130)
$form.Controls.Add($txt)

$cmbPrivacy = New-Object System.Windows.Forms.ComboBox
$cmbPrivacy.DropDownStyle = 'DropDownList'
[void]$cmbPrivacy.Items.AddRange(@('openbaar', 'verborgen (unlisted)', 'privé'))
$cmbPrivacy.Location = New-Object System.Drawing.Point(515, 228); $cmbPrivacy.Size = New-Object System.Drawing.Size(200, 25)
$privacyMap = @{ 'openbaar' = 'public'; 'verborgen (unlisted)' = 'unlisted'; 'privé' = 'private' }
$cmbPrivacy.SelectedIndex = [array]::IndexOf(@('public', 'unlisted', 'private'), [string]$script:Cfg.Privacy)
if ($cmbPrivacy.SelectedIndex -lt 0) { $cmbPrivacy.SelectedIndex = 0 }
$form.Controls.Add($cmbPrivacy)

function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    if ($color) { $b.BackColor = $color; $b.ForeColor = [System.Drawing.Color]::White; $b.FlatStyle = 'Flat' }
    $form.Controls.Add($b); return $b
}
$btnNext  = New-Btn 'POST VOLGENDE  (YouTube + TikTok klaarzetten)' 515 262 510 55 ([System.Drawing.Color]::FromArgb(110, 40, 200))
$btnYt    = New-Btn 'Alleen YouTube (gekozen clip)'   515 325 250 40 ([System.Drawing.Color]::FromArgb(204, 0, 0))
$btnTt    = New-Btn 'TikTok klaarzetten (gekozen clip)' 775 325 250 40 ([System.Drawing.Color]::FromArgb(20, 20, 20))
$btnTtDone= New-Btn 'Staat op TikTok: klaar'          515 372 250 40 ([System.Drawing.Color]::FromArgb(39, 174, 96))
$btnClean = New-Btn 'Opruimen: geposte clips naar Gepost' 775 372 250 40 $null
$btnRonde = New-Btn 'TIKTOK-RONDE: alle clips die nog naar TikTok moeten, een voor een' 515 420 510 42 ([System.Drawing.Color]::FromArgb(20, 20, 20))
$btnAuto  = New-Btn '' 515 468 510 45 ([System.Drawing.Color]::FromArgb(0, 120, 200))
$btnSetup = New-Btn 'YouTube instellen'  15 555 160 40 $null
$btnCheck = New-Btn 'Controle'          185 555 150 40 $null
$btnLog   = New-Btn 'Logboek'           345 555 150 40 $null
$btnMusic = New-Btn 'Muziek eronder'     15 600 160 40 $null
$btnStats = New-Btn 'Cijfers'           185 600 150 40 $null
$btnPhone = New-Btn 'Telefoon'          345 600 150 40 $null

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(515, 520); $status.Size = New-Object System.Drawing.Size(510, 125)
$form.Controls.Add($status)
$summary = New-Object System.Windows.Forms.Label
$summary.Location = New-Object System.Drawing.Point(15, 652); $summary.Size = New-Object System.Drawing.Size(1010, 60)
$form.Controls.Add($summary)
function Set-Status([string]$t) { $status.Text = $t; [System.Windows.Forms.Application]::DoEvents() }

$script:All = @(); $script:Queue = @(); $script:Shown = @()
function Update-AutoButton {
    $t = Get-AutoTask
    if ($t) {
        $extra = ''; if ($script:Cfg.AutoGepauzeerd) { $extra = '  (OP PAUZE)' }
        $btnAuto.Text = ('Automatisch posten staat AAN: {0}{1}  -  klik om uit te zetten' -f (@($script:Cfg.Tijden) -join ', '), $extra)
    } else {
        $btnAuto.Text = ('Automatisch posten staat UIT  -  klik om aan te zetten ({0})' -f (@($script:Cfg.Tijden) -join ', '))
    }
}
function Format-Clip($c, [int]$n) {
    $g = switch ($c.Game) { 'GTA 6' { 'GTA ' } 'Arma Reforger' { 'ARMA' } 'Fall Guys' { 'FALL' } default { '??? ' } }
    $yt = if ($c.Gepost) { 'v' } else { '-' }; $tt = if ($c.TikTok) { 'v' } else { '-' }
    $pre = if ($n -gt 0) { '{0,3}. ' -f $n } else { '' }
    $suf = ''
    if ($c.MuziekNodig) { $suf = '  (muziek nodig)' } elseif ($c.Probleem) { $suf = '  (' + $c.Probleem + ')' }
    return ('{0}[{1}] [YT {2}] [TT {3}]  {4}{5}' -f $pre, $g, $yt, $tt, $c.Title, $suf)
}
function Refresh-List {
    $script:All = @(Get-AllClips)
    $script:Queue = @(Get-Queue $script:All)
    $sel = $lst.SelectedIndex
    $lst.Items.Clear()
    switch ($cmbView.SelectedIndex) {
        0 { $script:Shown = $script:Queue }
        1 { $script:Shown = @($script:All | Where-Object { $_.Gepost -and -not $_.TikTok -and $_.YouTubeId -ne 'al eerder gepost' } | Sort-Object { Get-SortKey $_ }) }
        2 { $script:Shown = @($script:All | Where-Object { -not $_.Gepost -and ($_.MuziekNodig -or $_.Probleem) } | Sort-Object { Get-SortKey $_ }) }
        default { $script:Shown = @($script:All | Sort-Object { Get-SortKey $_ }) }
    }
    $n = 0
    foreach ($c in $script:Shown) { $n++; [void]$lst.Items.Add((Format-Clip $c $(if ($cmbView.SelectedIndex -eq 0) { $n } else { 0 }))) }
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = [math]::Min([math]::Max($sel, 0), $lst.Items.Count - 1) }
    else { $txt.Text = ''; $txtTitle.Text = '' }
    $tiktok = @($script:All | Where-Object { $_.Gepost -and -not $_.TikTok -and $_.YouTubeId -ne 'al eerder gepost' }).Count
    $skip = @($script:All | Where-Object { -not $_.Gepost -and ($_.MuziekNodig -or $_.Probleem) }).Count
    $volgende = if ($script:Queue.Count) { $script:Queue[0].Title } else { '(geen)' }
    $laatste = ''
    if (Test-Path -LiteralPath $LogFile) { $laatste = [string](Get-Content -LiteralPath $LogFile -Tail 1 -Encoding UTF8) }
    $summary.Text = ('Wachtrij YouTube: {0} clips  |  nog naar TikTok: {1}  |  overgeslagen: {2}  |  volgende: {3}' -f $script:Queue.Count, $tiktok, $skip, $volgende)
    if ($laatste) { $summary.Text += "`nLaatste melding: " + $laatste }
    Update-AutoButton
    if ($script:Cfg.AutoGepauzeerd) { Set-Status ('LET OP: ' + $script:Cfg.AutoReden) }
}
function Get-Selected {
    if ($lst.SelectedIndex -lt 0 -or $lst.SelectedIndex -ge $script:Shown.Count) { [System.Windows.Forms.MessageBox]::Show('Kies eerst een clip in de lijst.') | Out-Null; return $null }
    return $script:Shown[$lst.SelectedIndex]
}

$lst.Add_SelectedIndexChanged({
    if ($lst.SelectedIndex -lt 0 -or $lst.SelectedIndex -ge $script:Shown.Count) { return }
    $c = $script:Shown[$lst.SelectedIndex]
    $txtTitle.Text = $c.Title
    $txt.Text = $c.Text
    if ($c.Gepost -and $c.YouTubeId -ne 'al eerder gepost') { Set-Status ('Al op YouTube: https://youtube.com/shorts/{0}' -f $c.YouTubeId) }
    elseif (-not $script:Cfg.AutoGepauzeerd) { Set-Status ('Bestand: ' + (Split-Path $c.Mp4 -Leaf)) }
})
$cmbView.Add_SelectedIndexChanged({ $lst.SelectedIndex = -1; Refresh-List })

$script:Job = $null; $script:JobClip = $null; $script:JobThenTikTok = $false
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000
$timer.Add_Tick({
    if (-not $script:Job) { $timer.Stop(); return }
    if ($script:Job.State -eq 'Running' -or $script:Job.State -eq 'NotStarted') { Set-Status ("Uploaden naar YouTube... ({0} sec)" -f [int]((Get-Date) - $script:Job.PSBeginTime).TotalSeconds); return }
    $timer.Stop()
    $out = [string](Receive-Job $script:Job | Select-Object -Last 1)
    Remove-Job $script:Job -Force; $script:Job = $null
    $btnYt.Enabled = $true; $btnNext.Enabled = $true
    Exit-UploadLock
    $c = $script:JobClip
    $msg = Complete-Upload $c.Key $c.Game $out ([string]$script:Cfg.Privacy)
    Set-Status $msg
    if ($out -like 'OK|*' -and $msg -notlike 'LET OP*' -and $script:JobThenTikTok) { Prepare-TikTok $c; Set-Status ($msg + "`n`nTikTok staat klaar: sleep de video naar de uploadpagina en plak de tekst (Ctrl+V). Daarna: 'Staat op TikTok: klaar'.") }
    Refresh-List
})

function Start-YouTube($c, [bool]$thenTikTok) {
    if ($script:Job) { Set-Status 'Er loopt al een upload.'; return }
    # Vers inlezen: misschien heeft de automatische taak deze clip net gepost.
    Reload-State; Reload-Cfg
    $c.Gepost = [bool]([string](Get-State $c.Key).youtube)
    if ($script:Cfg.AutoGepauzeerd) {
        $a = [System.Windows.Forms.MessageBox]::Show(("Posten staat op pauze:`n`n{0}`n`nToch uploaden?" -f $script:Cfg.AutoReden), 'Let op', 'YesNo')
        if ($a -ne 'Yes') { return }
    }
    if ($c.Gepost) {
        $a = [System.Windows.Forms.MessageBox]::Show('Deze clip staat al op YouTube. Nog een keer uploaden?', 'Let op', 'YesNo')
        if ($a -ne 'Yes') { return }
    }
    if ($c.MuziekNodig -or $c.Probleem) {
        $why = if ($c.MuziekNodig) { 'GTA-stream met echo, er moet nog muziek onder' } else { $c.Probleem }
        if ([System.Windows.Forms.MessageBox]::Show(('Deze clip wordt normaal overgeslagen ({0}). Toch uploaden?' -f $why), 'Let op', 'YesNo') -ne 'Yes') { return }
    }
    if (-not $txtTitle.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('Vul een titel in.') | Out-Null; return }
    try { $token = Get-AccessToken } catch { Set-Status ('Inloggen mislukt: ' + $_.Exception.Message); return }
    $privacy = $privacyMap[[string]$cmbPrivacy.SelectedItem]
    $script:Cfg.Privacy = $privacy; Save-Cfg
    $meta = New-UploadMeta $txtTitle.Text $txt.Text $privacy
    $c.Title = $txtTitle.Text.Trim(); $c.Text = $txt.Text
    if (-not (Enter-UploadLock)) { Set-Status 'Er loopt al een upload (misschien de automatische taak). Probeer het over een paar minuten opnieuw.'; return }
    $btnYt.Enabled = $false; $btnNext.Enabled = $false
    $script:JobClip = $c; $script:JobThenTikTok = $thenTikTok
    $script:Job = Start-Job -ScriptBlock $UploadJob -ArgumentList $token, $c.Mp4, $meta
    $timer.Start()
}

function Prepare-TikTok($c) {
    if ($c.Text) { Set-Clipboard -Value $c.Text }
    Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $c.Mp4)
    Start-Process 'https://www.tiktok.com/tiktokstudio/upload'
}

$btnNext.Add_Click({
    $cmbView.SelectedIndex = 0; Refresh-List
    if (-not $script:Queue.Count) { Set-Status 'De wachtrij is leeg.'; return }
    $lst.SelectedIndex = 0
    Start-YouTube $script:Queue[0] $true
})
$btnYt.Add_Click({ $c = Get-Selected; if ($c) { Start-YouTube $c $false } })
$btnTt.Add_Click({ $c = Get-Selected; if ($c) { Prepare-TikTok $c; Set-Status 'Tekst staat op je klembord en de video is geselecteerd in Verkenner. Sleep de video naar TikTok en plak de tekst (Ctrl+V).' } })
$btnTtDone.Add_Click({
    $c = Get-Selected; if (-not $c) { return }
    Reload-State; $s = Get-State $c.Key; $s.tiktok = $true; Save-Status
    $c.Gepost = [bool]([string]$s.youtube)
    if ($c.Gepost) { Move-ToGepost $c; Set-Status ('Klaar en verplaatst naar ' + $GepostDir) } else { Set-Status 'Gemarkeerd als op TikTok. Nog niet op YouTube, dus hij blijft in de wachtrij.' }
    Refresh-List
})
# TikTok-ronde: alle clips die al op YouTube staan maar nog niet op TikTok, een voor een.
$btnRonde.Add_Click({
    Refresh-List
    $todo = @($script:All | Where-Object { $_.Gepost -and -not $_.TikTok -and $_.YouTubeId -ne 'al eerder gepost' } | Sort-Object { Get-SortKey $_ })
    if (-not $todo.Count) { Set-Status 'Er hoeft niets naar TikTok.'; return }
    $i = 0
    foreach ($c in $todo) {
        $i++
        Prepare-TikTok $c
        $slot = Get-NextTikTokSlot
        $plan = if ($slot) { ("Plan hem in TikTok in op: {0}  (bij 'Inplannen' onderaan de uploadpagina)." -f $slot.ToString('dddd d MMMM HH:mm', [Globalization.CultureInfo]'nl-NL')) } else { 'TikTok kan maar 10 dagen vooruit plannen: post deze gewoon meteen.' }
        $vraag = ("Clip {0} van {1}: {2}`n`nDe tekst staat op je klembord en de video is geselecteerd in Verkenner.`nSleep de video naar TikTok en plak de tekst (Ctrl+V).`n{3}`n`nJa = staat op TikTok, door naar de volgende`nNee = deze overslaan`nAnnuleren = stoppen" -f $i, $todo.Count, $c.Title, $plan)
        $a = [System.Windows.Forms.MessageBox]::Show($vraag, 'TikTok-ronde', 'YesNoCancel')
        if ($a -eq 'Cancel') { break }
        if ($a -eq 'Yes') {
            Reload-State; (Get-State $c.Key).tiktok = $true; Save-Status
            if ($slot) { Reload-Cfg; $script:Cfg.TikTokLaatsteSlot = $slot.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture); Save-Cfg }
            try { Move-ToGepost $c } catch { Set-Status ('Verplaatsen mislukt (bestand in gebruik?): ' + $_.Exception.Message) }
        }
    }
    Refresh-List
    Set-Status 'TikTok-ronde klaar. Wat op TikTok staat is verplaatst naar de map Gepost.'
})
$btnClean.Add_Click({
    $n = 0
    foreach ($c in @($script:All | Where-Object { $_.Gepost -and $_.TikTok })) { Move-ToGepost $c; $n++ }
    Set-Status ('{0} clips verplaatst naar {1}' -f $n, $GepostDir); Refresh-List
})
$btnAuto.Add_Click({
    try {
        if (Get-AutoTask) { Set-AutoTask $false; Set-Status 'Automatisch posten staat uit.' }
        else {
            if (-not (Test-Path -LiteralPath $TokenFile)) { Set-Status 'Koppel eerst YouTube (YouTube instellen).'; return }
            Set-AutoTask $true
            Set-Status ('Automatisch posten staat aan. Elke dag om {0} gaat de volgende clip op YouTube, ook als dit venster dicht is (de pc moet aan staan). TikTok-clips verschijnen in de lijst "Nog naar TikTok".' -f (@($script:Cfg.Tijden) -join ', '))
        }
    } catch { Set-Status ('Automatisch posten instellen mislukt: ' + $_.Exception.Message) }
    Refresh-List
})
$btnMusic.Add_Click({
    try {
        $ff = Find-Ffmpeg
        if (-not $ff) {
            $a = [System.Windows.Forms.MessageBox]::Show("Voor muziek onder de clips is het gratis programma ffmpeg nodig.`n`nNu installeren via winget (de officiële Windows-pakketbron, pakket Gyan.FFmpeg, ongeveer 100 MB)?", 'ffmpeg installeren', 'YesNo')
            if ($a -ne 'Yes') { return }
            Set-Status 'ffmpeg wordt geïnstalleerd... (dit kan een paar minuten duren)'
            $ff = Install-Ffmpeg
        }
        $todo = @($script:All | Where-Object { $_.MuziekNodig -and -not $_.Gepost -and -not $_.Probleem }).Count
        if (-not $todo) { Set-Status 'Er zijn geen clips die nog muziek nodig hebben.'; return }
        $a = [System.Windows.Forms.MessageBox]::Show(("Muziek zetten onder {0} GTA-clips met echo?`n`nDe nieuwe versies komen in 'Vandaag posten' en gaan daarna vanzelf in de wachtrij. De originelen blijven staan." -f $todo), 'Muziek eronder', 'YesNo')
        if ($a -ne 'Yes') { return }
        $n = Invoke-MusicBatch $todo
        Set-Status ('{0} clips hebben nu muziek en staan in de wachtrij.' -f $n)
    } catch { Set-Status ('Muziek toevoegen mislukt: ' + $_.Exception.Message) }
    Refresh-List
})
$btnStats.Add_Click({
    try { Set-Status 'Cijfers ophalen bij YouTube...'; $txtS = Format-Stats (Get-YouTubeStats); Set-Status ''; [System.Windows.Forms.MessageBox]::Show($txtS, 'Cijfers') | Out-Null }
    catch { Set-Status ('Cijfers ophalen mislukt: ' + $_.Exception.Message + ' (log eventueel opnieuw in via YouTube instellen; de leesrechten zijn nieuw.)') }
})
$btnPhone.Add_Click({
    $topic = [string]$script:Cfg.NtfyTopic
    $msg = "Meldingen op je telefoon:`n`n1. Installeer de gratis app 'ntfy' (Play Store / App Store).`n2. Tik op + en abonneer je op dit onderwerp:`n`n      $topic`n`n3. Klik hierna op OK: dan stuurt de Clip-poster een testmelding.`n`nJe krijgt een melding bij elke post, als iets mislukt, als posten op pauze gaat en als de wachtrij leeg is.`n(Het onderwerp staat ook op je klembord.)"
    Set-Clipboard -Value $topic
    [System.Windows.Forms.MessageBox]::Show($msg, 'Telefoon') | Out-Null
    if (Send-PhoneCore 'Clip-poster: testmelding' 'Het werkt! Vanaf nu krijg je hier meldingen van de Clip-poster.') { Set-Status ('Testmelding verstuurd naar onderwerp ' + $topic) }
    else { Set-Status 'Testmelding versturen lukte niet. Is er internet?' }
})
$btnCheck.Add_Click({ [System.Windows.Forms.MessageBox]::Show(((Get-Checks $script:All) -join "`n`n"), 'Controle') | Out-Null })
$btnLog.Add_Click({ if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $LogFile) } else { Set-Status 'Het logboek is nog leeg.' } })
$btnSetup.Add_Click({
    $msg = "Kies het bestand client_secret.json dat je in Google Cloud hebt gedownload.`n`nDaarna log je in bij Google. Kies daar het kanaal playingparentsnl (niet je eigen naam)."
    [System.Windows.Forms.MessageBox]::Show($msg, 'YouTube instellen') | Out-Null
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    Copy-Item -LiteralPath $dlg.FileName -Destination $SecretFile -Force
    Remove-Item -LiteralPath $TokenFile -ErrorAction SilentlyContinue
    try {
        $null = Get-AccessToken
        $script:Cfg.AutoGepauzeerd = $false; $script:Cfg.AutoReden = ''; Save-Cfg
        Set-Status 'YouTube is gekoppeld. Bij de eerste upload zie je op welk kanaal hij komt.'
    } catch { Set-Status ('Koppelen mislukt: ' + $_.Exception.Message) }
    Refresh-List
})

$form.Add_Shown({ $cmbView.SelectedIndex = 0 })
$form.Add_FormClosing({ if ($script:Job) { Stop-Job $script:Job -ErrorAction SilentlyContinue } })
[void]$form.ShowDialog()
