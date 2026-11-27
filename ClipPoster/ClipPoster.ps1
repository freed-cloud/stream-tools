# Clip-poster (versie 5) - gratis en open source, door Freddy den Haan
# https://github.com/freed-cloud/stream-tools
#
# Wat hij doet:
# - Maakt zelf een wachtrij van alle clips die klaar zijn om te posten:
#     * <clipsmap>\Vandaag posten   (video + .txt met dezelfde naam: gewone tekst, of YOUTUBE-TITEL / TEKST)
#     * <clipsmap>\Replay ... - staand.mp4  (met "- tekst.txt"; de naam die OBS-replays krijgen)
#   De titel komt uit de .txt, anders uit de naam in Videos\AI-clips\<game>, anders uit de tekst.
# - Herkent de game aan de hashtags (instelbaar) en post games om en om, oud naar nieuw.
# - Controleert de volgorde, dubbele clips, ontbrekende teksten en clips die nog muziek nodig hebben.
# - Eén knop "Post volgende": uploadt naar YouTube en zet TikTok klaar.
# - Automatisch posten: een Windows-taak die op vaste tijden de volgende clip op YouTube zet,
#   ook als dit venster dicht is. TikTok blijft handwerk (TikTok laat geen automatisch posten toe
#   zonder goedgekeurde app); de clips die nog naar TikTok moeten staan in een eigen lijst.
# - Klaar op YouTube en TikTok: video en tekst gaan naar de map "Gepost". Er wordt niets verwijderd.
# Instagram zit er bewust niet in: Instagram blokkeert accounts die automatisch posten.
# Werkt met Windows PowerShell 5.1 (standaard in Windows 10 en 11).
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
    # Fouten in knoppen en tekenwerk: duidelijke melding en in het logboek, in plaats van de .NET-foutmelding.
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        $m = 'Er ging iets mis: ' + $e.Exception.Message
        if ($e.Exception.InnerException) { $m += ' (' + $e.Exception.InnerException.Message + ')' }
        try { Write-Log $m } catch { }
        if ($env:CLIPPOSTER_SCREENSHOT) { [Console]::Error.WriteLine($m + "`n" + $e.Exception.ToString()); [Environment]::Exit(1) }
        [System.Windows.Forms.MessageBox]::Show($m, 'Clip-poster') | Out-Null
    })
}
# Onverwachte fout? Laat hem zien (venster) of schrijf hem in het logboek (automatisch), in plaats van stil te stoppen.
trap {
    $m = "Er ging iets mis: $($_.Exception.Message) (regel $($_.InvocationInfo.ScriptLineNumber))"
    if ($env:CLIPPOSTER_SCREENSHOT) { [Console]::Error.WriteLine($m); exit 1 }   # test zonder iemand achter het scherm
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
    Versie        = 5
    # Is het instelscherm al een keer opgeslagen? (Anders opent het vanzelf bij de eerste start.)
    Ingesteld     = $false
    # Naam van het YouTube-kanaal (alleen voor meldingen en het venster).
    KanaalNaam    = ''
    # Map met de clips. Leeg = Bureaublad\Clips voor socials.
    ClipsMap      = ''
    Privacy       = 'public'
    # Vaste posttijden voor automatisch posten (4 per dag). Niet precies op het hele uur: minder druk bij YouTube.
    Tijden        = @('12:07', '16:04', '19:06', '21:03')
    # Games, herkend aan de hashtags in de tekst (zonder #, kleine letters).
    Games         = @()
    # Om en om posten in deze volgorde. Andere games schuiven er af en toe tussen.
    Rotatie       = @()
    # Moet elke clip een herkende game hebben? (Nee = onbekende games gaan als "Overig" mee.)
    GameVerplicht = $false
    # Moet een clip in "Vandaag posten" een regel "Origineel: Replay ..." hebben? (Voorkomt dubbel posten
    # als dezelfde clip ook als OBS-replay in de clipsmap staat.)
    OrigineelVerplicht = $false
    # Streams waarvan clips van de muziek-game alleen met muziek eronder gepost worden (bijv. geluid met echo).
    EchoDatums    = @()
    MuziekGame    = ''
    # Het YouTube-kanaal-ID. Gaat een upload naar een ander kanaal, dan stopt automatisch posten.
    # Leeg = wordt bij de eerste geslaagde upload vanzelf ingevuld.
    KanaalId      = ''
    LaatsteGame   = ''
    # Aantal posts uit de hoofdrotatie sinds de laatste "andere" game.
    SindsExtra    = 0
    # Regel die onder elke YouTube-beschrijving komt (bijv. je Twitch-link). Leeg = geen regel.
    TwitchRegel   = ''
    # Pushmeldingen op de telefoon via de gratis app ntfy (onderwerp wordt bij de eerste start gemaakt).
    NtfyTopic     = ''
    # Muziek onder clips: volume van het spelgeluid en van de muziek.
    GameVolume    = 0.35
    MuziekVolume  = 0.85
    MuziekIndex   = 0
    # Zoveel clips met muziek wil de taak minstens klaar hebben staan; anders maakt hij er zelf bij.
    MinGtaKlaar   = 3
    # Laatst voorgestelde TikTok-inplantijd.
    TikTokLaatsteSlot = ''
    AutoGepauzeerd = $false
    AutoReden     = ''
}
# Instellingen van versie 4 (alleen gebruikt door playingparentsnl, waar de Clip-poster mee begon).
$V4Cfg = @{
    KanaalNaam = 'playingparentsnl'; Rotatie = @('GTA 6', 'Arma Reforger'); EchoDatums = @('2026-11-19'); MuziekGame = 'GTA 6'
    KanaalId = 'UC0EU7Am-oiUnpg_yv9FHJkQ'; TwitchRegel = 'Live op Twitch: https://twitch.tv/playingparentsnl'
    GameVerplicht = $true; OrigineelVerplicht = $true; Ingesteld = $true
    Games = @(
        [pscustomobject]@{ Naam = 'Arma Reforger'; Tags = @('armareforger', 'arma') },
        [pscustomobject]@{ Naam = 'GTA 6'; Tags = @('gta6', 'gtavi') },
        [pscustomobject]@{ Naam = 'Fall Guys'; Tags = @('fallguys') }
    )
}
$script:Cfg = Load-Json $ConfigFile $null
$cfgVersie = 0
if ($script:Cfg -and ($script:Cfg.PSObject.Properties.Name -contains 'Versie')) { $cfgVersie = [int]$script:Cfg.Versie }
if (-not $script:Cfg -or $cfgVersie -lt 4) {
    # Nieuwe installatie (of heel oude versie): beginnen met de standaardinstellingen.
    $old = $script:Cfg
    $script:Cfg = $DefaultCfg.PSObject.Copy()
    if ($old -and ($old.PSObject.Properties.Name -contains 'Privacy') -and $old.Privacy) { $script:Cfg.Privacy = [string]$old.Privacy }
    Save-Json $ConfigFile $script:Cfg
} elseif ($cfgVersie -eq 4) {
    # Overstap van versie 4: die werkte alleen voor playingparentsnl. Wat al in config.json stond blijft staan;
    # de nieuwe instellingen krijgen de waarden die in versie 4 vast in het programma zaten.
    foreach ($k in $V4Cfg.Keys) {
        if (-not ($script:Cfg.PSObject.Properties.Name -contains $k) -or $k -in 'Games', 'KanaalNaam', 'GameVerplicht', 'OrigineelVerplicht', 'MuziekGame', 'Ingesteld') { Set-Prop $script:Cfg $k $V4Cfg[$k] }
    }
    $script:Cfg.Versie = 5
    Save-Json $ConfigFile $script:Cfg
}
function Complete-Cfg { foreach ($p in $DefaultCfg.PSObject.Properties) { if (-not ($script:Cfg.PSObject.Properties.Name -contains $p.Name)) { Set-Prop $script:Cfg $p.Name $p.Value } } }
Complete-Cfg
function Save-Cfg { Save-Json $ConfigFile $script:Cfg }
if (-not $script:Cfg.NtfyTopic) {
    $chars = 'abcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
    $rnd = New-Object byte[] 12; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
    $pre = ([string]$script:Cfg.KanaalNaam).ToLower() -replace '[^a-z0-9]', ''
    if (-not $pre) { $pre = 'clipposter' }
    $script:Cfg.NtfyTopic = $pre + '-' + (-join ($rnd | ForEach-Object { $chars[$_ % $chars.Length] }))
    Save-Cfg
}
# Naam voor in meldingen: de kanaalnaam, of "je kanaal".
function Get-KanaalTekst { if ([string]$script:Cfg.KanaalNaam) { return [string]$script:Cfg.KanaalNaam } else { return 'je eigen kanaal' } }

