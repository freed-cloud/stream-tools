# Tests voor de Clip-poster. Draait op Windows PowerShell 5.1, PowerShell 7 en Linux (pwsh).
# Gebruik:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
# Exitcode 0 = alles geslaagd, 1 = er is iets mis.
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Check($cond, $msg) { if ($cond) { "  OK   $msg" } else { "  FOUT $msg"; $script:fails++ } }
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'ClipPoster\ClipPoster.ps1'
if (-not (Test-Path $src)) { $src = Join-Path $repo 'ClipPoster/ClipPoster.ps1' }
$py = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
function New-TestRoot([string]$name) {
    $root = Join-Path ([IO.Path]::GetTempPath()) $name
    & $py (Join-Path $PSScriptRoot 'maak_testmappen.py') $root | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'maak_testmappen.py mislukt' }
    # Net als op de stream-pc: een bestaande installatie van versie 4 (overstap naar versie 5 wordt zo meegetest).
    $app = Join-Path $root 'AppData/ClipPoster'
    New-Item -ItemType Directory -Force $app | Out-Null
    '{"Versie":4,"Privacy":"public"}' | Set-Content -LiteralPath (Join-Path $app 'config.json') -Encoding UTF8
    return $root
}
"PowerShell $($PSVersionTable.PSVersion) op $([Environment]::OSVersion.VersionString)"
$t=$null;$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$t,[ref]$e)
Check ($e.Count -eq 0) "syntax ($($e.Count) fouten) $($e | % { $_.Message + ' r' + $_.Extent.StartLineNumber })"

"=================== Wachtrij, titels, status ==================="
$env:CLIPPOSTER_TESTROOT = New-TestRoot 'clipposter-test-1'
. $src -GeenVenster

"== Titels uit tekst"
Get-TitleFromText "Rustig boodschappen doen? Niet bij ons! 🛒💥 Papa neemt de trap`n`n#gta6" 'GTA 6'
Get-TitleFromText "Klein kamertje, grote ruzie 😂`n#gta6" 'GTA 6'
Get-TitleFromText "Nog 9 seconden op de klok en papa ligt nog steeds verstopt. Geduld is ook een skill 😎⏱️" 'Arma Reforger'
Get-TitleFromText "'You are capturing this base!' – papa op z'n buik, mama aan het juichen." 'Arma Reforger'
Check ((Get-MomentKey 'Replay 2026-11-19 16-47-23 moment 15 - staand') -eq '2026-11-19 16-47-23 m15') 'momentsleutel'
Check ((Get-MomentKey 'Replay 2026-11-08 22-14-12 - tekst') -eq '2026-11-08 22-14-12') 'momentsleutel zonder moment'

"== AI-koppeling"
$ai = Get-AiTitleIndex
Check ($ai['2026-11-16 15-14-01 m01'].Title -eq 'Op patrouille door de havenstad') 'Arma 01 exact'
Check ($ai['2026-11-18 22-05-45 m01'].Title -eq 'Wachten onder de tent') 'Arma 30 (klein verschil)'
Check ($ai['2026-11-18 22-05-45 m06'].Title -eq 'Bestorming van de basis') 'Arma 35'
Check ($ai['2026-11-19 16-47-23 m26'].Title -eq 'Jason in de slaapkamer') 'GTA 28 zonder MUZIEK'
Check ($ai['2026-11-19 16-47-23 m08'].Title -eq 'Inbreken bij nacht') 'GTA 10 klein verschil'
Check ($ai['2026-11-18 22-05-45 m07'].Game -eq 'Fall Guys') 'Fall Guys koppeling'
"   gekoppeld: $($ai.Count)"

