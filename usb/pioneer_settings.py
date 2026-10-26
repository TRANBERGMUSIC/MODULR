"""MODULR – My Settings på et rekordbox-USB (MYSETTING.DAT, MYSETTING2.DAT, DJMMYSETTING.DAT, DEVSETTING.DAT).

Format (fra rekordcrate/Deep Symmetry, kontrolleret mod rekordbox' egne filer):
  u32 len_strings (= 0x60) · brand[32] · software[32] · version[32] · u32 len_data · data[len_data]
  · u16 CRC16-XMODEM · u16 0
CRC'en regnes over data – undtagen DJMMYSETTING.DAT, hvor den regnes over alt før CRC'en.
Alle felter er én byte med faste værdier. Ukendte bytes bevares uændret.
Bemærk: waveform-farven (BLUE/RGB/3Band) ligger i DEVSETTING.DAT – ikke i MYSETTING2.DAT.
"""
import json
import os
import struct
import sys

LAYOUT = {
 "DEVSETTING.DAT": {
  "size": 32,
  "fields": [
   [
    "overview_waveform_type",
    9,
    "Overview-waveform",
    [
     [
      1,
      "Half Waveform"
     ],
     [
      2,
      "Full Waveform"
     ]
    ],
    1
   ],
   [
    "waveform_color",
    10,
    "Waveform-farve",
    [
     [
      1,
      "BLUE"
     ],
     [
      3,
      "RGB"
     ],
     [
      4,
      "3Band"
     ]
    ],
    1
   ],
   [
    "key_display_format",
    12,
    "Toneart-visning",
    [
     [
      1,
      "Classic"
     ],
     [
      2,
      "Alphanumeric"
     ]
    ],
    1
   ],
   [
    "waveform_current_position",
    13,
    "Afspilningsposition i waveform",
    [
     [
      2,
      "LEFT"
     ],
     [
      1,
      "CENTER"
     ]
    ],
    1
   ]
  ]
 },
 "MYSETTING.DAT": {
  "size": 40,
  "fields": [
   [
    "on_air_display",
    8,
    "On Air Display",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON"
     ]
    ],
    129
   ],
   [
    "lcd_brightness",
    9,
    "LCD-lysstyrke",
    [
     [
      129,
      "1"
     ],
     [
      130,
      "2"
     ],
     [
      131,
      "3"
     ],
     [
      132,
      "4"
     ],
     [
      133,
      "5"
     ]
    ],
    131
   ],
   [
    "quantize",
    10,
    "Quantize",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON"
     ]
    ],
    129
   ],
   [
    "auto_cue_level",
    11,
    "Auto cue-niveau",
    [
     [
      135,
      "-78dB"
     ],
     [
      134,
      "-72dB"
     ],
     [
      133,
      "-66dB"
     ],
     [
      132,
      "-60dB"
     ],
     [
      131,
      "-54dB"
     ],
     [
      130,
      "-48dB"
     ],
     [
      129,
      "-42dB"
     ],
     [
      128,
      "-36dB"
     ],
     [
      136,
      "MEMORY"
     ]
    ],
    136
   ],
   [
    "language",
    12,
    "Sprog",
    [
     [
      129,
      "English"
     ],
     [
      130,
      "Français"
     ],
     [
      131,
      "Deutsch"
     ],
     [
      132,
      "Italiano"
     ],
     [
      133,
      "Nederlands"
     ],
     [
      134,
      "Español"
     ],
     [
      135,
      "Русский"
     ],
     [
      136,
      "한국어"
     ],
     [
      137,
      "简体中文"
     ],
     [
      138,
      "繁體中文"
     ],
     [
      139,
      "日本語"
     ],
     [
      140,
      "Português"
     ],
     [
      141,
      "Svenska"
     ],
     [
      142,
      "Čeština"
     ],
     [
      143,
      "Magyar"
     ],
     [
      144,
      "Dansk"
     ],
     [
      145,
      "Ελληνικά"
     ],
     [
      146,
      "Türkçe"
     ]
    ],
    129
   ],
   [
    "jog_ring_brightness",
    14,
    "Jog ring-lysstyrke",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "1 (Dark)"
     ],
     [
      130,
      "2 (Bright)"
     ]
    ],
    130
   ],
   [
    "jog_ring_indicator",
    15,
    "Jog ring-indikator",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON"
     ]
    ],
    129
   ],
   [
    "slip_flashing",
    16,
    "Slip-blink",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON"
     ]
    ],
    129
   ],
   [
    "disc_slot_illumination",
    20,
    "Disc slot-lys",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "1 (Dark)"
     ],
     [
      130,
      "2 (Bright)"
     ]
    ],
    130
   ],
   [
    "eject_lock",
    21,
    "Eject/Load lock",
    [
     [
      128,
      "UNLOCK"
     ],
     [
      129,
      "LOCK"
     ]
    ],
    128
   ],
   [
    "sync",
    22,
    "Sync",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON"
     ]
    ],
    128
   ],
   [
    "play_mode",
    23,
    "Play mode",
    [
     [
      128,
      "CONTINUE / ON"
     ],
     [
      129,
      "SINGLE / OFF"
     ]
    ],
    129
   ],
   [
    "quantize_beat_value",
    24,
    "Quantize beat value",
    [
     [
      131,
      "1/8 Beat"
     ],
     [
      130,
      "1/4 Beat"
     ],
     [
      129,
      "1/2 Beat"
     ],
     [
      128,
      "1 Beat"
     ]
    ],
    128
   ],
   [
    "hotcue_autoload",
    25,
    "Hot cue auto load",
    [
     [
      128,
      "OFF"
     ],
     [
      130,
      "rekordbox SETTING"
     ],
     [
      129,
      "On"
     ]
    ],
    129
   ],
   [
    "hotcue_color",
    26,
    "Hot cue-farve",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "On"
     ]
    ],
    128
   ],
   [
    "needle_lock",
    29,
    "Needle lock",
    [
     [
      128,
      "UNLOCK"
     ],
     [
      129,
      "LOCK"
     ]
    ],
    129
   ],
   [
    "time_mode",
    32,
    "Tidsvisning",
    [
     [
      128,
      "Elapsed"
     ],
     [
      129,
      "REMAIN"
     ]
    ],
    129
   ],
   [
    "jog_mode",
    33,
    "Jog mode",
    [
     [
      129,
      "VINYL"
     ],
     [
      128,
      "CDJ"
     ]
    ],
    129
   ],
   [
    "auto_cue",
    34,
    "Auto cue",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON"
     ]
    ],
    129
   ],
   [
    "master_tempo",
    35,
    "Master tempo",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON"
     ]
    ],
    128
   ],
   [
    "tempo_range",
    36,
    "Tempo range",
    [
     [
      128,
      "±6"
     ],
     [
      129,
      "±10"
     ],
     [
      130,
      "±16"
     ],
     [
      131,
      "WIDE"
     ]
    ],
    129
   ],
   [
    "phase_meter",
    37,
    "Phase meter",
    [
     [
      128,
      "TYPE 1"
     ],
     [
      129,
      "TYPE 2"
     ]
    ],
    128
   ]
  ]
 },
 "MYSETTING2.DAT": {
  "size": 40,
  "fields": [
   [
    "vinyl_speed_adjust",
    0,
    "Vinyl speed adjust",
    [
     [
      128,
      "TOUCH & RELEASE"
     ],
     [
      129,
      "TOUCH"
     ],
     [
      130,
      "RELEASE"
     ]
    ],
    129
   ],
   [
    "jog_display_mode",
    1,
    "Jog display mode",
    [
     [
      128,
      "AUTO"
     ],
     [
      129,
      "INFO"
     ],
     [
      130,
      "SIMPLE"
     ],
     [
      131,
      "ARTWORK"
     ]
    ],
    128
   ],
   [
    "pad_button_brightness",
    2,
    "Pad/knap-lysstyrke",
    [
     [
      129,
      "1"
     ],
     [
      130,
      "2"
     ],
     [
      131,
      "3"
     ],
     [
      132,
      "4"
     ]
    ],
    131
   ],
   [
    "jog_lcd_brightness",
    3,
    "Jog LCD-lysstyrke",
    [
     [
      129,
      "1"
     ],
     [
      130,
      "2"
     ],
     [
      131,
      "3"
     ],
     [
      132,
      "4"
     ],
     [
      133,
      "5"
     ]
    ],
    131
   ],
   [
    "waveform_divisions",
    4,
    "Waveform divisions",
    [
     [
      128,
      "TIME SCALE"
     ],
     [
      129,
      "PHRASE"
     ]
    ],
    129
   ],
   [
    "waveform",
    10,
    "Waveform / Phase meter",
    [
     [
      128,
      "WAVEFORM"
     ],
     [
      129,
      "PHASE METER"
     ]
    ],
    128
   ],
   [
    "beat_jump_beat_value",
    12,
    "Beat jump beat value",
    [
     [
      128,
      "1/2 BEAT"
     ],
     [
      129,
      "1 BEAT"
     ],
     [
      130,
      "2 BEAT"
     ],
     [
      131,
      "4 BEAT"
     ],
     [
      132,
      "8 BEAT"
     ],
     [
      133,
      "16 BEAT"
     ],
     [
      134,
      "32 BEAT"
     ],
     [
      135,
      "64 BEAT"
     ]
    ],
    133
   ]
  ]
 },
 "DJMMYSETTING.DAT": {
  "size": 52,
  "fields": [
   [
    "channel_fader_curve",
    12,
    "Kanalfader-kurve",
    [
     [
      128,
      "Steep Top"
     ],
     [
      129,
      "Linear"
     ],
     [
      130,
      "Steep Bottom"
     ]
    ],
    129
   ],
   [
    "crossfader_curve",
    13,
    "Crossfader-kurve",
    [
     [
      128,
      "Constant Power"
     ],
     [
      129,
      "Slow Cut"
     ],
     [
      130,
      "Fast Cut"
     ]
    ],
    130
   ],
   [
    "headphones_pre_eq",
    14,
    "Hovedtelefon pre EQ",
    [
     [
      128,
      "POST EQ"
     ],
     [
      129,
      "PRE EQ"
     ]
    ],
    128
   ],
   [
    "headphones_mono_split",
    15,
    "Hovedtelefon mono split",
    [
     [
      129,
      "MONO SPLIT"
     ],
     [
      128,
      "STEREO"
     ]
    ],
    128
   ],
   [
    "beat_fx_quantize",
    16,
    "Beat FX quantize",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON"
     ]
    ],
    129
   ],
   [
    "mic_low_cut",
    17,
    "Mic low cut",
    [
     [
      128,
      "OFF"
     ],
     [
      129,
      "ON(for MC)"
     ]
    ],
    129
   ],
   [
    "talk_over_mode",
    18,
    "Talk over mode",
    [
     [
      128,
      "ADVANCED"
     ],
     [
      129,
      "NORMAL"
     ]
    ],
    128
   ],
   [
    "talk_over_level",
    19,
    "Talk over level",
    [
     [
      128,
      "-24dB"
     ],
     [
      129,
      "-18dB"
     ],
     [
      130,
      "-12dB"
     ],
     [
      131,
      "-6dB"
     ]
    ],
    129
   ],
   [
    "midi_channel",
    20,
    "MIDI-kanal",
    [
     [
      128,
      "1"
     ],
     [
      129,
      "2"
     ],
     [
      130,
      "3"
     ],
     [
      131,
      "4"
     ],
     [
      132,
      "5"
     ],
     [
      133,
      "6"
     ],
     [
      134,
      "7"
     ],
     [
      135,
      "8"
     ],
     [
      136,
      "9"
     ],
     [
      137,
      "10"
     ],
     [
      138,
      "11"
     ],
     [
      139,
      "12"
     ],
     [
      140,
      "13"
     ],
     [
      141,
      "14"
     ],
     [
      142,
      "15"
     ],
     [
      143,
      "16"
     ]
    ],
    128
   ],
   [
    "midi_button_type",
    21,
    "MIDI-knaptype",
    [
     [
      128,
      "TOGGLE"
     ],
     [
      129,
      "TRIGGER"
     ]
    ],
    128
   ],
   [
    "display_brightness",
    22,
    "Display-lysstyrke",
    [
     [
      128,
      "WHITE"
     ],
     [
      129,
      "1"
     ],
     [
      130,
      "2"
     ],
     [
      131,
      "3"
     ],
     [
      132,
      "4"
     ],
     [
      133,
      "5"
     ]
    ],
    133
   ],
   [
    "indicator_brightness",
    23,
    "Indikator-lysstyrke",
    [
     [
      128,
      "1"
     ],
     [
      129,
      "2"
     ],
     [
      130,
      "3"
     ]
    ],
    130
   ],
   [
    "channel_fader_curve_long_fader",
    24,
    "Kanalfader-kurve (lang fader)",
    [
     [
      128,
      "Exponential"
     ],
     [
      129,
      "Smooth"
     ],
     [
      130,
      "Linear"
     ]
    ],
    128
   ]
  ]
 }
}