# Mappen (de clipsmap is instelbaar).
function Set-Folders {
    $m = [string]$script:Cfg.ClipsMap
    if (-not $m -or $env:CLIPPOSTER_TESTROOT) { $m = Join-Path $Desktop 'Clips voor socials' }
    $script:SocialsDir = $m
    $script:VandaagDir = Join-Path $m 'Vandaag posten'
    $script:GepostDir  = Join-Path $m 'Gepost'
    $script:MuziekDir  = Join-Path $m 'Muziek'
    $script:InstaDir   = Join-Path $m 'Instagram posten'
    $script:AiDir      = Join-Path $VideosDir 'AI-clips'
}
Set-Folders

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
    if ($c -and ($c.PSObject.Properties.Name -contains 'Versie') -and [int]$c.Versie -ge 5) { $script:Cfg = $c; Complete-Cfg; Set-Folders }
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
    # (Alleen voor het kanaal waar de Clip-poster mee begon.)
    foreach ($k in $(if ($script:Cfg.KanaalId -eq 'UC0EU7Am-oiUnpg_yv9FHJkQ') { $AlEerderGepost } else { @() })) {
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

# De game herkennen aan de hashtags (instelbaar bij Instellingen).
function Get-GameFromText([string]$text) {
    foreach ($g in @($script:Cfg.Games)) {
        if (-not $g -or -not $g.Naam) { continue }
        foreach ($t in @($g.Tags)) {
            $t = ([string]$t).Trim().TrimStart('#')
            if ($t -and $text -match ('(?i)#' + [regex]::Escape($t) + '\b')) { return [string]$g.Naam }
        }
    }
    return ''
}
# De game uit een bestandsnaam (bijv. "12 - Titel - GTA 6.mp4").
function Get-GameFromName([string]$name) {
    $n = ($name -replace '[^a-zA-Z0-9]', '').ToLower()
    foreach ($g in @($script:Cfg.Games)) {
        if (-not $g -or -not $g.Naam) { continue }
        $cands = @(([string]$g.Naam -replace '[^a-zA-Z0-9]', '').ToLower()) + @($g.Tags | ForEach-Object { ([string]$_).Trim().TrimStart('#').ToLower() })
        foreach ($c in $cands) { if ($c.Length -ge 3 -and $n.Contains($c)) { return [string]$g.Naam } }
    }
    return ''
}
function Get-GameProbleem {
    $tags = @(@($script:Cfg.Games) | ForEach-Object { @($_.Tags) | Select-Object -First 1 } | Where-Object { $_ } | ForEach-Object { '#' + ([string]$_).TrimStart('#') })
    if ($tags.Count) { return ('game onbekend (geen {0} in de tekst)' -f ($tags -join ' of ')) }
    return 'game onbekend (stel bij Instellingen in aan welke hashtags je games herkend worden)'
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
        if (-not $c.Key) {
            $c.Key = 'vandaag:' + $f.BaseName
            if ($script:Cfg.OrigineelVerplicht -and -not $c.Probleem) { $c.Probleem = 'geen regel "Origineel: Replay ..." in de .txt (anders kan hij dubbel gepost worden)' }
        }
        $c.Game = Get-GameFromText $c.Text
        if (-not $c.Game) { $c.Game = Get-GameFromName $f.BaseName }
        $c.Title = $parts.Title
        if (-not $c.Title -and $ai.ContainsKey($c.Key)) { $c.Title = '{0} | {1}' -f $ai[$c.Key].Title, $ai[$c.Key].Game }
        if (-not $c.Title) { $c.Title = Get-CleanTitle $f.BaseName }
        if (-not $c.Text -and -not $c.Probleem) { $c.Probleem = 'tekst is leeg' }
        if (-not $c.Game -and -not $c.Probleem -and $script:Cfg.GameVerplicht) { $c.Probleem = Get-GameProbleem }
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
        if (-not $c.Game -and -not $c.Probleem -and $script:Cfg.GameVerplicht) { $c.Probleem = Get-GameProbleem }
        if (-not $c.Text -and -not $c.Probleem) { $c.Probleem = 'tekst is leeg' }
        $datum = $c.Key.Substring(0, [math]::Min(10, $c.Key.Length))
        # Stream met slecht geluid (bijv. echo): clips van de muziek-game, en voor de zekerheid ook clips
        # waarvan de game niet uit de tekst blijkt, gaan pas met muziek eronder.
        $mg = [string]$script:Cfg.MuziekGame
        if ($echo -contains $datum -and ((-not $mg) -or $c.Game -eq $mg -or -not (Get-GameFromText $c.Text))) { $c.MuziekNodig = $true }
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
# Games die om en om gaan: de ingestelde rotatie, of anders alle ingestelde games.
function Get-Rotatie {
    $r = @(@($script:Cfg.Rotatie) | Where-Object { $_ })
    if (-not $r.Count) { $r = @(@($script:Cfg.Games) | Where-Object { $_ -and $_.Naam } | ForEach-Object { [string]$_.Naam }) }
    return $r
}
function Get-SortKey($c) { return ('{0}|{1:D4}' -f $c.Key, $c.Nr) }

# De wachtrij voor YouTube: oud naar nieuw per game, om en om volgens de rotatie.
function Get-Queue($all) {
    $ok = @($all | Where-Object { -not $_.Gepost -and -not $_.Probleem -and -not $_.MuziekNodig })
    $perGame = [ordered]@{}
    foreach ($c in ($ok | Sort-Object { Get-SortKey $_ })) {
        if (-not $perGame.Contains($c.Game)) { $perGame[$c.Game] = New-Object System.Collections.Generic.Queue[object] }
        $perGame[$c.Game].Enqueue($c)
    }
    # Hoofdrotatie (bijv. GTA 6 en Arma Reforger om en om). Andere games (bijv. Fall Guys) komen
    # er af en toe tussen: één na elke $ExtraElke posts uit de hoofdrotatie.
    $ExtraElke = $script:ExtraElke
    $rot = New-Object System.Collections.Generic.List[string]
    foreach ($g in @(Get-Rotatie)) { if ($perGame.Contains($g)) { $rot.Add($g) } }
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
    if ($m.Count) { $msgs.Add(('{0} clips van een stream met slecht geluid worden overgeslagen tot er muziek onder zit (knop "Muziek eronder").' -f $m.Count)) }
    $per = @{}
    foreach ($c in @(Get-Queue $all)) { if (-not $per.ContainsKey($c.Game)) { $per[$c.Game] = 0 }; $per[$c.Game]++ }
    $perDag = [math]::Max(1, @($script:Cfg.Tijden).Count)
    $rotatie = @(Get-Rotatie)
    if (-not $rotatie.Count) {
        $n = @(Get-Queue $all).Count
        if ($n -eq 0) { $msgs.Add('Er staan geen clips meer klaar om te posten.') }
        elseif ([math]::Floor($n / $perDag) -le 3) { $msgs.Add(('Nog maar {0} clips klaar (ongeveer {1} dagen). Zet op tijd nieuwe clips klaar.' -f $n, [math]::Max(1, [math]::Floor($n / $perDag)))) }
    }
    foreach ($g in $rotatie) {
        $n = 0; if ($per.ContainsKey($g)) { $n = $per[$g] }
        $dagen = [math]::Floor($n * $rotatie.Count / $perDag)
        if ($n -eq 0) { $msgs.Add(('Er staan geen {0}-clips meer klaar. De andere games gaan gewoon door.' -f $g)) }
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
    Set-Status ('Log in bij Google in je browser. Kies het kanaal {0} en geef toestemming...' -f (Get-KanaalTekst))
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
        # Verkeerd kanaal: NIET als gepost tellen, zodat de clip in de wachtrij blijft voor het goede kanaal.
        $s.verkeerd = $parts[1]; Save-Status
        $script:Cfg.AutoGepauzeerd = $true
        $script:Cfg.AutoReden = ('Upload ging naar kanaal "{0}" in plaats van {1} (video https://youtube.com/shorts/{2}). Klik op YouTube koppelen en kies het goede kanaal.' -f $parts[4], (Get-KanaalTekst), $parts[1])
        Save-Cfg
        $msg = 'LET OP: ' + $script:Cfg.AutoReden + ' Posten staat op pauze.'
        Write-Log $msg
        Send-Phone 'Clip-poster: verkeerd kanaal, op pauze' $msg 'high'
        return $msg
    }
    $s.youtube = $parts[1]; $s.kanaal = $parts[3]; $s.datum = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Save-Status
    # Eerste geslaagde upload: dit kanaal onthouden, zodat een upload naar een ander kanaal later opvalt.
    if (-not $script:Cfg.KanaalId -and $parts[3]) {
        $script:Cfg.KanaalId = $parts[3]
        if (-not $script:Cfg.KanaalNaam -and $parts[4]) { $script:Cfg.KanaalNaam = $parts[4] }
    }
    if (@(Get-Rotatie) -contains $game) { $script:Cfg.LaatsteGame = $game; $script:Cfg.SindsExtra = [int]$script:Cfg.SindsExtra + 1 }
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
    # Bijna geen clips van de muziek-game meer klaar? Dan eerst twee clips van muziek voorzien.
    try {
        $mg = [string]$script:Cfg.MuziekGame
        $wacht = @(Get-AllClips | Where-Object { $_.MuziekNodig -and -not $_.Gepost -and -not $_.Probleem }).Count
        $klaarMg = @(Get-Queue (Get-AllClips) | Where-Object { (-not $mg) -or $_.Game -eq $mg }).Count
        if ($wacht -and $klaarMg -lt [int]$script:Cfg.MinGtaKlaar -and -not $Proef -and (Find-Ffmpeg)) {
            $n = Invoke-MusicBatch 2
            if ($n) { Write-Log ('{0} clips van muziek voorzien.' -f $n) }
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
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Description 'Clip-poster: zet op vaste tijden de volgende clip op YouTube.' -Force | Out-Null
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


# ---------------------------------------------------------------- muziek onder clips (ffmpeg)
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
    $game = if ($c.Game) { $c.Game } elseif ($script:Cfg.MuziekGame) { [string]$script:Cfg.MuziekGame } else { '' }
    $title = $c.Title
    if ($game) { $title = $title -replace ('\s*\|\s*' + [regex]::Escape($game) + '\s*$'), '' }
    $base = '{0} - {1}' -f $nr, (Get-SafeFileName $title)
    if ($game) { $base += ' - ' + (Get-SafeFileName $game) }
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
# Kleuren en lettertypes (donker thema)
$Kleur = @{
    Bg      = [System.Drawing.Color]::FromArgb(15, 17, 23)
    Card    = [System.Drawing.Color]::FromArgb(24, 27, 36)
    Input   = [System.Drawing.Color]::FromArgb(32, 36, 48)
    Hover   = [System.Drawing.Color]::FromArgb(44, 49, 64)
    Sel     = [System.Drawing.Color]::FromArgb(40, 36, 66)
    Line    = [System.Drawing.Color]::FromArgb(38, 42, 56)
    Text    = [System.Drawing.Color]::FromArgb(232, 234, 240)
    Muted   = [System.Drawing.Color]::FromArgb(150, 158, 178)
    Accent  = [System.Drawing.Color]::FromArgb(139, 92, 246)
    Accent2 = [System.Drawing.Color]::FromArgb(124, 58, 237)
    Red     = [System.Drawing.Color]::FromArgb(220, 38, 38)
    Green   = [System.Drawing.Color]::FromArgb(22, 163, 74)
    Blue    = [System.Drawing.Color]::FromArgb(37, 99, 235)
    Amber   = [System.Drawing.Color]::FromArgb(245, 158, 11)
    Black   = [System.Drawing.Color]::FromArgb(9, 9, 11)
}
$Letter = @{
    App    = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
    Head   = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
    Body   = New-Object System.Drawing.Font('Segoe UI', 10)
    Small  = New-Object System.Drawing.Font('Segoe UI', 8.75)
    Badge  = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
    Big    = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    Btn    = New-Object System.Drawing.Font('Segoe UI Semibold', 9.75)
}
$GamePalette = @(
    [System.Drawing.Color]::FromArgb(236, 72, 153), [System.Drawing.Color]::FromArgb(34, 197, 94),
    [System.Drawing.Color]::FromArgb(59, 130, 246), [System.Drawing.Color]::FromArgb(245, 158, 11),
    [System.Drawing.Color]::FromArgb(168, 85, 247), [System.Drawing.Color]::FromArgb(20, 184, 166),
    [System.Drawing.Color]::FromArgb(239, 68, 68)
)
function Get-GameColor([string]$name) {
    if (-not $name) { return [System.Drawing.Color]::FromArgb(100, 108, 128) }
    $i = 0; foreach ($g in @($script:Cfg.Games)) { if ($g.Naam -eq $name) { return $GamePalette[$i % $GamePalette.Count] }; $i++ }
    $sum = 0; foreach ($ch in $name.ToCharArray()) { $sum += [int]$ch }
    return $GamePalette[$sum % $GamePalette.Count]
}
$script:Brushes = @{}
function Get-Brush($color) {
    $k = $color.ToArgb()
    if (-not $script:Brushes.ContainsKey($k)) { $script:Brushes[$k] = New-Object System.Drawing.SolidBrush($color) }
    return $script:Brushes[$k]
}
function New-RoundPath([System.Drawing.Rectangle]$r, [int]$rad) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $rad * 2
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}
# Afgeronde hoeken voor knoppen en kaarten.
function Set-Round($ctrl, [int]$rad) {
    $apply = {
        param($s, $e)
        if ($s.Width -lt 2 -or $s.Height -lt 2) { return }
        $s.Region = New-Object System.Drawing.Region((New-RoundPath (New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)) $s.Tag))
    }
    $ctrl.Tag = $rad
    $ctrl.Add_Resize($apply)
    & $apply $ctrl $null
}
function Get-Lighter($c, [int]$n) { return [System.Drawing.Color]::FromArgb([math]::Min(255, $c.R + $n), [math]::Min(255, $c.G + $n), [math]::Min(255, $c.B + $n)) }
function New-Btn($parent, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $color, $font) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if (-not $color) { $color = $Kleur.Input }
    $b.BackColor = $color; $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatAppearance.MouseOverBackColor = (Get-Lighter $color 22)
    $b.FlatAppearance.MouseDownBackColor = (Get-Lighter $color 40)
    $b.Font = $(if ($font) { $font } else { $Letter.Btn })
    $b.UseVisualStyleBackColor = $false
    $parent.Controls.Add($b); Set-Round $b 8
    return $b
}
function New-Lbl($parent, [string]$text, [int]$x, [int]$y, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $l.Font = $(if ($font) { $font } else { $Letter.Small }); $l.ForeColor = $(if ($color) { $color } else { $Kleur.Muted }); $l.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($l); return $l
}
function New-Card($parent, [int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y); $p.Size = New-Object System.Drawing.Size($w, $h); $p.BackColor = $Kleur.Card
    $parent.Controls.Add($p); Set-Round $p 12
    return $p
}
function Set-Input($t) { $t.BackColor = $Kleur.Input; $t.ForeColor = $Kleur.Text; $t.BorderStyle = 'FixedSingle'; $t.Font = $Letter.Body }

# Schermafbeelding maken (alleen voor de website/handleiding, via CLIPPOSTER_SCREENSHOT).
function Save-Shot($frm, [string]$path) {
    $frm.Activate(); $frm.Refresh(); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400; [System.Windows.Forms.Application]::DoEvents()
    $b = $frm.Bounds
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    if ($env:CLIPPOSTER_SHOT_SCREEN) {
        $gr = [System.Drawing.Graphics]::FromImage($bmp); $gr.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size); $gr.Dispose()
    } else { $frm.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $b.Width, $b.Height))) }
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Clip-poster'
$form.ClientSize = New-Object System.Drawing.Size(1180, 770)
$form.MinimumSize = New-Object System.Drawing.Size(980, 730)
# Past het venster niet op het scherm (bijv. een laptop), dan zo groot als het scherm.
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($form.Width -gt $wa.Width -or $form.Height -gt $wa.Height) { $form.Size = New-Object System.Drawing.Size([math]::Min($form.Width, $wa.Width), [math]::Min($form.Height, $wa.Height)) }
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Kleur.Bg; $form.ForeColor = $Kleur.Text
$form.Font = $Letter.Body