"== Alle clips"
$all = @(Get-AllClips)
"   totaal: $($all.Count)"
$v = @($all | ? Bron -eq 'Vandaag posten')
Check ($v.Count -eq 5) 'vijf uit Vandaag posten'
Check (@($all | ? Key -eq '2026-11-19 16-47-23 m15').Count -eq 1) 'm15 maar 1 keer (Vandaag wint)'
Check (($all | ? Key -eq '2026-11-19 16-47-23 m15').Bron -eq 'Vandaag posten') 'm15 komt uit Vandaag posten'
Check (($all | ? Key -eq '2026-11-19 16-47-23 m01').MuziekNodig) 'GTA 19 nov zonder muziek overgeslagen'
Check (-not ($all | ? Key -eq '2026-11-21 09-10-44 m01').MuziekNodig) 'GTA 21 nov mag'
Check ((($all | ? Key -eq '2026-11-21 09-10-44 m01').Title) -like '*| GTA 6') 'titel GTA 21 nov'
Check (($all | ? Key -eq '2026-11-23 20-00-00 m01').Probleem) 'clip zonder tekst = probleem'
Check (($all | ? Key -eq '2026-11-08 22-14-12').Gepost) 'veldhospitaal al gepost'
Check (($all | ? Key -eq '2026-11-18 22-05-45 m07').Game -eq 'Fall Guys') 'Fall Guys herkend'
Check ((($all | ? Key -eq '2026-11-16 15-14-01 m01').Title) -like 'Papa sjouwt de radio door de hele stad*| Arma Reforger') 'Arma titel uit eigen tekst'
Check (@($all | ? { $_.Title -match '\.\.$' -and $_.Title -notmatch '\.\.\.$' }).Count -eq 0) 'geen titels met twee puntjes'
Check (@($all | ? { $_.Title -match '(MUZIEK|staand)' }).Count -eq 0) 'geen MUZIEK/staand in titels'
Check ((($all | ? Bron -eq 'Vandaag posten' | ? Nr -eq 11).Title) -eq 'Het gaat mis in het pakhuis | GTA 6') 'Vandaag titel uit txt'
Check (-not (($all | ? Bron -eq 'Vandaag posten' | ? Nr -eq 11).Text -match 'Muziek:|Origineel')) 'voetnoot niet in tekst'
Check (@($all | ? { $_.Title.Length -gt 100 }).Count -eq 0) 'titels max 100'

"== Wachtrij"
$q = @(Get-Queue $all)
$i=0; foreach ($c in $q) { $i++; if ($i -le 14) { '{0,3}. [{1}] {2}   <{3}>' -f $i,$c.Game,$c.Title,$c.Key } }
"   ... totaal in wachtrij: $($q.Count)"
Check ($q[0].Game -eq 'GTA 6' -and $q[1].Game -eq 'Arma Reforger' -and $q[2].Game -ne $q[1].Game) 'om en om'
$gta = @($q | ? Game -eq 'GTA 6'); $sorted = @($gta | Sort-Object Key)
Check ((($gta.Key) -join ',') -eq (($sorted.Key) -join ',')) 'GTA oud naar nieuw'
$arma = @($q | ? Game -eq 'Arma Reforger'); $s2=@($arma | Sort-Object Key)
Check ((($arma.Key) -join ',') -eq (($s2.Key) -join ',')) 'Arma oud naar nieuw'
Check (@($q | ? { $_.MuziekNodig -or $_.Probleem -or $_.Gepost }).Count -eq 0) 'niets overgeslagens in de rij'
Check (@($q.Key | Select-Object -Unique).Count -eq $q.Count) 'geen dubbele in de rij'

"== Volgende na Arma begint met GTA en omgekeerd"
$script:Cfg.LaatsteGame = 'GTA 6'; $q2 = @(Get-Queue $all); Check ($q2[0].Game -eq 'Arma Reforger') 'na GTA komt Arma'
$script:Cfg.LaatsteGame = 'Arma Reforger'; $q3 = @(Get-Queue $all); Check ($q3[0].Game -ne 'Arma Reforger') 'na Arma geen Arma'

"== Upload verwerken (nep-antwoord)"
$c = $q[0]
$msg = Complete-Upload $c.Key $c.Game 'OK|abc123|public|UC0EU7Am-oiUnpg_yv9FHJkQ|playingparentsnl'
$msg
$all2 = @(Get-AllClips); $q4=@(Get-Queue $all2)
Check (($all2 | ? Key -eq $c.Key).Gepost) 'na upload gemarkeerd'
Check (-not ($q4.Key -contains $c.Key)) 'niet meer in de wachtrij'
Check ($q4[0].Game -ne $c.Game) 'volgende is andere game'
Check (-not $script:Cfg.AutoGepauzeerd) 'goed kanaal: geen pauze'
$m2 = Complete-Upload $q4[0].Key $q4[0].Game 'OK|zzz|public|UCandere|Freddy Den Haan'
$m2
Check ($script:Cfg.AutoGepauzeerd) 'verkeerd kanaal: pauze'
$all3 = @(Get-AllClips); $q5 = @(Get-Queue $all3)
Check ($q5.Key -contains $q4[0].Key) 'verkeerd kanaal: clip blijft in de wachtrij'
$script:Cfg.AutoGepauzeerd = $false; $script:Cfg.AutoReden=''; Save-Cfg