BRANDS = {"DEVSETTING.DAT": "PIONEER DJ", "DJMMYSETTING.DAT": "PioneerDJ", "MYSETTING.DAT": "PIONEER", "MYSETTING2.DAT": "PIONEER"}


def crc16_xmodem(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def _checksum(name, raw):
    n = struct.unpack_from("<I", raw, 100)[0]
    if name == "DJMMYSETTING.DAT":
        return crc16_xmodem(raw[:104 + n])
    return crc16_xmodem(raw[104:104 + n])


def parse(name, raw):
    if len(raw) < 108 or struct.unpack_from("<I", raw, 0)[0] != 0x60:
        raise ValueError("%s er ikke en gyldig indstillingsfil" % name)
    n = struct.unpack_from("<I", raw, 100)[0]
    if n != LAYOUT[name]["size"] or len(raw) < 104 + n + 4:
        raise ValueError("%s har en ukendt længde (%d)" % (name, n))
    stored = struct.unpack_from("<H", raw, 104 + n)[0]
    data = raw[104:104 + n]
    values = {}
    for fname, off, label, options, default in LAYOUT[name]["fields"]:
        values[fname] = data[off]
    return {"values": values, "crc_ok": stored == _checksum(name, raw),
            "software": raw[36:68].split(b"\x00")[0].decode("ascii", "replace"),
            "version": raw[68:100].split(b"\x00")[0].decode("ascii", "replace")}


def build(name, values, base=None):
    """Ny fil: tager `base` (den eksisterende fil) og ændrer kun de felter der står i `values`."""
    n = LAYOUT[name]["size"]
    if base:
        raw = bytearray(base[:104 + n + 4])
    else:
        raw = bytearray(struct.pack("<I", 0x60))
        for s in (BRANDS[name], "rekordbox", "6.6.1"):
            raw += s.encode("ascii").ljust(32, b"\x00")
        raw += struct.pack("<I", n)
        data = bytearray(n)
        if name == "DEVSETTING.DAT":
            data[0:9] = bytes([0x78, 0x56, 0x34, 0x12, 0x01, 0x00, 0x00, 0x00, 0x01])
            data[11] = 0x01
        if name == "MYSETTING2.DAT":
            data[11] = 0x81
        for fname, off, label, options, default in LAYOUT[name]["fields"]:
            data[off] = default
        raw += data + b"\x00\x00\x00\x00"
    fields = {f[0]: f for f in LAYOUT[name]["fields"]}
    for k, v in (values or {}).items():
        f = fields.get(k)
        if not f:
            raise ValueError("Ukendt indstilling: %s" % k)
        if int(v) not in [o[0] for o in f[3]]:
            raise ValueError("Ugyldig værdi for %s: %s" % (f[2], v))
        raw[104 + f[1]] = int(v)
    struct.pack_into("<HH", raw, 104 + n, _checksum(name, raw), 0)
    return bytes(raw)


def read_settings(root):
    out = {"ok": True, "files": {}, "layout": LAYOUT}
    for name in LAYOUT:
        p = os.path.join(root, "PIONEER", name)
        if not os.path.exists(p):
            out["files"][name] = {"missing": True}
            continue
        try:
            with open(p, "rb") as f:
                out["files"][name] = parse(name, f.read())
        except ValueError as e:
            out["files"][name] = {"error": str(e)}
    return out


def write_settings(root, changes):
    """changes = {"DEVSETTING.DAT": {"waveform_color": 3}, …}. Backup af de gamle filer i PIONEER/MODULR-settings-backup."""
    import datetime
    import shutil
    base = os.path.join(root, "PIONEER")
    if not os.path.isdir(base):
        raise ValueError("Ingen PIONEER-mappe på USB'en")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    bdir = os.path.join(base, "MODULR-settings-backup", stamp)
    written = []
    for name, values in changes.items():
        if name not in LAYOUT:
            raise ValueError("Ukendt fil: %s" % name)
        p = os.path.join(base, name)
        old = open(p, "rb").read() if os.path.exists(p) else None
        if old is not None:
            parse(name, old)                       # nægt at skrive oven i noget vi ikke forstår
        new = build(name, values, old)
        parse(name, new)                           # kontrol: kan læses igen, og CRC'en stemmer
        if old is not None:
            os.makedirs(bdir, exist_ok=True)
            shutil.copy2(p, os.path.join(bdir, name))
        tmp = p + ".modulr-tmp"
        with open(tmp, "wb") as f:
            f.write(new)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, p)
        written.append(name)
    return {"ok": True, "written": written}


def main():
    cmd, root = sys.argv[1], sys.argv[2]
    try:
        if cmd == "read":
            res = read_settings(root)
        elif cmd == "write":
            res = write_settings(root, json.load(sys.stdin))
        else:
            res = {"ok": False, "error": "ukendt kommando"}
    except Exception as e:  # noqa
        res = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