# --- kop
$head = New-Object System.Windows.Forms.Panel
$head.Dock = 'Top'; $head.Height = 76; $head.BackColor = $Kleur.Card
$form.Controls.Add($head)
$logo = New-Object System.Windows.Forms.Panel
$logo.Location = New-Object System.Drawing.Point(20, 18); $logo.Size = New-Object System.Drawing.Size(40, 40); $logo.BackColor = $Kleur.Accent
$head.Controls.Add($logo); Set-Round $logo 10
$logo.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $pts = [System.Drawing.Point[]]@((New-Object System.Drawing.Point(15, 11)), (New-Object System.Drawing.Point(29, 20)), (New-Object System.Drawing.Point(15, 29)))
    $e.Graphics.FillPolygon((Get-Brush ([System.Drawing.Color]::White)), $pts)
})
$lblApp = New-Lbl $head 'Clip-poster' 70 12 $Letter.App $Kleur.Text
$lblSub = New-Lbl $head '' 73 46 $Letter.Small $Kleur.Muted
$pill = New-Object System.Windows.Forms.Label
$pill.AutoSize = $false; $pill.Size = New-Object System.Drawing.Size(270, 34); $pill.TextAlign = 'MiddleCenter'
$pill.Font = $Letter.Btn; $pill.ForeColor = [System.Drawing.Color]::White; $pill.Anchor = 'Top,Right'
$pill.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 290), 21)
$head.Controls.Add($pill); Set-Round $pill 17

