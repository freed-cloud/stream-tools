# Opent de Clip-poster met testclips op een Windows-pc, maakt schermafbeeldingen en sluit hem weer.
# Gebruikt door GitHub Actions (en handig voor de website). Uitvoer: map "schermafbeeldingen".
# Gebruik:  powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\Maak-Schermafbeeldingen.ps1 [-Scherm]
param([switch]$Scherm)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$uit = Join-Path $repo 'schermafbeeldingen'
New-Item -ItemType Directory -Force $uit | Out-Null
$root = Join-Path ([IO.Path]::GetTempPath()) 'clipposter-scherm'
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
$py = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
& $py (Join-Path $PSScriptRoot 'maak_testmappen.py') $root | Out-Null
$app = Join-Path $root 'AppData\ClipPoster'
New-Item -ItemType Directory -Force $app | Out-Null
'{"Versie":4,"Privacy":"public"}' | Set-Content -LiteralPath (Join-Path $app 'config.json') -Encoding UTF8
$suffix = if ($Scherm) { '-scherm' } else { '' }
$env:CLIPPOSTER_TESTROOT = $root
$env:CLIPPOSTER_SCREENSHOT = Join-Path $uit ("clip-poster$suffix.png")
$env:CLIPPOSTER_SCREENSHOT_SETTINGS = Join-Path $uit ("instellingen$suffix.png")
if ($Scherm) { $env:CLIPPOSTER_SHOT_SCREEN = '1' } else { $env:CLIPPOSTER_SHOT_SCREEN = '' }
$p = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'ClipPoster\ClipPoster.ps1')) -PassThru -NoNewWindow -RedirectStandardError (Join-Path $uit "fout$suffix.txt")
if (-not $p.WaitForExit(90000)) {
    # Wat staat er op het scherm? (bijv. een melding die op een klik wacht)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($sb.Width, $sb.Height)
    $gr = [System.Drawing.Graphics]::FromImage($bmp); $gr.CopyFromScreen($sb.Location, [System.Drawing.Point]::Empty, $sb.Size); $gr.Dispose()
    $bmp.Save((Join-Path $uit "hangen$suffix.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    Get-Process | Where-Object { $_.MainWindowTitle } | ForEach-Object { Write-Host ('Venster: {0} - {1}' -f $_.ProcessName, $_.MainWindowTitle) }
    $p.Kill(); Write-Host 'De Clip-poster bleef hangen.'
    Get-Content (Join-Path $uit "fout$suffix.txt") -ErrorAction SilentlyContinue | Write-Host
    Get-Content (Join-Path $app 'log.txt') -ErrorAction SilentlyContinue | Write-Host
    exit 1
}
$fout = Get-Content (Join-Path $uit "fout$suffix.txt") -Raw -ErrorAction SilentlyContinue
if ($fout) { Write-Host "Fout: $fout" }
$ok = (Test-Path $env:CLIPPOSTER_SCREENSHOT) -and (Test-Path $env:CLIPPOSTER_SCREENSHOT_SETTINGS)
Get-ChildItem $uit | ForEach-Object { Write-Host ('{0}  {1:N0} bytes' -f $_.Name, $_.Length) }
if ($ok -and $p.ExitCode -eq 0) { Write-Host 'Venster en instellingen openen zonder fouten.'; exit 0 } else { Write-Host ('Mislukt (exitcode {0}).' -f $p.ExitCode); exit 1 }
