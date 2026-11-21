# Beveiliging

- **Geen geheimen in de code.** Het OBS-wachtwoord, `client_secret.json` en de YouTube-inlogsleutel staan alleen op de eigen pc in `%APPDATA%\StreamCheck` en `%APPDATA%\ClipPoster`, nooit in deze repository. `.gitignore` blokkeert ze.
- **Versleuteld opslaan.** Het OBS-wachtwoord en de YouTube-inlogsleutel worden versleuteld met Windows DPAPI (gekoppeld aan het Windows-account).
- **Zo weinig mogelijk rechten.** De Clip-poster vraagt alleen `youtube.upload`: uploaden, niet lezen of verwijderen.
- **OAuth met PKCE en state-controle** tegen het onderscheppen of vervalsen van de inlog.
- **Alleen lokaal.** De Stream-check praat alleen met OBS op `127.0.0.1`.

Een probleem gevonden? Neem contact op via https://freed-cloud.github.io/.
