# MODULR

**Your tools. One platform.** Mac-værktøjer til DJs.

## Værktøjer

- **Bibliotek** (Mixed In Key-inspireret): alle filer du sætter ind i MODULR, med RGB-waveform, cover, BPM, toneart (Camelot), energi, længde og reel kvalitet (rød/gul/grøn). Camelot-hjul som filter, mapper og playlister, afspiller, "Udskift fil med bedre version" (samme data, cover flyttes med) og **direkte eksport til rekordbox-USB** til CDJ-3000: sange kopieres, `PIONEER/rekordbox/export.pdb` udvides (backup først, kun nye rækker, verificeres før den gamle erstattes) og ANLZ-filer med beatgrid og RGB-waveform skrives. Formatet bygger på Deep Symmetrys crate-digger, rekordcrate og pyrekordbox og er testet mod rigtige rekordbox-eksporter.

- **Afspiller til at forberede sættet**: zoombar detaljewaveform (rekordbox-farver) med beatgrid – slag, takter og en orange streg for hver frase på 8 takter med taktnummer – og tæller ("Takt 17.3 · frase om 2 takter"). Ret griddet (BPM ±0,01/±0,1, ½/×2, skub 5 ms, træk i waveformen, "Takt 1 her"), sæt markører på slag til ind- og udgange, 3-bånds EQ der høres med det samme og kan lægges ind i filen, og niveaumåler med rødt felt over −1 dBFS og CLIP-lampe. Klik/træk i tabellens små waveforms for at spole.
- **Fiks tracks (lydstyrke som Platinum Notes)**: hver sang måles efter EBU R128 (LUFS) og rettes automatisk til samme klubniveau (standard −9 LUFS, justerbart i Indstillinger → Lydstyrke), så gain-knappen kan blive samme sted. WAV/AIFF: gain + gennemsigtig look-ahead-limiter (top −1 dBFS, højst 5 dB dæmpning), gemt som 24-bit med tags og cover. MP3: tabsfri global_gain-ændring i trin på 1,5 dB (som mp3gain – ingen genkodning). Originalerne gemmes i `Musik/MODULR/Originaler` (højreklik → "Gendan original"). Listen "Fiks tracks" viser sange med lav kvalitet eller forkert lydstyrke og et behandlingspanel med før/efter-waveform (hvid = klippede toppe), klip rettet, limiter og LUFS før → efter. Klippede toppe genskabes før lydstyrken rettes; MP3 der ikke kan rettes tabsfrit, gemmes som 24-bit WAV.
- **Bitrate-tjek**: analyserer selve lyden og afslører filer, der er opkonverteret fra lav bitrate (fx 128 kbps gemt som 320).
- **Find bedre version**: genkender præcis sangen ud fra lyden (Chromaprint/AcoustID, valgfrit AudD/ACRCloud) og finder steder, hvor kunstneren eller labelet selv giver den gratis i bedre kvalitet: SoundCloud (officielt API, kun `downloadable`), Bandcamp (gratis / name your price), download-gates (Hypeddit, ToneDen, lnk.to, Fanlink) og kunstnerens egne sider. Gates gennemfører du selv i appens browser. Den hentede fil verificeres med fingerprint og kvalitetsanalyse og gemmes kun, hvis den er præcis samme sang og reelt bedre – med en herkomst-fil ved siden af.
- **Konti**: log ind én gang hos SoundCloud, Hypeddit, ToneDen, Spotify, Instagram og Bandcamp i MODULRs browser (delt med gate-browseren), og forbind din SoundCloud-konto til API'et med OAuth 2.1 + PKCE (redirect-URI `modulr://soundcloud/callback`).
- **Artwork**: bibliotek over covers samlet fra dine filer (også de dårlige versioner). "Find bedre version" og "Udskift fil" flytter coveret med over på den nye fil. Covers kan udskiftes, og alle filer der bruger dem opdateres. Skrives som ID3 i WAV, AIFF og MP3 (JPEG, maks. 800×800) til rekordbox/CDJ.
- **Gates i din egen browser** (standard): Google-login virker, og MODULR fanger filen i Overførsler (kilden tjekkes via macOS' "Hentet fra").

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
