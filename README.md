# MODULR

**Your tools. One platform.** Mac-værktøjer til DJs.

## Værktøjer

- **Bitrate-tjek**: analyserer selve lyden og afslører filer, der er opkonverteret fra lav bitrate (fx 128 kbps gemt som 320).
- **Find bedre version**: genkender præcis sangen ud fra lyden (Chromaprint/AcoustID, valgfrit AudD/ACRCloud) og finder steder, hvor kunstneren eller labelet selv giver den gratis i bedre kvalitet: SoundCloud (officielt API, kun `downloadable`), Bandcamp (gratis / name your price), download-gates (Hypeddit, ToneDen, lnk.to, Fanlink) og kunstnerens egne sider. Gates gennemfører du selv i appens browser. Den hentede fil verificeres med fingerprint og kvalitetsanalyse og gemmes kun, hvis den er præcis samme sang og reelt bedre – med en herkomst-fil ved siden af.
- **Artwork**: lægger et billede ind i WAV, AIFF og MP3 som ID3-tag (JPEG, maks. 800×800), så det vises i rekordbox og på CDJ'en.

## Hvad MODULR aldrig gør

Ingen api-v2.soundcloud.com, ingen stream-URL'er eller stream-rippere (yt-dlp, scdl …), ingen automatisk gennemførelse af gates, ingen piratsider eller filehosts. Det er håndhævet i koden (`Core/Policy.swift`): en download kan kun ske via en `ApprovedDownload`, som kun kan oprettes derfra.

## Installation

1. Hent repoet (Code → Download ZIP) og pak det ud – eller `git clone`.
2. Åbn Terminal, skriv `bash ` og træk `Installer.command` ind i vinduet. Tryk Enter.

Appen lægger sig i Programmer og opdaterer sig selv, når der kommer en ny version i dette repo.

## Indstillinger (Cmd + ,)

- **AcoustID-nøgle** (gratis på acoustid.org) – nødvendig for at genkende sange ud fra lyden.
- **SoundCloud client-id/secret** – kræver godkendt API-adgang hos SoundCloud. Uden den står der "SoundCloud ikke konfigureret".
- Valgfrit: AudD, ACRCloud og Brave Search (generel websøgning).

## Tests

```
bash run_tests.command
```

Tester fingerprint-matchning (128 vs lossless, radio edit og extended afvises), spektral cutoff på syntetiske filer, kandidatfiltrering, "kun bedre"-reglen, kildepolitikken, robots.txt og ID3/artwork i WAV/AIFF/MP3.

## Opbygning

- `main.swift` – app, Bitrate-tjek, auto-opdatering
- `App/` – Find bedre version (identifikation, kilder, forløb, browser, skærme), Artwork, indstillinger
- `Core/` – testbar logik: analyse, kvalitet, matchning, fingerprint, politik, kandidater, robots.txt, ID3
- `Tests/` – testprogrammet