# --- lijst met clips (links)
$cardL = New-Card $form 16 92 540 596
$cardL.Anchor = 'Top,Bottom,Left'
$script:View = 0
$viewBtns = @()
$vx = 12
foreach ($v in @('Wachtrij', 'Nog naar TikTok', 'Overgeslagen', 'Alles')) {
    $w = [System.Windows.Forms.TextRenderer]::MeasureText($v, $Letter.Btn).Width + 26
    $b = New-Btn $cardL $v $vx 12 $w 32 $Kleur.Input $Letter.Btn
    $viewBtns += $b; $vx += $w + 6
}
$lst = New-Object System.Windows.Forms.ListBox
$lst.Location = New-Object System.Drawing.Point(8, 54); $lst.Size = New-Object System.Drawing.Size(524, 534)
$lst.Anchor = 'Top,Bottom,Left,Right'
$lst.BorderStyle = 'None'; $lst.BackColor = $Kleur.Card; $lst.ForeColor = $Kleur.Text
$lst.DrawMode = 'OwnerDrawFixed'; $lst.ItemHeight = 58; $lst.IntegralHeight = $false
$cardL.Controls.Add($lst)
$lblEmpty = New-Lbl $cardL '' 24 80 $Letter.Body $Kleur.Muted
$lblEmpty.AutoSize = $false; $lblEmpty.Size = New-Object System.Drawing.Size(490, 120); $lblEmpty.BackColor = $Kleur.Card

$lst.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0 -or $e.Index -ge @($script:Shown).Count) { return }
    $c = @($script:Shown)[$e.Index]
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $r = $e.Bounds
    $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $g.FillRectangle((Get-Brush $Kleur.Card), $r)
    $inner = New-Object System.Drawing.Rectangle(($r.X + 2), ($r.Y + 3), ($r.Width - 6), ($r.Height - 6))
    if ($sel) { $g.FillPath((Get-Brush $Kleur.Sel), (New-RoundPath $inner 8)) }
    $x = $r.X + 12
    if ($script:View -eq 0) {
        [System.Windows.Forms.TextRenderer]::DrawText($g, [string]($e.Index + 1), $Letter.Head, (New-Object System.Drawing.Rectangle($x, $r.Y, 28, $r.Height)), $Kleur.Muted, [System.Windows.Forms.TextFormatFlags]'VerticalCenter,Right')
        $x += 36
    }
    # game-label
    $gname = if ($c.Game) { [string]$c.Game } else { 'Overig' }
    $gw = [System.Windows.Forms.TextRenderer]::MeasureText($gname, $Letter.Badge).Width + 12
    $br = New-Object System.Drawing.Rectangle($x, ($r.Y + 9), $gw, 19)
    $g.FillPath((Get-Brush (Get-GameColor ([string]$c.Game))), (New-RoundPath $br 9))
    [System.Windows.Forms.TextRenderer]::DrawText($g, $gname, $Letter.Badge, $br, [System.Drawing.Color]::White, [System.Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,NoPrefix,SingleLine')
    # YT / TT
    $chipX = $r.Right - 84
    foreach ($ch in @(@('YT', $c.Gepost, $Kleur.Red), @('TT', $c.TikTok, $Kleur.Black))) {
        $cr = New-Object System.Drawing.Rectangle($chipX, ($r.Y + 18), 32, 22)
        $fill = if ($ch[1]) { $ch[2] } else { $Kleur.Input }
        $g.FillPath((Get-Brush $fill), (New-RoundPath $cr 6))
        $fc = if ($ch[1]) { [System.Drawing.Color]::White } else { $Kleur.Muted }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $ch[0], $Letter.Badge, $cr, $fc, [System.Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter')
        $chipX += 38
    }
    # titel en tweede regel
    $tx = $x + $gw + 8
    $titleRect = New-Object System.Drawing.Rectangle($tx, ($r.Y + 7), ($chipX - 76 - $tx - 8), 22)
    [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$c.Title, $Letter.Head, $titleRect, $Kleur.Text, [System.Windows.Forms.TextFormatFlags]'EndEllipsis,NoPrefix,SingleLine,VerticalCenter')
    $sub = Split-Path $c.Mp4 -Leaf; $subColor = $Kleur.Muted
    if ($c.MuziekNodig) { $sub = 'Muziek nodig  -  ' + $sub; $subColor = $Kleur.Amber }
    elseif ($c.Probleem) { $sub = $c.Probleem; $subColor = $Kleur.Amber }
    $subRect = New-Object System.Drawing.Rectangle($x, ($r.Y + 32), ($chipX - 76 - $x - 8), 18)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $sub, $Letter.Small, $subRect, $subColor, [System.Windows.Forms.TextFormatFlags]'EndEllipsis,NoPrefix,SingleLine')
    $g.FillRectangle((Get-Brush $Kleur.Line), ($r.X + 12), ($r.Bottom - 1), ($r.Width - 24), 1)
})