"== Dubbel posten voorkomen (taak post terwijl venster open is)"
$voor = @(Get-Queue (Get-AllClips))[0]
# de 'taak' schrijft direct in het statusbestand
$st = Get-Content $StatusFile -Raw | ConvertFrom-Json
$st | Add-Member -NotePropertyName $voor.Key -NotePropertyValue ([pscustomobject]@{youtube='taak1';kanaal='UC0EU7Am-oiUnpg_yv9FHJkQ';tiktok=$false;datum='';verkeerd=''}) -Force
$st | ConvertTo-Json -Depth 6 | Set-Content $StatusFile -Encoding UTF8
$na = @(Get-Queue (Get-AllClips))
Check (-not ($na.Key -contains $voor.Key)) 'venster ziet post van de taak'
$null = Complete-Upload $na[0].Key $na[0].Game 'OK|venster1|public|UC0EU7Am-oiUnpg_yv9FHJkQ|playingparentsnl'
$st2 = Get-Content $StatusFile -Raw | ConvertFrom-Json
Check ($st2.($voor.Key).youtube -eq 'taak1' -and $st2.($na[0].Key).youtube -eq 'venster1') 'beide posts bewaard'

"== Slot"
Check (Enter-UploadLock) 'slot pakken'
Check (-not (Enter-UploadLock)) 'tweede keer geweigerd'
Exit-UploadLock
Check (Enter-UploadLock) 'na vrijgeven weer te pakken'
Exit-UploadLock

"== Prive wordt gemeld"
$q6 = @(Get-Queue (Get-AllClips))
$pm = Complete-Upload $q6[0].Key $q6[0].Game 'OK|p1|private|UC0EU7Am-oiUnpg_yv9FHJkQ|playingparentsnl' 'public'
Check ($pm -match 'privé' -and $script:Cfg.AutoGepauzeerd) 'privé gemeld en pauze'
$script:Cfg.AutoGepauzeerd = $false; $script:Cfg.AutoReden=''; Save-Cfg

"== Fall Guys na elke 6 posts, ook als de rij steeds opnieuw wordt gebouwd"
$script:Cfg.SindsExtra = 0; $script:Cfg.LaatsteGame=''; Save-Cfg
$volgorde = @()
for ($k=0; $k -lt 14; $k++) { $qq=@(Get-Queue (Get-AllClips)); $x=$qq[0]; $volgorde += $x.Game; $null = Complete-Upload $x.Key $x.Game ("OK|sim$k|public|UC0EU7Am-oiUnpg_yv9FHJkQ|playingparentsnl") }
"   " + (($volgorde | % { $_.Substring(0,4) }) -join ' ')
Check ($volgorde[6] -eq 'Fall Guys' -and $volgorde[13] -eq 'Fall Guys') 'Fall Guys op plek 7 en 14'
$hoofd = @($volgorde | ? { $_ -ne 'Fall Guys' }); $wissel=$true
for ($k=1;$k -lt $hoofd.Count;$k++){ if ($hoofd[$k] -eq $hoofd[$k-1]) { $wissel=$false } }
Check $wissel 'GTA en Arma wisselen echt af bij echt posten'
"== Titels in de wachtrij"
@(Get-Queue (Get-AllClips)) | % { "   [$($_.Game)] $($_.Title)" }
$m3 = Complete-Upload 'x' 'GTA 6' 'FOUT|quotaExceeded'
Check ($m3 -like 'Upload mislukt*') 'fout wordt gemeld'

"== Controle"
Get-Checks $all2 | % { "   - $_" }

