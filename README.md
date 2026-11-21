# Stream-tools voor playingparentsnl

Twee gratis Windows-programma's voor onze Twitch-stream:

1. **Stream-check**: één knop die vóór het streamen controleert of alles goed staat.
2. **Clip-poster**: clips met tekst naar YouTube uploaden en klaarzetten voor TikTok en Instagram.

Beide draaien op **Windows PowerShell 5.1**, dat standaard in Windows zit. Je hoeft niets te installeren.

---

## 1. Stream-check

### Waarom
Op 20 november 2026 had onze stream ruim 7 uur geen geluid. Een Windows-update gaf de headset een nieuwe apparaat-ID, en OBS zocht nog naar de oude. Kijkers merkten het eerder dan wij. Deze check vangt dat vooraf.

### Wat hij controleert
| Check | Rood als |
| --- | --- |
| Windows-update | Windows wacht op een herstart (oranje), of is bijgewerkt sinds de laatste goede check (oranje) |
| Windows-geluid | De headset staat niet als standaardapparaat voor afspelen of opnemen |
| Internet | Twitch is niet bereikbaar |
| OBS | OBS draait niet, of de WebSocket-verbinding lukt niet |
| Apparaten in OBS | Een gekozen geluids- of video-apparaat bestaat niet meer |
| Gedempt | Desktop-audio, Mic/Aux of PlayStation staat op stil |
| Geluid komt binnen | De geluidsbalk bewoog niet tijdens 6 seconden meten |
| Beeld capture card | Het beeld van de PlayStation is zwart (oranje) |

### Eén keer instellen
1. Open OBS en ga naar **Tools > WebSocket-serverinstellingen**.
2. Zet **WebSocket-server inschakelen** en **Authenticatie inschakelen** aan. Laat de poort op 4455.
3. Klik op de knop om de verbindingsgegevens te tonen (Show Connect Info) en kopieer het wachtwoord.
4. Dubbelklik op **Start Stream-check.bat**, klik op **Instellingen** en plak het wachtwoord.

### Gebruik
Dubbelklik op **Start Stream-check.bat** en klik op **Check alles**. Praat even tijdens het meten en laat de game geluid maken. Pas als alles groen is, ga je live.

---

## 2. Clip-poster

### Wat hij doet
- Toont de clips uit `Bureaublad\Clips voor socials\Vandaag posten`, met de bijbehorende tekst.
- **YouTube:** uploadt de clip met titel, tekst en hashtags via de officiële YouTube Data API.
- **TikTok en Instagram:** kopieert de tekst naar je klembord, selecteert de video in Verkenner en opent de uploadpagina. Jij sleept de video erin en plakt de tekst. Automatisch posten op TikTok kan pas als TikTok de app heeft gekeurd (audit); tot die tijd komt alles op privé te staan.
- **Klaar:** verplaatst de clip naar `Clips voor socials\Gepost`. Er wordt niets verwijderd.

### Eén keer instellen (YouTube)
1. Ga naar https://console.cloud.google.com en maak een nieuw project, bijvoorbeeld "Clip-poster".
2. Zoek in de **API-bibliotheek** naar **YouTube Data API v3** en klik op **Inschakelen**.
3. Stel het **OAuth-toestemmingsscherm** in: type **Extern**, vul een naam en je e-mailadres in, en voeg je eigen Google-account toe als **testgebruiker**.
4. Maak bij **Clients** (Inloggegevens) een **OAuth-client-ID** van het type **Desktop-app** en download het JSON-bestand.
5. Open de Clip-poster, klik op **YouTube instellen**, kies het JSON-bestand en log in met het Google-account van het YouTube-kanaal.

**Let op:** zolang de app in Google op "Testen" staat, verloopt de inlog na 7 dagen en moet je opnieuw inloggen. De Clip-poster vraagt dat dan vanzelf. Wil je dat niet, zet de app dan op **In productie**. Google laat dan bij het inloggen een waarschuwing "app niet geverifieerd" zien, die je via **Geavanceerd** kunt overslaan, want het is je eigen app.

Een nieuw Google-project mag standaard 100 video's per dag uploaden. Ruim genoeg voor 4 clips per dag.

---

## Beveiliging
- Wachtwoorden en inlogsleutels worden opgeslagen met Windows-versleuteling (DPAPI): alleen jouw Windows-account kan ze lezen.
- Inloggen bij Google gebruikt OAuth met PKCE. De Clip-poster ziet je Google-wachtwoord nooit en vraagt alleen toestemming om video's te uploaden (`youtube.upload`).
- Er staan geen geheimen in deze repository. Zie [SECURITY.md](SECURITY.md).

## Status
Gebouwd in november 2026 met Claude. De eerste versie moet nog op de echte pc getest worden.