# --- details en knoppen (rechts)
$cardR = New-Card $form 572 92 592 596
$cardR.Anchor = 'Top,Bottom,Left,Right'
$null = New-Lbl $cardR 'TITEL  (YouTube, max. 100 tekens)' 20 16 $Letter.Badge $Kleur.Muted
$txtTitle = New-Object System.Windows.Forms.TextBox
$txtTitle.Location = New-Object System.Drawing.Point(20, 36); $txtTitle.Size = New-Object System.Drawing.Size(552, 28); $txtTitle.MaxLength = 100
$txtTitle.Anchor = 'Top,Left,Right'; Set-Input $txtTitle
$cardR.Controls.Add($txtTitle)
$null = New-Lbl $cardR 'TEKST MET HASHTAGS  (beschrijving op YouTube, gekopieerd voor TikTok)' 20 74 $Letter.Badge $Kleur.Muted
$txt = New-Object System.Windows.Forms.TextBox
$txt.Multiline = $true; $txt.ScrollBars = 'Vertical'
$txt.Location = New-Object System.Drawing.Point(20, 94); $txt.Size = New-Object System.Drawing.Size(552, 118)
$txt.Anchor = 'Top,Left,Right'; Set-Input $txt
$cardR.Controls.Add($txt)
$null = New-Lbl $cardR 'ZICHTBAARHEID' 20 224 $Letter.Badge $Kleur.Muted
$cmbPrivacy = New-Object System.Windows.Forms.ComboBox
$cmbPrivacy.DropDownStyle = 'DropDownList'; $cmbPrivacy.FlatStyle = 'Flat'
$cmbPrivacy.BackColor = $Kleur.Input; $cmbPrivacy.ForeColor = $Kleur.Text
$cmbPrivacy.DrawMode = 'OwnerDrawFixed'; $cmbPrivacy.ItemHeight = 22
$cmbPrivacy.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $e.Graphics.FillRectangle((Get-Brush $(if ($sel) { $Kleur.Accent2 } else { $Kleur.Input })), $e.Bounds)
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $Letter.Body, $e.Bounds, $Kleur.Text, [System.Windows.Forms.TextFormatFlags]'VerticalCenter,Left')
})
[void]$cmbPrivacy.Items.AddRange(@('openbaar', 'verborgen (unlisted)', 'privé'))
$cmbPrivacy.Location = New-Object System.Drawing.Point(130, 220); $cmbPrivacy.Size = New-Object System.Drawing.Size(200, 28)
$privacyMap = @{ 'openbaar' = 'public'; 'verborgen (unlisted)' = 'unlisted'; 'privé' = 'private' }
$cmbPrivacy.SelectedIndex = [array]::IndexOf(@('public', 'unlisted', 'private'), [string]$script:Cfg.Privacy)
if ($cmbPrivacy.SelectedIndex -lt 0) { $cmbPrivacy.SelectedIndex = 0 }
$cardR.Controls.Add($cmbPrivacy)

$btnNext   = New-Btn $cardR 'Post volgende clip' 20 262 552 58 $Kleur.Accent $Letter.Big
$btnNext.Anchor = 'Top,Left,Right'
$lblNext = New-Lbl $cardR '' 22 324 $Letter.Small $Kleur.Muted
$lblNext.AutoSize = $false; $lblNext.Size = New-Object System.Drawing.Size(552, 18); $lblNext.AutoEllipsis = $true
$btnYt     = New-Btn $cardR 'Alleen YouTube (gekozen clip)' 20 348 272 40 $Kleur.Red
$btnTt     = New-Btn $cardR 'TikTok klaarzetten (gekozen clip)' 300 348 272 40 $Kleur.Black
$btnTtDone = New-Btn $cardR 'Staat op TikTok: klaar' 20 394 272 40 $Kleur.Green
$btnRonde  = New-Btn $cardR 'TikTok-ronde: alles een voor een' 300 394 272 40 $Kleur.Black
$btnAuto   = New-Btn $cardR '' 20 440 552 44 $Kleur.Blue
$btnAuto.Anchor = 'Top,Left,Right'
# Knoppen rechts schalen mee met de breedte van het venster.
function Set-RightLayout {
    $w = $cardR.ClientSize.Width - 40
    $half = [int](($w - 8) / 2)
    foreach ($row in @(@($btnYt, $btnTt, 348), @($btnTtDone, $btnRonde, 394))) {
        $row[0].SetBounds(20, $row[2], $half, 40); $row[1].SetBounds((28 + $half), $row[2], ($w - $half - 8), 40)
    }
    $lblNext.Width = $w
}
$cardR.Add_Resize({ Set-RightLayout })
$statusBox = New-Object System.Windows.Forms.Panel
$statusBox.Location = New-Object System.Drawing.Point(20, 496); $statusBox.Size = New-Object System.Drawing.Size(552, 86); $statusBox.BackColor = $Kleur.Input
$statusBox.MinimumSize = New-Object System.Drawing.Size(100, 36)
$statusBox.Anchor = 'Top,Bottom,Left,Right'
$cardR.Controls.Add($statusBox); Set-Round $statusBox 8
$status = New-Object System.Windows.Forms.Label
$status.Dock = 'Fill'; $status.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$status.Font = $Letter.Small; $status.ForeColor = $Kleur.Text; $status.BackColor = $Kleur.Input
$statusBox.Controls.Add($status)

# --- onderbalk
$bar = New-Object System.Windows.Forms.Panel
$bar.Dock = 'Bottom'; $bar.Height = 66; $bar.BackColor = $Kleur.Bg
$form.Controls.Add($bar)
$bx = 16
$tools = @{}
$tip = New-Object System.Windows.Forms.ToolTip
foreach ($t in @('Instellingen', 'YouTube koppelen', 'Clipsmap', 'Controle', 'Muziek', 'Cijfers', 'Telefoon', 'Opruimen', 'Logboek')) {
    $w = [System.Windows.Forms.TextRenderer]::MeasureText($t, $Letter.Btn).Width + 24
    $tools[$t] = New-Btn $bar $t $bx 14 $w 36 $Kleur.Card $Letter.Btn
    $bx += $w + 6
}
$btnSettings = $tools['Instellingen']; $btnSetup = $tools['YouTube koppelen']; $btnFolder = $tools['Clipsmap']
$btnCheck = $tools['Controle']; $btnMusic = $tools['Muziek']; $btnStats = $tools['Cijfers']
$tip.SetToolTip($btnFolder, 'De map met je clips openen in Verkenner')
$btnPhone = $tools['Telefoon']; $btnClean = $tools['Opruimen']; $btnLog = $tools['Logboek']
$tip.SetToolTip($btnClean, 'Clips die op YouTube en TikTok staan naar de map Gepost verplaatsen')
$tip.SetToolTip($btnMusic, 'Muziek onder clips zetten die dat nodig hebben (mp3-bestanden in de map Muziek)')
$tip.SetToolTip($btnPhone, 'Meldingen op je telefoon met de gratis app ntfy')
$tip.SetToolTip($btnCheck, 'Controleer volgorde, dubbele clips en ontbrekende teksten')