"== Naar Gepost na TikTok"
$cl = $all2 | ? Key -eq $c.Key
(Get-State $c.Key).tiktok = $true; Save-Status
Move-ToGepost $cl
Check (-not (Test-Path -LiteralPath $cl.Mp4) -and (Test-Path -LiteralPath (Join-Path $GepostDir (Split-Path $cl.Mp4 -Leaf)))) 'video verplaatst'
Check (Test-Path -LiteralPath (Join-Path $GepostDir (Split-Path $cl.Txt -Leaf))) 'tekst verplaatst'

"== Instellingen en status bewaard"
Check (Test-Path $StatusFile) 'statusbestand'
$re = Get-Content $StatusFile -Raw | ConvertFrom-Json
Check ($re.($c.Key).youtube -eq 'abc123') 'status leest terug'
"== Extra controles na review"
$tk = Get-TitleFromText "Even tanken... en dan ineens alles in het rood 🚗⛽😵 Dat was niet de bedoeling, schat!`n#gta6" 'GTA 6'
"   $tk"
Check ($tk -notmatch '[^.]\.\.( |$)') 'geen twee puntjes bij Even tanken'
# Fall Guys gepost: daarna geen twee keer dezelfde hoofdgame
$script:Cfg.LaatsteGame='GTA 6'; Save-Cfg
$fq = @(Get-Queue (Get-AllClips)) | ? Game -eq 'Fall Guys' | Select-Object -First 1
if ($fq) { $null = Complete-Upload $fq.Key $fq.Game 'OK|fg1|public|UC0EU7Am-oiUnpg_yv9FHJkQ|playingparentsnl'; Check ((@(Get-Queue (Get-AllClips))[0]).Game -eq 'Arma Reforger') 'na Fall Guys gaat de rotatie verder (geen 2x GTA)' }
# Vandaag zonder Origineel-regel = overgeslagen
$vt = Get-ChildItem -LiteralPath $VandaagDir -Filter '*.txt' | Select-Object -First 1
$tekst = Get-Content -LiteralPath $vt.FullName -Raw; ($tekst -replace '(?m)^Origineel:.*$','') | Set-Content -LiteralPath $vt.FullName -Encoding UTF8
$vc = @(Get-AllClips) | ? { $_.Txt -eq $vt.FullName }
Check ($vc.Probleem -match 'Origineel') 'Vandaag zonder Origineel wordt overgeslagen'
# mislukt 3x -> overgeslagen
$x = @(Get-Queue (Get-AllClips))[0]
1..3 | % { $null = Complete-Upload $x.Key $x.Game 'FOUT|invalidTitle' }
Check (-not (@(Get-Queue (Get-AllClips)).Key -contains $x.Key)) 'na 3 fouten uit de rij'
$null = Complete-Upload $x.Key $x.Game 'FOUT|quotaExceeded'
# kapot statusbestand -> stoppen, niet alles opnieuw posten
Remove-Item ($StatusFile + '.bak') -ErrorAction SilentlyContinue
'{ kapot' | Set-Content $StatusFile
$gestopt = $false; try { $null = Get-AllClips } catch { $gestopt = $true }
Check $gestopt 'kapot statusbestand: stopt in plaats van alles opnieuw'

