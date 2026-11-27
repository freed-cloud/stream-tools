# Beveiliging

- **Geen geheimen in de code.** Het OBS-wachtwoord, `client_secret.json` en de YouTube-inlogsleutel staan alleen op de eigen pc in `%APPDATA%\StreamCheck` en `%APPDATA%\ClipPoster`, nooit in deze repository. `.gitignore` blokkeert ze, en de geschiedenis is vóór het openbaar maken op sleutels doorzocht.
- **Versleuteld opslaan.** Het OBS-wachtwoord en de YouTube-inlogsleutel worden versleuteld met Windows DPAPI (gekoppeld aan het Windows-account).
- **Zo weinig mogelijk rechten.** De Clip-poster vraagt `youtube.upload` (uploaden) en `youtube.readonly` (cijfers van de eigen video's lezen). Hij kan niets verwijderen of aanpassen. Na het inloggen controleert hij of het upload-recht echt gegeven is.
- **OAuth met PKCE en state-controle** tegen het onderscheppen of vervalsen van de inlog.
- **Verkeerd kanaal = stop.** Komt een upload op een ander kanaal terecht dan ingesteld, dan telt hij niet als gepost en stopt het automatisch posten.
- **Geen admin nodig.** De automatische taak draait als gewone gebruiker.
- **Telefoonmeldingen** (optioneel, via ntfy.sh) bevatten alleen korte teksten, zoals de link naar een geposte video of een foutmelding. Het onderwerp is een willekeurige code die bij de eerste start op de pc wordt gemaakt en niet in deze repository staat.
- **Alleen lokaal.** De Stream-check praat alleen met OBS op `127.0.0.1`.

Privacybeleid van de Clip-poster: https://freed-cloud.github.io/clip-poster/privacy.html

Een probleem gevonden? Neem contact op via https://freed-cloud.github.io/.