function Set-Status([string]$t) {
    $status.Text = $t
    $status.ForeColor = $(if ($t -match '^LET OP|mislukt|Fout|lukt niet') { $Kleur.Amber } else { $Kleur.Text })
    [System.Windows.Forms.Application]::DoEvents()
}

$script:All = @(); $script:Queue = @(); $script:Shown = @()
function Update-AutoButton {
    $t = Get-AutoTask
    $tijden = (@($script:Cfg.Tijden) -join ', ')
    if ($t -and $script:Cfg.AutoGepauzeerd) {
        $btnAuto.Text = 'Automatisch posten staat op PAUZE  -  klik om uit te zetten'
        $pill.Text = 'Automatisch: op pauze'; $pill.BackColor = $Kleur.Amber
    } elseif ($t) {
        $btnAuto.Text = ('Automatisch posten staat AAN ({0})  -  klik om uit te zetten' -f $tijden)
        $pill.Text = 'Automatisch posten: aan'; $pill.BackColor = $Kleur.Green
    } else {
        $btnAuto.Text = ('Automatisch posten aanzetten  ({0})' -f $tijden)
        $pill.Text = 'Automatisch posten: uit'; $pill.BackColor = $Kleur.Hover
    }
    $btnAuto.BackColor = $(if ($t) { $Kleur.Hover } else { $Kleur.Blue })
    $btnAuto.FlatAppearance.MouseOverBackColor = (Get-Lighter $btnAuto.BackColor 22)
}
function Update-ViewButtons {
    $x = 12
    for ($i = 0; $i -lt $viewBtns.Count; $i++) {
        $w = [System.Windows.Forms.TextRenderer]::MeasureText($viewBtns[$i].Text, $Letter.Btn).Width + 26
        $viewBtns[$i].SetBounds($x, 12, $w, 32); $x += $w + 6
        $col = if ($i -eq $script:View) { $Kleur.Accent2 } else { $Kleur.Input }
        $viewBtns[$i].BackColor = $col; $viewBtns[$i].FlatAppearance.MouseOverBackColor = (Get-Lighter $col 22)
    }
}
function Refresh-List {
    $script:All = @(Get-AllClips)
    $script:Queue = @(Get-Queue $script:All)
    $sel = $lst.SelectedIndex
    switch ($script:View) {
        0 { $script:Shown = $script:Queue }
        1 { $script:Shown = @($script:All | Where-Object { $_.Gepost -and -not $_.TikTok -and $_.YouTubeId -ne 'al eerder gepost' } | Sort-Object { Get-SortKey $_ }) }
        2 { $script:Shown = @($script:All | Where-Object { -not $_.Gepost -and ($_.MuziekNodig -or $_.Probleem) } | Sort-Object { Get-SortKey $_ }) }
        default { $script:Shown = @($script:All | Sort-Object { Get-SortKey $_ }) }
    }
    $lst.BeginUpdate(); $lst.Items.Clear()
    foreach ($c in $script:Shown) { [void]$lst.Items.Add([string]$c.Title) }
    $lst.EndUpdate()
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = [math]::Min([math]::Max($sel, 0), $lst.Items.Count - 1); $lblEmpty.Visible = $false }
    else {
        $txt.Text = ''; $txtTitle.Text = ''
        $lblEmpty.Text = switch ($script:View) {
            0 { "Geen clips in de wachtrij.`n`nZet een video met een .txt-bestand (zelfde naam, met de tekst en hashtags) in:`n" + $VandaagDir }
            1 { 'Alles wat op YouTube staat, staat ook op TikTok.' }
            2 { 'Er worden geen clips overgeslagen.' }
            default { "Nog geen clips gevonden in:`n" + $SocialsDir }
        }
        $lblEmpty.Visible = $true; $lblEmpty.BringToFront()
    }
    $tiktok = @($script:All | Where-Object { $_.Gepost -and -not $_.TikTok -and $_.YouTubeId -ne 'al eerder gepost' }).Count
    $skip = @($script:All | Where-Object { -not $_.Gepost -and ($_.MuziekNodig -or $_.Probleem) }).Count
    $kanaal = if ($script:Cfg.KanaalNaam) { [string]$script:Cfg.KanaalNaam + '   ' } else { '' }
    $lblSub.Text = ('{0}{1} in de wachtrij   {2} nog naar TikTok   {3} overgeslagen' -f $kanaal, $script:Queue.Count, $tiktok, $skip)
    $lblNext.Text = $(if ($script:Queue.Count) { 'Volgende: ' + $script:Queue[0].Title } else { 'De wachtrij is leeg.' })
    $viewBtns[1].Text = $(if ($tiktok) { 'Nog naar TikTok (' + $tiktok + ')' } else { 'Nog naar TikTok' })
    $viewBtns[2].Text = $(if ($skip) { 'Overgeslagen (' + $skip + ')' } else { 'Overgeslagen' })
    Update-AutoButton; Update-ViewButtons
    if ($script:Cfg.AutoGepauzeerd) { Set-Status ('LET OP: ' + $script:Cfg.AutoReden) }
    elseif (-not $status.Text -and (Test-Path -LiteralPath $LogFile)) { Set-Status ('Laatste melding: ' + [string](Get-Content -LiteralPath $LogFile -Tail 1 -Encoding UTF8)) }
    $lst.Invalidate()
}
function Set-View([int]$i) { $script:View = $i; $lst.SelectedIndex = -1; Refresh-List }
$viewBtns[0].Add_Click({ Set-View 0 }); $viewBtns[1].Add_Click({ Set-View 1 }); $viewBtns[2].Add_Click({ Set-View 2 }); $viewBtns[3].Add_Click({ Set-View 3 })

function Get-Selected {
    if ($lst.SelectedIndex -lt 0 -or $lst.SelectedIndex -ge @($script:Shown).Count) { [System.Windows.Forms.MessageBox]::Show('Kies eerst een clip in de lijst.') | Out-Null; return $null }
    return @($script:Shown)[$lst.SelectedIndex]
}

$lst.Add_SelectedIndexChanged({
    $lst.Invalidate()
    if ($lst.SelectedIndex -lt 0 -or $lst.SelectedIndex -ge @($script:Shown).Count) { return }
    $c = @($script:Shown)[$lst.SelectedIndex]
    $txtTitle.Text = $c.Title
    $txt.Text = $c.Text
    if ($c.Gepost -and $c.YouTubeId -ne 'al eerder gepost') { Set-Status ('Al op YouTube: https://youtube.com/shorts/{0}' -f $c.YouTubeId) }
    elseif (-not $script:Cfg.AutoGepauzeerd) { Set-Status ('Bestand: ' + $c.Mp4) }
})

