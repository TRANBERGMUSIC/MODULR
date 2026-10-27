# Rekordbox-USB uden rekordbox – sådan gør MODULR

Bygger på referencedokumentet "Rekordbox USB-eksport reference" (LEARN SKILLS-chatten, 26/10-2026),
kontrolleret mod en rigtig rekordbox-USB (KNOWN MUSIC, 138 sange), rekordcrate og Deep Symmetry.
Hvor dokumentet tog fejl, står det under "Rettelser".

## Filer på stikket

```
/PIONEER/rekordbox/export.pdb        Device Library (DeviceSQL, little-endian) – det CDJ-3000 læser
/PIONEER/rekordbox/exportExt.pdb     My Tag m.m. (røres ikke)
/PIONEER/rekordbox/exportLibrary.db  OneLibrary (SQLCipher) – CDJ-3000X/XDJ-AZ/OPUS-QUAD/OMNIS-DUO (røres ikke)
/PIONEER/USBANLZ/Pxxx/xxxxxxxx/ANLZ0000.DAT|.EXT|.2EX   analyse pr. sang (big-endian)
/PIONEER/Artwork/…                   cover (80×80 + _m 240×240)
/PIONEER/DEVSETTING.DAT              visning: waveform-farve, overview-type, toneart-format
/PIONEER/MYSETTING.DAT, MYSETTING2.DAT, DJMMYSETTING.DAT   My Settings
/Contents/<Kunstner>/<Album>/<fil>   lydfilerne
```

FAT32 eller exFAT (exFAT kun CDJ-3000 og nyere), MBR. APFS/Mac OS Extended kan CDJ'er ikke læse – MODULR advarer.

## Hvilket bibliotek læser CDJ-3000?

- Firmware 3.22 (seneste, 15/1-2026): Device Library (`export.pdb`). Ingen OneLibrary.
- Firmware 3.30 (21/10-2025, trukket tilbage): "If Device Library and OneLibrary are both present … OneLibrary will load by default".
  En CDJ der stadig har 3.30, ignorerer derfor ændringer i `export.pdb` på et stik med `exportLibrary.db`.
  Tjek versionen i UTILITY på spilleren.
- CDJ-3000X m.fl. læser kun OneLibrary. MODULR skriver ikke OneLibrary (krypteret); brug rekordbox 7 → "Convert from Device Library".

## ANLZ – det der giver waveform, grid og cues

Spilleren tegner kun fra ANLZ-filerne. `analyze_path` i track-rækken peger på `.DAT`; `.EXT` og `.2EX` ligger ved siden af.

| Fil | Tag | MODULR skriver |
|---|---|---|
| .DAT | PPTH | filstien (UTF-16BE, med 0-afslutning) – skal være identisk med `file_path` |
| .DAT | PVBR | 401 × u32. CBR-MP3: nuller + samlede antal samples i sidste felt (som rekordbox) |
| .DAT | PQTZ | beatgrid: (takt-slag 1–4, BPM×100, ms) pr. slag |
| .DAT | PWAV/PWV2 | blå oversigt 400 / 100 kolonner |
| .DAT/.EXT | PCOB | cues: PCPT-poster á 0x38, hot cues skrevet H→A, order-felter 0xFFFF |
| .EXT | PWV3 | blå detalje 150/s |
| .EXT | PCO2 | hot cues med farve: PCP2-poster (0x58 uden kommentar; rekordbox bruger 0x6C med "CUE(Auto)") |
| .EXT | PWV5 | RGB-detalje 150/s: 3 bit R/G/B + 5 bit højde – farverne er NORMALISEREDE (lyse, gennemsnit 4–5 af 7) |
| .EXT | PWV4 | RGB-oversigt 1200 × 6 byte; byte 3/4/5 = lav/mellem/høj 0–127 |
| .2EX | PWV7/PWV6/PWVC | 3-bånd (mellem, høj, lav); detalje op til ~120, oversigt op til ~45 |

Kontrol: hver fil parses med rekordcrate efter skrivning i testene, og sammenlignes tag for tag med en fil rekordbox har lavet.

## Rettelser til referencedokumentet

1. **Mappenavnet under USBANLZ er IKKE vilkårligt – CDJ'en regner det selv ud fra filstien og ignorerer `analyze_path`.**
   rekordbox' `CreateAnlzFileFolderPath` (fundet af rhythmbox-to-pioneer-xdj-exporter, PIONEER.md):
   ```
   h = 0; for hver UTF-16-enhed c i "/Contents/…":  h = ((h*0x5BC9 + c) * 0x93B5 + c) mod 2^32
   r = h mod 200003
   P = bit0 | bit2→1 | bit6→2 | bit7→3 | bit9→4 | bit13→5 | bit16→6   (af r)
   sti = /PIONEER/USBANLZ/P%03X/%08X/ANLZ0000.DAT  (P, r)
   ```
   Kontrolleret: alle 138 rekordbox-sange på KNOWN MUSIC (også med æøå) passer præcist.
   MODULRs sang lå i `P800/…` og senere `P02C/00039FAE`, men CDJ'en kiggede i `P026/0000F176` → ingen analyse,
   spilleren kørte sin egen (blå waveform, lang indlæsning, 130.2 i stedet for 130.0 BPM).
   MODULR bruger nu formlen (`anlz_hash_path`) og flytter ældre MODULR-analyser automatisk ("Ret nu" / ved næste skrivning).
   Hash-kollision (to sange, samme mappe) er sjælden; så skrives der ikke oven i den anden sangs analyse.