"=================== Muziek (ffmpeg), Twitch-regel, TikTok, cijfers ==================="
$env:CLIPPOSTER_TESTROOT = New-TestRoot 'clipposter-test-2'
. $src -GeenVenster
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    "  (ffmpeg niet gevonden: muziektests overgeslagen)"
} else {
# echte staande video met geluid onder een echo-moment, en een zonder geluid
$D = $SocialsDir
$null = Invoke-Native 'ffmpeg' @('-loglevel','error','-y','-f','lavfi','-i','testsrc=size=540x960:rate=30','-f','lavfi','-i','sine=frequency=440','-t','8','-c:v','libx264','-c:a','aac','-shortest',(Join-Path $D 'Replay 2026-11-19 16-47-23 moment 01 - staand.mp4'))
$null = Invoke-Native 'ffmpeg' @('-loglevel','error','-y','-f','lavfi','-i','testsrc=size=540x960:rate=30','-t','6','-c:v','libx264',(Join-Path $D 'Replay 2026-11-19 16-47-23 moment 03 - staand.mp4'))
$null = Invoke-Native 'ffmpeg' @('-loglevel','error','-y','-f','lavfi','-i','testsrc=size=540x960:rate=30','-f','lavfi','-i','sine=frequency=500','-t','5','-c:v','libx264','-c:a','aac','-shortest',(Join-Path $D 'Replay 2026-11-19 16-47-23 moment 08 - staand.mp4'))
New-Item -ItemType Directory -Force $MuziekDir | Out-Null
$null = Invoke-Native 'ffmpeg' @('-loglevel','error','-y','-f','lavfi','-i','sine=frequency=220','-t','4',(Join-Path $MuziekDir 'Kick It - Anno Domini Beats.mp3'))
$null = Invoke-Native 'ffmpeg' @('-loglevel','error','-y','-f','lavfi','-i','sine=frequency=330','-t','4',(Join-Path $MuziekDir 'Red - Anno Domini Beats.mp3'))
$ff = Find-Ffmpeg; Check ($ff) "ffmpeg gevonden: $ff"
$voor = @(Get-Queue (Get-AllClips) | ? Game -eq 'GTA 6').Count
$n = Invoke-MusicBatch 3
Check ($n -eq 3) "3 clips van muziek voorzien"
Get-ChildItem $VandaagDir | ? Name -match '^(1[5-9]|2\d) ' | % { "   nieuw: $($_.Name)" }
$nieuw = Get-ChildItem $VandaagDir -Filter '*.mp4' | Sort-Object Name | ? { $_.Name -match 'Bellen in Vice City|telefoon|Bellen' } | Select-Object -First 1
$nieuw = Get-ChildItem $VandaagDir -Filter '15 - *.mp4' | Select-Object -First 1
$info = (Invoke-Native (Find-Ffprobe $ff) @('-v','error','-show_entries','stream=codec_type,duration','-of','csv=p=0',$nieuw.FullName)).Out
"   streams: $($info -join ' ; ')"
Check (($info -join ' ') -match 'audio') 'nieuwe video heeft geluid'
$d = (Get-MediaDuration $ff $nieuw.FullName)
Check ($d -gt 7 -and $d -lt 9) "lengte gelijk aan origineel ($d s) ondanks kortere muziek"
$txt = Get-Content ($nieuw.FullName -replace '\.mp4$','.txt') -Raw
Check ($txt -match 'YOUTUBE-TITEL:' -and $txt -match 'Origineel: Replay 2026-11-19 16-47-23 moment 01') 'tekstbestand met titel en origineel'
$zonder = Get-ChildItem $VandaagDir -Filter '16 - *.mp4' | Select-Object -First 1
$i2 = (Invoke-Native (Find-Ffprobe $ff) @('-v','error','-show_entries','stream=codec_type','-of','csv=p=0',$zonder.FullName)).Out
Check (($i2 -join ' ') -match 'audio') 'clip zonder geluid krijgt muziek'
$all = @(Get-AllClips); $q=@(Get-Queue $all)
$na = @($q | ? Game -eq 'GTA 6').Count
Check ($na -eq $voor + 3) "GTA in wachtrij: $voor -> $na"
Check (-not (($all | ? Key -eq '2026-11-19 16-47-23 m01').MuziekNodig)) 'moment 01 heeft nu muziek (Vandaag wint)'
Check (@($all | ? Key -eq '2026-11-19 16-47-23 m01').Count -eq 1) 'geen dubbel moment'
$tr = @(Get-ChildItem $VandaagDir -Filter '*.txt' | ? Name -match '^1[5-7] - ' | Sort-Object Name | % { ((Get-Content $_.FullName -Raw) -split "`n" | ? { $_ -like 'Muziek:*' }) })
"   $($tr -join ' / ')"
Check ($tr[0] -ne $tr[1] -and $tr[0] -eq $tr[2]) 'muziek wisselt per clip'

"== Geen deeltijdbestanden achtergebleven"
Check (@(Get-ChildItem -LiteralPath $SocialsDir -Filter '*.bezig.mp4' -ErrorAction SilentlyContinue).Count -eq 0) 'geen .bezig.mp4'
}
"== Twitch-regel"
$m = New-UploadMeta 'Titel' "Tekst`n#gta6" 'public' | ConvertFrom-Json
Check ($m.snippet.description -match 'twitch\.tv/playingparentsnl') 'Twitch-link in beschrijving'
$m2 = New-UploadMeta 'Titel' "Kijk op twitch.tv/playingparentsnl #gta6" 'public' | ConvertFrom-Json
Check (([regex]::Matches($m2.snippet.description,'twitch\.tv').Count) -eq 1) 'niet dubbel als hij er al staat'
"== TikTok-planning"
$s1 = Get-NextTikTokSlot; "   eerste: $s1"
$script:Cfg.TikTokLaatsteSlot = $s1.ToString('yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)
$s2 = Get-NextTikTokSlot; "   tweede: $s2"
Check ($s2 -gt $s1) 'tweede tijd na de eerste'
$script:Cfg.TikTokLaatsteSlot = (Get-Date).AddDays(11).ToString('yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)
Check ($null -eq (Get-NextTikTokSlot)) 'niet verder dan 10 dagen'
"== Cijfers (nepdata)"
$rows = 1..9 | % { [pscustomobject]@{Titel="Clip $_";Game=@('GTA 6','Arma Reforger')[$_ % 2];Uur=@(12,16,19)[$_ % 3];Dag='za';Views=$_*10;Likes=1;Id="x$_"} }
Format-Stats $rows
"== Telefoon (niet echt verstuurd in test)"
$null = Complete-Upload 'k' 'GTA 6' 'FOUT|iets'
Check ($script:PhoneLog.Count -ge 1) "melding gemaakt: $($script:PhoneLog[-1])"
Check ($script:Cfg.NtfyTopic -like 'playingparentsnl-*') "onderwerp: $($script:Cfg.NtfyTopic)"

"=================== Nieuwe gebruiker (gedownload, nog niets ingesteld) ==================="
$root3 = Join-Path ([IO.Path]::GetTempPath()) 'clipposter-test-3'
Remove-Item -Recurse -Force $root3 -ErrorAction SilentlyContinue
$env:CLIPPOSTER_TESTROOT = $root3
. $src -GeenVenster
Check (-not $script:Cfg.Ingesteld) 'instelscherm moet nog'
Check (-not $script:Cfg.KanaalId -and -not $script:Cfg.TwitchRegel -and -not @($script:Cfg.Rotatie).Count) 'geen kanaal, Twitch-regel of rotatie van playingparentsnl'
Check ($script:Cfg.NtfyTopic -like 'clipposter-*') "eigen meldingsonderwerp: $($script:Cfg.NtfyTopic)"
New-Item -ItemType Directory -Force $VandaagDir | Out-Null
function Nieuw([string]$naam, [string]$tekst) {
    [IO.File]::WriteAllBytes((Join-Path $VandaagDir ($naam + '.mp4')), [byte[]](1..200))
    [IO.File]::WriteAllText((Join-Path $VandaagDir ($naam + '.txt')), $tekst, (New-Object System.Text.UTF8Encoding($true)))
    $o = (Get-Date).AddMinutes(-30); $f = Get-Item -LiteralPath (Join-Path $VandaagDir ($naam + '.mp4')); $f.CreationTime = $o; $f.LastWriteTime = $o
}
Nieuw '1 - Mijn eerste headshot' "Wat een schot! #valorant #gaming"
Nieuw '2 - Bouwen tot de zon opkomt' "We bouwen een kasteel #minecraft"
Nieuw '3 - Nog een clutch' "Clutch in de laatste ronde #valorant"
Nieuw '4 - Zonder tekst' ''
$all = @(Get-AllClips); $q = @(Get-Queue $all)
Check ($all.Count -eq 4) "vier clips gevonden ($($all.Count))"
Check ($q.Count -eq 3) "drie in de wachtrij, zonder Origineel-regel of games ($($q.Count))"
Check (($all | ? { $_.Mp4 -like '*Zonder tekst*' }).Probleem -eq 'tekst is leeg') 'clip zonder tekst overgeslagen'
Check ($q[0].Title -eq 'Mijn eerste headshot') "titel uit bestandsnaam: $($q[0].Title)"
$m = New-UploadMeta 'T' 'Tekst #valorant' 'public' | ConvertFrom-Json
Check ($m.snippet.description -notmatch 'twitch') 'geen Twitch-regel als die niet is ingesteld'
"== Games instellen: om en om"
$script:Cfg.Games = @([pscustomobject]@{ Naam = 'Valorant'; Tags = @('valorant') }, [pscustomobject]@{ Naam = 'Minecraft'; Tags = @('minecraft', 'mc') })
$script:Cfg.TwitchRegel = 'Live op Twitch: https://twitch.tv/voorbeeld'
$script:Cfg.Ingesteld = $true; Save-Cfg
$q = @(Get-Queue (Get-AllClips))
"   " + (($q | % { $_.Game }) -join ' > ')
Check ($q[0].Game -eq 'Valorant' -and $q[1].Game -eq 'Minecraft' -and $q[2].Game -eq 'Valorant') 'Valorant en Minecraft om en om'
Check ((Get-GameFromName '5 - Titel - Minecraft') -eq 'Minecraft') 'game uit bestandsnaam'
Check ((Get-GameFromText 'leuk #MC') -eq 'Minecraft') 'tweede hashtag werkt ook'
"== Eerste upload onthoudt het kanaal"
$r = Complete-Upload $q[0].Key $q[0].Game 'OK|v1|public|UCnieuw123|Mijn Kanaal'
Check ($script:Cfg.KanaalId -eq 'UCnieuw123' -and $script:Cfg.KanaalNaam -eq 'Mijn Kanaal') 'kanaal onthouden'
Check (-not $script:Cfg.AutoGepauzeerd) 'geen pauze bij eerste upload'
$q = @(Get-Queue (Get-AllClips))
$r = Complete-Upload $q[0].Key $q[0].Game 'OK|v2|public|UCanders|Iemand Anders'
Check ($script:Cfg.AutoGepauzeerd -and $r -match 'Mijn Kanaal') 'daarna wel pauze bij ander kanaal'
$re = Load-Json $ConfigFile $null
Check ($re.Versie -eq 5 -and @($re.Games).Count -eq 2 -and $re.TwitchRegel -like '*voorbeeld') 'instellingen bewaard'

"== Na review: hoofdletters in rotatie, volgorde op nummer, bestandsnamen"
$script:Cfg.AutoGepauzeerd = $false; $script:Cfg.Rotatie = @('minecraft', 'VALORANT'); $script:Cfg.LaatsteGame = 'Minecraft'; Save-Cfg
Nieuw '10 - Nog een kasteel' "Groter kasteel #minecraft"
Nieuw '11 - Nog een ace' "Ace! #valorant"
Nieuw '9 - Tweede blok' "Blokken #minecraft"
$q = @(Get-Queue (Get-AllClips))
"   " + (($q | % { '{0}:{1}' -f $_.Nr, $_.Game }) -join ' > ')
Check (@($q.Key | Select-Object -Unique).Count -eq $q.Count) 'geen dubbele clips bij andere hoofdletters in de rotatie'
Check ($q[0].Game -eq 'Valorant') 'na Minecraft komt Valorant (rotatie ondanks hoofdletters)'
$mc = @($q | ? Game -eq 'Minecraft' | % { $_.Nr })
Check (($mc -join ',') -eq '2,9,10') "volgorde op nummer: 2, 9, 10 ($($mc -join ','))"
Check ((Get-GameFromName 'Karma - Minecraft clip') -eq 'Minecraft' -and -not (Get-GameFromName 'Minecraftig')) 'game alleen op hele woorden in bestandsnaam'
"== Kapotte config.json: reservekopie gebruiken"
Save-Cfg; Save-Cfg   # zorgt voor een .bak
'{ kapot' | Set-Content $ConfigFile
. $src -GeenVenster
Check ($script:Cfg.KanaalId -eq 'UCnieuw123') 'reservekopie gebruikt, kanaalcontrole blijft'
Check ((Load-Json $ConfigFile $null).KanaalId -eq 'UCnieuw123') 'config.json hersteld'

""
if ($script:fails) { "MISLUKT: $script:fails test(s)"; exit 1 } else { 'ALLE TESTS GESLAAGD'; exit 0 }