# ---------------------------------------------------------------- instellingen (venster)
function Show-Settings([bool]$eerste) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Instellingen - Clip-poster'
    $d.ClientSize = New-Object System.Drawing.Size(660, 700)
    $d.StartPosition = 'CenterParent'; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.BackColor = $Kleur.Bg; $d.ForeColor = $Kleur.Text; $d.Font = $Letter.Body
    $card = New-Card $d 16 16 628 608
    $y = 16
    if ($eerste) {
        $w = New-Lbl $card 'Welkom! Stel de Clip-poster in voor jouw kanaal. Je kunt dit later altijd aanpassen.' 20 $y $Letter.Head $Kleur.Text
        $y += 34
    }
    function Add-Field([string]$label, [string]$hint, [string]$value, [int]$h) {
        $null = New-Lbl $card $label 20 $script:fy $Letter.Badge $Kleur.Muted
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(20, ($script:fy + 20)); $tb.Size = New-Object System.Drawing.Size(588, $(if ($h) { $h } else { 28 }))
        if ($h) { $tb.Multiline = $true; $tb.ScrollBars = 'Vertical' }
        Set-Input $tb; $tb.Text = $value
        $card.Controls.Add($tb)
        $script:fy += 20 + $tb.Height + 2
        if ($hint) { $null = New-Lbl $card $hint 20 $script:fy $Letter.Small $Kleur.Muted; $script:fy += 20 }
        $script:fy += 8
        return $tb
    }
    $script:fy = $y
    $tbKanaal = Add-Field 'NAAM VAN JE KANAAL' 'Alleen voor meldingen. Het kanaal zelf kies je bij "YouTube koppelen".' ([string]$script:Cfg.KanaalNaam) 0
    $tbRegel = Add-Field 'REGEL ONDER ELKE BESCHRIJVING' 'Bijvoorbeeld: Live op Twitch: https://twitch.tv/jouwnaam  (leeg = geen regel)' ([string]$script:Cfg.TwitchRegel) 0
    $mapNu = if ($script:Cfg.ClipsMap) { [string]$script:Cfg.ClipsMap } else { $SocialsDir }
    $tbMap = Add-Field 'MAP MET CLIPS' 'Hierin komen de mappen "Vandaag posten", "Gepost" en "Muziek".' $mapNu 0
    $tbMap.Width = 480
    $btnBrowse = New-Btn $card 'Bladeren' 508 ($tbMap.Top - 1) 100 30 $Kleur.Input $null
    $btnBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.SelectedPath = $tbMap.Text
        if ($fb.ShowDialog() -eq 'OK') { $tbMap.Text = $fb.SelectedPath }
    })
    $gamesTxt = (@($script:Cfg.Games) | Where-Object { $_ -and $_.Naam } | ForEach-Object { '{0}: {1}' -f $_.Naam, ((@($_.Tags) | ForEach-Object { ([string]$_).TrimStart('#') }) -join ', ') }) -join "`r`n"
    $tbGames = Add-Field 'GAMES  (een per regel:  Naam: hashtag, hashtag)' 'Voorbeeld:  Minecraft: minecraft, mc   -   de game wordt herkend aan de hashtags in je tekst.' $gamesTxt 84
    $tbRot = Add-Field 'OM EN OM POSTEN  (games, gescheiden door komma''s)' 'Leeg = alle games hierboven om en om. Andere games komen er af en toe tussen.' ((@($script:Cfg.Rotatie) | Where-Object { $_ }) -join ', ') 0
    $tbTijden = Add-Field 'POSTTIJDEN VOOR AUTOMATISCH POSTEN' 'Bijvoorbeeld: 12:07, 16:04, 19:06, 21:03  (net niet op het hele uur is rustiger bij YouTube)' (@($script:Cfg.Tijden) -join ', ') 0
    $chkGame = New-Object System.Windows.Forms.CheckBox
    $chkGame.Text = 'Clips zonder herkende game overslaan'; $chkGame.Checked = [bool]$script:Cfg.GameVerplicht
    $chkGame.Location = New-Object System.Drawing.Point(20, $script:fy); $chkGame.AutoSize = $true; $chkGame.ForeColor = $Kleur.Text
    $card.Controls.Add($chkGame); $script:fy += 28
    $chkOrig = New-Object System.Windows.Forms.CheckBox
    $chkOrig.Text = 'Regel "Origineel: Replay ..." verplicht (tegen dubbel posten van OBS-replays)'; $chkOrig.Checked = [bool]$script:Cfg.OrigineelVerplicht
    $chkOrig.Location = New-Object System.Drawing.Point(20, $script:fy); $chkOrig.AutoSize = $true; $chkOrig.ForeColor = $Kleur.Text
    $card.Controls.Add($chkOrig)
    $ok = New-Btn $d 'Opslaan' 404 636 240 46 $Kleur.Accent $Letter.Head
    $cancel = New-Btn $d 'Annuleren' 16 636 160 46 $Kleur.Card $null
    $ok.Add_Click({
        $tijden = @(($tbTijden.Text -split '[,;\s]+') | Where-Object { $_ })
        foreach ($t in $tijden) {
            $tmp = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($t, [string[]]@('HH:mm', 'H:mm'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$tmp)) {
                [System.Windows.Forms.MessageBox]::Show(('"{0}" is geen geldige tijd. Gebruik bijvoorbeeld 12:07.' -f $t), 'Instellingen') | Out-Null; return
            }
        }
        if (-not $tijden.Count) { [System.Windows.Forms.MessageBox]::Show('Vul minstens een posttijd in.', 'Instellingen') | Out-Null; return }
        $games = New-Object System.Collections.Generic.List[object]
        foreach ($l in ($tbGames.Text -split "`r?`n")) {
            if (-not $l.Trim()) { continue }
            $naam = $l; $tags = @()
            if ($l -match '^(.*?):(.*)$') { $naam = $Matches[1]; $tags = @(($Matches[2] -split '[,;\s]+') | ForEach-Object { $_.Trim().TrimStart('#').ToLower() } | Where-Object { $_ }) }
            $naam = $naam.Trim()
            if (-not $tags.Count) { $tags = @(($naam -replace '[^a-zA-Z0-9]', '').ToLower()) }
            if ($naam) { $games.Add([pscustomobject]@{ Naam = $naam; Tags = $tags }) }
        }
        $map = $tbMap.Text.Trim()
        try { if (-not (Test-Path -LiteralPath $map)) { New-Item -ItemType Directory -Path $map -Force | Out-Null } }
        catch { [System.Windows.Forms.MessageBox]::Show(('De map "{0}" kan niet worden gemaakt.' -f $map), 'Instellingen') | Out-Null; return }
        Reload-Cfg
        $oudeTijden = (@($script:Cfg.Tijden) -join ',')
        $script:Cfg.KanaalNaam = $tbKanaal.Text.Trim()
        $script:Cfg.TwitchRegel = $tbRegel.Text.Trim()
        $script:Cfg.ClipsMap = $(if ($map -eq (Join-Path $Desktop 'Clips voor socials')) { '' } else { $map })
        $script:Cfg.Games = $games.ToArray()
        $script:Cfg.Rotatie = @(($tbRot.Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $script:Cfg.Tijden = $tijden
        $script:Cfg.GameVerplicht = $chkGame.Checked
        $script:Cfg.OrigineelVerplicht = $chkOrig.Checked
        $script:Cfg.Ingesteld = $true
        Save-Cfg; Set-Folders
        foreach ($sub in @($VandaagDir, $GepostDir, $MuziekDir)) { if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null } }
        # Andere posttijden? Dan de Windows-taak bijwerken.
        if ((Get-AutoTask) -and $oudeTijden -ne ($tijden -join ',')) { try { Set-AutoTask $true } catch { } }
        $d.DialogResult = 'OK'; $d.Close()
    })
    $cancel.Add_Click({ $d.Close() })
    if ($env:CLIPPOSTER_SCREENSHOT_SETTINGS) {
        $st = New-Object System.Windows.Forms.Timer; $st.Interval = 1200
        $st.Add_Tick({ $st.Stop(); Save-Shot $d $env:CLIPPOSTER_SCREENSHOT_SETTINGS; $d.Close() })
        $d.Add_Shown({ $st.Start() })
    }
    return ($d.ShowDialog($form) -eq 'OK')
}