2. **Waveform-farven (BLUE/RGB/3Band) ligger i `DEVSETTING.DAT`, ikke `MYSETTING2.DAT`.** Standard er BLUE.
   `DEVSETTING.DAT` er fuldt kendt (32 bytes) og kan skrives sikkert. (KNOWN MUSIC stod allerede på RGB – det var ikke årsagen.)
3. **CRC16-XMODEM:** over data-delen – men for `DJMMYSETTING.DAT` over ALT før checksummen.
4. **PVBR** er ikke tom for MP3: sidste felt = antal samples.
5. **Farverne i PWV5** skal være normaliserede farver, ikke rå båndenergi (ellers næsten sort).

## My Settings-format

`u32 0x60 · brand[32] · software[32] · version[32] · u32 len_data · data · u16 CRC16-XMODEM · u16 0`
Data: DEVSETTING 32, MYSETTING 40, MYSETTING2 40, DJMMYSETTING 52 bytes. Hvert felt én byte med faste værdier
(tabellen i `usb/pioneer_settings.py` er genereret fra rekordcrate `setting.rs`). Ukendte bytes bevares.
Kontrol: alle 82 rigtige rekordbox-indstillingsfiler i rekordcrates testdata læses med korrekt CRC og skrives byte-identisk tilbage.

## At rette i en eksisterende export.pdb

- Tilføj: rækker indsættes på tabellens sidste side (ny side når den er fuld), indekssiden opdateres.
- Slet: tilstedeværelses-bit ryddes, `num_rows_valid` tælles ned, sideflag 0x10 ("indeholder slettede"). Bytes bliver liggende (som rekordbox).
- Playliste-numre gøres fortløbende (1, 2, 3 …) efter enhver ændring.
- `analyze_path` rettes på stedet (samme længde).
- Altid: backup af `PIONEER/rekordbox` (5 nyeste gemmes), skriv i hukommelsen, parse igen og kontrollér at intet andet er ændret,
  skriv atomisk (tmp + rename). Filer slettes først efter databasen er gemt.
- Rekordbox' egne analysefiler røres aldrig; MODULRs mapper har en `.modulr`-mærkefil.

## PQT2 og PSSI (afkodet fra KNOWN MUSIC)

**PSSI (phrases)** – skrives nu. 24-byte poster: index, startslag (1-baseret i PQTZ), type, flag. Mood 1 = High:
1 Intro, 2 Up, 3 Down, 5 Chorus, 6 Outro. MODULR: intro→1, groove/buildup→2, breakdown→3, drop→5, outro→6.
Alt fra mood og frem XOR-maskeres med `(nøgle[i] + antal) mod 256`. Kontrol: rekordbox' egne PSSI fra tre sange
genopbygges byte-identisk, og rekordcrate læser MODULRs.

**PQT2 (udvidet beatgrid)** – skrives IKKE. Header: første slag (u16 taktslag, u16 tempo×100, u32 ms), sidste slag,
antal slag, og en u32 vi ikke kan genskabe (ikke sum/tid/CRC). Indhold: u16 pr. slag = tusindedele af ms
(PQTZ har kun hele ms, rundet NED). En forkert værdi kan få spilleren til at afvise .EXT, og ingen af de
hardware-testede projekter skriver den – derfor udeladt.

**PQTZ** rundes nu ned til hele ms som rekordbox.

## Ikke lavet endnu

- PQT2 (se ovenfor).
- Loops og cue-navne (MODULR har ikke loops/navne i sin model endnu).
- PVBR for VBR-MP3 (kræver en rekordbox-reference fra en VBR-fil).
- Hot cues/grid fra USB'en ind i biblioteket ved import, og ændringer lavet på CDJ'en.
- OneLibrary.

## Kilder

- Deep Symmetry: Analysis Files og Export Structure (djl-analysis.deepsymmetry.org)
- rhythmbox-to-pioneer-xdj-exporter `PIONEER.md` (ANLZ-sti-hash), openboxxx `docs/research-findings.md`
- rekordcrate (`src/anlz.rs`, `src/setting.rs`, `src/pdb`), beat-link (`CueList.java`, `WaveformPreview.java`)
- AlphaTheta: CDJ-3000 firmware 3.22 (support.alphatheta.com) og notits om 3.30 (pioneerdj.com, 7/1-2026)