# ---------------------------------------------------------------- uploaden vanuit het venster
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
        $why = if ($c.MuziekNodig) { 'stream met slecht geluid, er moet nog muziek onder' } else { $c.Probleem }
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
    Set-View 0
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
            if (-not (Test-Path -LiteralPath $TokenFile)) { Set-Status 'Koppel eerst YouTube (knop "YouTube koppelen" onderaan).'; return }
            Set-AutoTask $true
            Set-Status ('Automatisch posten staat aan. Elke dag om {0} gaat de volgende clip op YouTube, ook als dit venster dicht is (de pc moet aan staan). TikTok-clips verschijnen bij "Nog naar TikTok".' -f (@($script:Cfg.Tijden) -join ', '))
        }
    } catch { Set-Status ('Automatisch posten instellen mislukt: ' + $_.Exception.Message) }
    Refresh-List
})
$btnMusic.Add_Click({
    try {
        $todo = @($script:All | Where-Object { $_.MuziekNodig -and -not $_.Gepost -and -not $_.Probleem }).Count
        if (-not $todo) { Set-Status 'Er zijn geen clips die nog muziek nodig hebben. (Dat stel je per stream in met EchoDatums in config.json.)'; return }
        $ff = Find-Ffmpeg
        if (-not $ff) {
            $a = [System.Windows.Forms.MessageBox]::Show("Voor muziek onder de clips is het gratis programma ffmpeg nodig.`n`nNu installeren via winget (de officiële Windows-pakketbron, pakket Gyan.FFmpeg, ongeveer 100 MB)?", 'ffmpeg installeren', 'YesNo')
            if ($a -ne 'Yes') { return }
            Set-Status 'ffmpeg wordt geïnstalleerd... (dit kan een paar minuten duren)'
            $ff = Install-Ffmpeg
        }
        $a = [System.Windows.Forms.MessageBox]::Show(("Muziek zetten onder {0} clips?`n`nDe muziek komt uit de map:`n{1}`n`nDe nieuwe versies komen in 'Vandaag posten' en gaan daarna vanzelf in de wachtrij. De originelen blijven staan." -f $todo, $MuziekDir), 'Muziek eronder', 'YesNo')
        if ($a -ne 'Yes') { return }
        $n = Invoke-MusicBatch $todo
        Set-Status ('{0} clips hebben nu muziek en staan in de wachtrij.' -f $n)
    } catch { Set-Status ('Muziek toevoegen mislukt: ' + $_.Exception.Message) }
    Refresh-List
})
$btnStats.Add_Click({
    try { Set-Status 'Cijfers ophalen bij YouTube...'; $txtS = Format-Stats (Get-YouTubeStats); Set-Status ''; [System.Windows.Forms.MessageBox]::Show($txtS, 'Cijfers') | Out-Null }
    catch { Set-Status ('Cijfers ophalen mislukt: ' + $_.Exception.Message + ' (log eventueel opnieuw in via YouTube koppelen.)') }
})
$btnPhone.Add_Click({
    $topic = [string]$script:Cfg.NtfyTopic
    $msg = "Meldingen op je telefoon:`n`n1. Installeer de gratis app 'ntfy' (Play Store / App Store).`n2. Tik op + en abonneer je op dit onderwerp:`n`n      $topic`n`n3. Klik hierna op OK: dan stuurt de Clip-poster een testmelding.`n`nJe krijgt een melding bij elke post, als iets mislukt, als posten op pauze gaat en als de wachtrij leeg is.`n(Het onderwerp staat ook op je klembord. Houd het geheim: iedereen die het kent kan je meldingen lezen.)"
    Set-Clipboard -Value $topic
    [System.Windows.Forms.MessageBox]::Show($msg, 'Telefoon') | Out-Null
    if (Send-PhoneCore 'Clip-poster: testmelding' 'Het werkt! Vanaf nu krijg je hier meldingen van de Clip-poster.') { Set-Status ('Testmelding verstuurd naar onderwerp ' + $topic) }
    else { Set-Status 'Testmelding versturen lukte niet. Is er internet?' }
})
$btnCheck.Add_Click({ [System.Windows.Forms.MessageBox]::Show(((Get-Checks $script:All) -join "`n`n"), 'Controle') | Out-Null })
$btnLog.Add_Click({ if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $LogFile) } else { Set-Status 'Het logboek is nog leeg.' } })
$btnFolder.Add_Click({
    foreach ($sub in @($SocialsDir, $VandaagDir)) { if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null } }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $SocialsDir)
})
$btnSettings.Add_Click({ if (Show-Settings $false) { Set-Status 'Instellingen opgeslagen.'; Refresh-List } })
$HandleidingUrl = 'https://freed-cloud.github.io/clip-poster/handleiding.html'
$btnSetup.Add_Click({
    $msg = "YouTube koppelen (eenmalig, ongeveer 10 minuten):`n`n1. Maak in Google Cloud een gratis project met de YouTube Data API v3.`n2. Maak een OAuth-client van het type 'Desktop-app' en download het bestand client_secret.json.`n3. Kies dat bestand zo meteen hier.`n4. Log in bij Google en kies het kanaal {0}.`n`nStap voor stap met plaatjes: Ja = handleiding openen in je browser.`nNee = ik heb client_secret.json al, verder." -f (Get-KanaalTekst)
    $a = [System.Windows.Forms.MessageBox]::Show($msg, 'YouTube koppelen', 'YesNoCancel')
    if ($a -eq 'Cancel') { return }
    if ($a -eq 'Yes') { Start-Process $HandleidingUrl; return }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'client_secret (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    Copy-Item -LiteralPath $dlg.FileName -Destination $SecretFile -Force
    Remove-Item -LiteralPath $TokenFile -ErrorAction SilentlyContinue
    try {
        $null = Get-AccessToken
        $script:Cfg.AutoGepauzeerd = $false; $script:Cfg.AutoReden = ''; Save-Cfg
        Set-Status 'YouTube is gekoppeld. Bij de eerste upload onthoudt de Clip-poster op welk kanaal hij komt.'
    } catch { Set-Status ('Koppelen mislukt: ' + $_.Exception.Message) }
    Refresh-List
})

$form.Add_Shown({
    Refresh-List
    if (-not $script:Cfg.Ingesteld -and -not $env:CLIPPOSTER_SCREENSHOT) {
        if (Show-Settings $true) { Set-Status "Klaar! Zet je clips (video + .txt met dezelfde naam) in de map 'Vandaag posten' en klik daarna op 'YouTube koppelen'."; Refresh-List }
    }
    if ($env:CLIPPOSTER_SCREENSHOT) {
        if ($lst.Items.Count -gt 1) { $lst.SelectedIndex = 1 }
        Set-Status 'Op YouTube gezet (public) op kanaal "playingparentsnl": https://youtube.com/shorts/...   TikTok staat klaar: sleep de video naar de uploadpagina en plak de tekst (Ctrl+V).'
        $script:ShotTimer = New-Object System.Windows.Forms.Timer; $script:ShotTimer.Interval = 1500
        $script:ShotTimer.Add_Tick({
            $script:ShotTimer.Stop()
            Save-Shot $form $env:CLIPPOSTER_SCREENSHOT
            if ($env:CLIPPOSTER_SCREENSHOT_SETTINGS) { [void](Show-Settings $false) }
            $form.Close()
        })
        $script:ShotTimer.Start()
    }
})
$form.Add_FormClosing({ if ($script:Job) { Stop-Job $script:Job -ErrorAction SilentlyContinue } })
[void]$form.ShowDialog()
