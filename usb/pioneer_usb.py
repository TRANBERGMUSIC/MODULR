#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MODULR – læser og skriver Pioneers USB-bibliotek (Device Library: PIONEER/rekordbox/export.pdb)
så CDJ'er (fx CDJ-3000) kan vise MODULRs playlister og spille sangene.

Formatet er ikke officielt dokumenteret. Denne kode bygger på det offentlige reverse-engineering-
arbejde fra Deep Symmetry (crate-digger), rekordcrate og pyrekordbox, og er testet mod rigtige
rekordbox-eksporter.

Sikkerhed: Vi ændrer ALDRIG eksisterende rækker. Nye rækker lægges i ledig plads i tabellens
sidste side eller i nye sider, der hægtes på tabellen. Før hver skrivning tages en backup af
hele PIONEER/rekordbox-mappen, og den nye database læses igen og tjekkes, før den erstatter
den gamle.

Kun Python 3.9-standardbiblioteket (følger med Apples udviklerværktøjer).

Brug (JSON ind/ud):
  python3 pioneer_usb.py read  /Volumes/USB
  python3 pioneer_usb.py write /Volumes/USB < plan.json
"""

import datetime
import json
import os
import shutil
import struct
import sys
import tempfile

# Tabeltyper (page_type)
T_TRACKS, T_GENRES, T_ARTISTS, T_ALBUMS, T_LABELS, T_KEYS, T_COLORS = 0, 1, 2, 3, 4, 5, 6
T_PLAYLIST_TREE, T_PLAYLIST_ENTRIES = 7, 8
T_ARTWORK = 13

HEAP_START = 0x28          # 0x20 sidehoved + 8 bytes datasidehoved
ROW_GROUP_SIZE = 0x24      # 16 * 2 offsets + 2 flag + 2 transaktionsflag
EMPTY_INDEX_ENTRY = 0x1FFFFFF8

FILE_TYPES = {"mp3": 0x1, "m4a": 0x4, "aac": 0x4, "flac": 0x5, "wav": 0xB, "aif": 0xC, "aiff": 0xC}


class PdbError(Exception):
    pass


# ---------------------------------------------------------------------------------------------
# DeviceSQL-strenge
# ---------------------------------------------------------------------------------------------

def encode_string(s):
    """Koder en streng som DeviceSQL: kort ASCII, lang ASCII eller UTF-16LE."""
    if s is None:
        s = ""
    try:
        raw = s.encode("ascii")
        is_ascii = True
    except UnicodeEncodeError:
        is_ascii = False
    if is_ascii and len(raw) <= 126:
        return bytes([((len(raw) + 1) << 1) | 1]) + raw
    if is_ascii:
        return struct.pack("<BHB", 0x40, len(raw) + 4, 0) + raw
    body = s.encode("utf-16-le")
    return struct.pack("<BHB", 0x90, len(body) + 4, 0) + body


def string_alignment(s):
    """UTF-16-strenge skal ligge 4-byte-justeret (ellers kan CDJ'en gå ned)."""
    if s is None:
        return 1
    try:
        s.encode("ascii")
        return 1
    except UnicodeEncodeError:
        return 4


def decode_string(buf, pos):
    flags = buf[pos]
    if flags & 1:
        n = (flags >> 1) - 1
        return bytes(buf[pos + 1:pos + 1 + n]).decode("ascii", "replace")
    length = struct.unpack_from("<H", buf, pos + 1)[0]
    body = bytes(buf[pos + 4:pos + length])
    if flags == 0x40:
        return body.decode("ascii", "replace")
    if flags == 0x90:
        # ISRC gemmes med et ekstra 0x03-præfiks
        if body[:1] == b"\x03":
            return body[1:].split(b"\x00")[0].decode("ascii", "replace")
        return body.decode("utf-16-le", "replace")
    return ""


def build_with_strings(fixed, strings, offset_size, magic_pos=None):
    """Bygger en række: fast del + offset-array (0x03-magic + N offsets) + strenge.
    Offsets regnes fra rækkens start; UTF-16 justeres til 4 bytes."""
    n = len(strings)
    header_len = len(fixed) + (n + 1) * offset_size
    out = bytearray(fixed)
    out += b"\x00" * ((n + 1) * offset_size)
    offsets = []
    for s in strings:
        align = string_alignment(s)
        while len(out) % align:
            out.append(0)
        offsets.append(len(out))
        out += encode_string(s)
    pos = len(fixed)
    if offset_size == 1:
        out[pos] = 0x03
        for i, o in enumerate(offsets):
            if o > 0xFF:
                raise PdbError("offset for stor til 8-bit")
            out[pos + 1 + i] = o
    else:
        struct.pack_into("<H", out, pos, 0x0003)
        for i, o in enumerate(offsets):
            struct.pack_into("<H", out, pos + 2 + 2 * i, o)
    assert header_len == pos + (n + 1) * offset_size
    return bytes(out)


# ---------------------------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------------------------

class Pdb(object):
    def __init__(self, data):
        self.data = bytearray(data)
        (z, self.page_size, self.num_tables, self.next_unused_page,
         self.unknown_hdr, self.sequence, gap) = struct.unpack_from("<7I", self.data, 0)
        if z != 0 or self.page_size not in (4096, 8192) or not (10 <= self.num_tables <= 40):
            raise PdbError("Ikke en gyldig export.pdb")
        self.tables = []
        for i in range(self.num_tables):
            t, ec, first, last = struct.unpack_from("<4I", self.data, 0x1C + 16 * i)
            self.tables.append({"type": t, "empty_candidate": ec, "first": first, "last": last, "slot": i})
        self.num_pages = len(self.data) // self.page_size

    # -- sider --

    def table(self, t):
        for tb in self.tables:
            if tb["type"] == t:
                return tb
        raise PdbError("Tabel %d findes ikke" % t)

    def page_off(self, i):
        return i * self.page_size

    def page_header(self, i):
        o = self.page_off(i)
        (z, idx, ptype, nxt, seq, unk2) = struct.unpack_from("<6I", self.data, o)
        b = self.data[o + 0x18:o + 0x1B]
        packed = b[0] | (b[1] << 8) | (b[2] << 16)
        num_rows = packed & 0x1FFF
        num_valid = (packed >> 13) & 0x7FF
        flags = self.data[o + 0x1B]
        free_size, used_size = struct.unpack_from("<HH", self.data, o + 0x1C)
        return {"index": idx, "type": ptype, "next": nxt, "seq": seq, "num_rows": num_rows,
                "num_valid": num_valid, "flags": flags, "free": free_size, "used": used_size}

    def set_row_counts(self, i, num_rows, num_valid):
        o = self.page_off(i)
        packed = (num_rows & 0x1FFF) | ((num_valid & 0x7FF) << 13)
        self.data[o + 0x18] = packed & 0xFF
        self.data[o + 0x19] = (packed >> 8) & 0xFF
        self.data[o + 0x1A] = (packed >> 16) & 0xFF

    def table_pages(self, t):
        tb = self.table(t)
        out = []
        seen = set()
        i = tb["first"]
        while i not in seen and i < self.num_pages:
            seen.add(i)
            h = self.page_header(i)
            if h["type"] != t:
                break
            out.append(i)
            if i == tb["last"]:
                break
            i = h["next"]
        return out

    def is_data_page(self, h):
        return (h["flags"] & 0x40) == 0

    def row_offsets(self, i):
        """Absolutte positioner for de rækker der er til stede på en dataside."""
        h = self.page_header(i)
        if not self.is_data_page(h):
            return []
        o = self.page_off(i)
        end = o + self.page_size
        out = []
        n = h["num_rows"]
        groups = (n + 15) // 16
        for g in range(groups):
            base = end - g * ROW_GROUP_SIZE
            present = struct.unpack_from("<H", self.data, base - 4)[0]
            for r in range(16):
                ri = g * 16 + r
                if ri >= n:
                    break
                ofs = struct.unpack_from("<H", self.data, base - 6 - 2 * r)[0]
                if (present >> r) & 1:
                    out.append(o + HEAP_START + ofs)
        return out

    def rows(self, t):
        for p in self.table_pages(t):
            for pos in self.row_offsets(p):
                yield pos

    # -- rækker (læsning) --

    def _strings(self, pos, n, ofs_at, size):
        res = []
        for k in range(n):
            if size == 1:
                o = self.data[ofs_at + 1 + k]
            else:
                o = struct.unpack_from("<H", self.data, ofs_at + 2 + 2 * k)[0]
            res.append(decode_string(self.data, pos + o))
        return res

    def read_track(self, pos):
        f = struct.unpack_from("<HHIIIIIHHIIIIIIIIIIII HHHHHH BBH", self.data, pos)
        (subtype, ishift, bitmask, sr, composer, fsize, u2, u3, u4, art, key, orig, label, remix,
         bitrate, trackno, tempo, genre, album, artist, tid, disc, plays, year, depth, dur, u5,
         color, rating, ftype) = f
        s = self._strings(pos, 21, pos + 0x5C, 2)
        return {"id": tid, "title": s[17], "artist_id": artist, "album_id": album, "genre_id": genre,
                "key_id": key, "artwork_id": art, "bpm": tempo / 100.0, "duration": dur, "path": s[20],
                "filename": s[19], "analyze_path": s[14], "date_added": s[10], "u3": u3, "u4": u4,
                "bitrate": bitrate, "sample_rate": sr, "depth": depth, "file_type": ftype, "comment": s[16]}

    def read_named(self, pos, t):
        if t == T_ARTISTS:
            subtype, ishift, rid = struct.unpack_from("<HHI", self.data, pos)
            far = subtype & 0x04
            return {"id": rid, "name": self._strings(pos, 1, pos + 8, 2 if far else 1)[0]}
        if t == T_ALBUMS:
            subtype, ishift, u2, artist, rid, u3 = struct.unpack_from("<HHIIII", self.data, pos)
            far = subtype & 0x04
            return {"id": rid, "artist_id": artist, "name": self._strings(pos, 1, pos + 20, 2 if far else 1)[0]}
        if t in (T_GENRES, T_LABELS):
            rid = struct.unpack_from("<I", self.data, pos)[0]
            return {"id": rid, "name": decode_string(self.data, pos + 4)}
        if t == T_KEYS:
            rid, rid2 = struct.unpack_from("<II", self.data, pos)
            return {"id": rid, "name": decode_string(self.data, pos + 8)}
        if t == T_ARTWORK:
            rid = struct.unpack_from("<I", self.data, pos)[0]
            return {"id": rid, "path": decode_string(self.data, pos + 4)}
        if t == T_PLAYLIST_TREE:
            parent, unk, sort, rid, raw_is_folder = struct.unpack_from("<5I", self.data, pos)
            return {"id": rid, "parent": parent, "sort": sort, "folder": raw_is_folder != 0,
                    "name": decode_string(self.data, pos + 20)}
        if t == T_PLAYLIST_ENTRIES:
            idx, track, pl = struct.unpack_from("<3I", self.data, pos)
            return {"index": idx, "track_id": track, "playlist_id": pl}
        raise PdbError("ukendt tabel")

    def all(self, t):
        if t == T_TRACKS:
            return [self.read_track(p) for p in self.rows(t)]
        return [self.read_named(p, t) for p in self.rows(t)]

    def max_id(self, t):
        ids = [r["id"] for r in self.all(t)] if t != T_PLAYLIST_ENTRIES else [0]
        return max(ids) if ids else 0

    # -- skrivning --

    def _page_in_use(self, i):
        for tb in self.tables:
            if i in self.table_pages(tb["type"]):
                return True
        return False

    def _new_page(self, t, template_page):
        """Hægter en ny, tom dataside på tabellen – på den side rekordbox selv har reserveret
        (tabellens empty_candidate) – og returnerer dens nummer."""
        tb = self.table(t)
        new_index = tb["empty_candidate"]
        if new_index == 0 or self._page_in_use(new_index) or new_index < 1:
            new_index = self.next_unused_page
            self.next_unused_page += 1
        new_candidate = self.next_unused_page
        self.next_unused_page += 1
        struct.pack_into("<I", self.data, 12, self.next_unused_page)

        if len(self.data) < (new_index + 1) * self.page_size:
            self.data += b"\x00" * ((new_index + 1) * self.page_size - len(self.data))
        o = self.page_off(new_index)
        self.data[o:o + self.page_size] = b"\x00" * self.page_size
        struct.pack_into("<6I", self.data, o, 0, new_index, t, new_candidate, self.sequence, 0)
        self.data[o + 0x1B] = 0x24                                   # dataside
        struct.pack_into("<HH", self.data, o + 0x1C, self.page_size - HEAP_START, 0)
        # Datasidehoved: kopiér fra en eksisterende dataside i tabellen (ukendte felter)
        if template_page is not None:
            to = self.page_off(template_page)
            self.data[o + 0x20:o + 0x28] = self.data[to + 0x20:to + 0x28]
        else:
            struct.pack_into("<HHHH", self.data, o + 0x20, 1, 0, 0, 0)

        # Hægt på: den gamle sidste side peger nu på den nye
        old_last = tb["last"]
        lo = self.page_off(old_last)
        struct.pack_into("<I", self.data, lo + 12, new_index)
        if not self.is_data_page(self.page_header(old_last)):
            struct.pack_into("<I", self.data, lo + 0x20 + 12, new_index)    # indekssidens kopi af next_page
        tb["last"] = new_index
        tb["empty_candidate"] = new_candidate
        struct.pack_into("<I", self.data, 0x1C + 16 * tb["slot"] + 4, new_candidate)
        struct.pack_into("<I", self.data, 0x1C + 16 * tb["slot"] + 12, new_index)
        self.num_pages = len(self.data) // self.page_size
        self._add_index_entry(t, new_index)
        return new_index

    def _add_index_entry(self, t, data_page):
        """Skriver den nye dataside ind i tabellens indeksside, hvis der er en ledig plads."""
        tb = self.table(t)
        first = tb["first"]
        h = self.page_header(first)
        if self.is_data_page(h):
            return
        o = self.page_off(first) + 0x20
        num_entries = struct.unpack_from("<H", self.data, o + 0x18)[0]
        capacity = (self.page_size - 0x20 - 28 - 20) // 4
        if num_entries >= capacity:
            return
        entry_pos = o + 28 + 4 * num_entries
        if struct.unpack_from("<I", self.data, entry_pos)[0] != EMPTY_INDEX_ENTRY:
            return
        struct.pack_into("<I", self.data, entry_pos, data_page << 3)
        struct.pack_into("<H", self.data, o + 0x18, num_entries + 1)
        next_offset = struct.unpack_from("<H", self.data, o + 6)[0]
        struct.pack_into("<H", self.data, o + 6, max(next_offset, num_entries + 1))
        first_empty = struct.unpack_from("<H", self.data, o + 0x1A)[0]
        if first_empty != 0x1FFF:
            struct.pack_into("<H", self.data, o + 0x1A, num_entries + 1)

    def insert_row(self, t, build):
        """`build(row_index_in_page)` returnerer rækkens bytes. Returnerer sidenummeret."""
        pages = self.table_pages(t)
        data_pages = [p for p in pages if self.is_data_page(self.page_header(p))]
        template = data_pages[-1] if data_pages else None
        target = pages[-1] if pages else None
        if target is None:
            raise PdbError("Tabel %d mangler sider" % t)
        for attempt in range(2):
            h = self.page_header(target)
            if self.is_data_page(h):
                row = build(h["num_rows"])
                size = (len(row) + 3) & ~3
                new_group = (h["num_rows"] % 16) == 0
                need = size + 2 + (4 if new_group else 0)
                if h["free"] >= need and h["num_rows"] < 0x1FFF:
                    self._put_row(target, h, row, size, new_group)
                    return target
            if attempt == 0:
                target = self._new_page(t, template)
        raise PdbError("Rækken er for stor til en side")

    def _put_row(self, p, h, row, size, new_group):
        o = self.page_off(p)
        heap_ofs = h["used"]
        self.data[o + HEAP_START + heap_ofs:o + HEAP_START + heap_ofs + len(row)] = row
        for k in range(len(row), size):
            self.data[o + HEAP_START + heap_ofs + k] = 0
        n = h["num_rows"]
        g, r = divmod(n, 16)
        base = o + self.page_size - g * ROW_GROUP_SIZE
        free = h["free"] - size - 2 - (4 if new_group else 0)
        if new_group:
            struct.pack_into("<HH", self.data, base - 4, 0, 0)
        struct.pack_into("<H", self.data, base - 6 - 2 * r, heap_ofs)
        present = struct.unpack_from("<H", self.data, base - 4)[0] | (1 << r)
        tx = struct.unpack_from("<H", self.data, base - 2)[0] | (1 << r)
        struct.pack_into("<HH", self.data, base - 4, present, tx)
        self.set_row_counts(p, n + 1, h["num_valid"] + 1)
        struct.pack_into("<HH", self.data, o + 0x1C, free, h["used"] + size)
        struct.pack_into("<I", self.data, o + 0x10, self.sequence)          # sidens sekvens

    def bump_sequence(self):
        self.sequence += 1
        struct.pack_into("<I", self.data, 0x14, self.sequence)

    # -- rækkebyggere --

    def add_named(self, t, name, extra=None):
        new_id = self.max_id(t) + 1
        if t == T_ARTISTS:
            def b(ri):
                far = len(encode_string(name)) + 10 > 0xFF
                fixed = struct.pack("<HHI", 0x64 if far else 0x60, (ri * 0x20) & 0xFFFF, new_id)
                row = build_with_strings(fixed, [name], 2 if far else 1)
                return row + b"\x00" * 6        # rekordbox lader 6 bytes være til redigering
        elif t == T_ALBUMS:
            artist_id = (extra or {}).get("artist_id", 0)

            def b(ri):
                far = len(encode_string(name)) + 22 > 0xFF
                fixed = struct.pack("<HHIIII", 0x84 if far else 0x80, (ri * 0x20) & 0xFFFF, 0, artist_id, new_id, 0)
                return build_with_strings(fixed, [name], 2 if far else 1) + b"\x00" * 6
        elif t in (T_GENRES, T_LABELS):
            def b(ri):
                return struct.pack("<I", new_id) + encode_string(name)
        elif t == T_KEYS:
            def b(ri):
                return struct.pack("<II", new_id, new_id) + encode_string(name)
        elif t == T_ARTWORK:
            def b(ri):
                return struct.pack("<I", new_id) + encode_string(name)
        else:
            raise PdbError("ukendt tabel")
        self.insert_row(t, b)
        return new_id

    def find_or_add(self, t, name, extra=None):
        if not name:
            return 0
        for r in self.all(t):
            if r.get("name", r.get("path")) == name and (t != T_ALBUMS or r.get("artist_id") == (extra or {}).get("artist_id", r.get("artist_id"))):
                return r["id"]
        return self.add_named(t, name, extra)

    def add_playlist_node(self, name, parent_id, is_folder):
        existing = self.all(T_PLAYLIST_TREE)
        new_id = max([r["id"] for r in existing] + [0]) + 1
        # Nye playlister/mapper lægges ØVERST (som det første man ser på CDJ'en): enten før den laveste
        # eksisterende sortering, eller – hvis der ikke er plads – skubbes søskende én ned.
        siblings = [r for r in existing if r["parent"] == parent_id]
        if not siblings:
            sort = 0
        else:
            low = min(r["sort"] for r in siblings)
            if low > 0:
                sort = low - 1
            else:
                for p in list(self.rows(T_PLAYLIST_TREE)):
                    r = self.read_named(p, T_PLAYLIST_TREE)
                    if r["parent"] == parent_id:
                        struct.pack_into("<I", self.data, p + 8, r["sort"] + 1)
                sort = 0

        def b(ri):
            return struct.pack("<5I", parent_id, 0, sort, new_id, 1 if is_folder else 0) + encode_string(name)
        self.insert_row(T_PLAYLIST_TREE, b)
        return new_id

    def add_playlist_entry(self, playlist_id, track_id):
        entries = [e for e in self.all(T_PLAYLIST_ENTRIES) if e["playlist_id"] == playlist_id]
        if any(e["track_id"] == track_id for e in entries):
            return
        idx = max([e["index"] for e in entries] + [0]) + 1

        def b(ri):
            return struct.pack("<3I", idx, track_id, playlist_id)
        self.insert_row(T_PLAYLIST_ENTRIES, b)

    def add_track(self, t):
        """t: dict med titel, kunstner-id osv. Returnerer det nye track-id."""
        tracks = self.all(T_TRACKS)
        new_id = max([x["id"] for x in tracks] + [0]) + 1
        # Felter der er ens for alle spor i en database kopieres fra et eksisterende spor
        u3, u4 = (tracks[0]["u3"], tracks[0]["u4"]) if tracks else (0x4A68, 0x78F7)
        today = datetime.date.today().isoformat()
        strings = [
            "",                                  # isrc
            "",                                  # lyricist
            str(t.get("u2", 1)),                 # unknown_string2 (tal)
            str(t.get("u3", 1)),                 # unknown_string3 (tal)
            "",                                  # unknown_string4
            "",                                  # message
            "ON",                                # publish_track_information
            "ON",                                # autoload_hotcues
            "",                                  # unknown_string5
            "",                                  # unknown_string6
            t.get("date_added") or today,        # date_added
            "",                                  # release_date
            t.get("mix_name", ""),               # mix_name
            "",                                  # unknown_string7
            t.get("analyze_path", ""),           # analyze_path
            today if t.get("analyze_path") else "",  # analyze_date
            t.get("comment", ""),                # comment
            t.get("title", ""),                  # title
            "",                                  # unknown_string8
            t.get("filename", ""),               # filename
            t.get("path", ""),                   # file_path
        ]

        def b(ri):
            fixed = struct.pack(
                "<HHIIIIIHHIIIIIIIIIIII",
                0x24, (ri * 0x20) & 0xFFFF, 0x000C0700,
                int(t.get("sample_rate", 44100)), 0, int(t.get("file_size", 0)) & 0xFFFFFFFF,
                (new_id * 2654435761) & 0xFFFFFFFF, u3, u4,
                int(t.get("artwork_id", 0)), int(t.get("key_id", 0)), 0, 0, 0,
                int(t.get("bitrate", 0)), 0, int(round(float(t.get("bpm", 0)) * 100)),
                int(t.get("genre_id", 0)), int(t.get("album_id", 0)), int(t.get("artist_id", 0)), new_id)
            fixed += struct.pack("<HHHHHH", 0, 0, int(t.get("year", 0)), int(t.get("depth", 16)),
                                 int(t.get("duration", 0)), 0x29)
            fixed += struct.pack("<BBH", int(t.get("color", 0)), 0, FILE_TYPES.get(t.get("ext", ""), 0))
            assert len(fixed) == 0x5C
            row = build_with_strings(fixed, strings, 2)
            # rekordbox lader ca. 48 bytes være bag nye spor-rækker (til redigering på CDJ'en)
            return row + b"\x00" * 48
        self.insert_row(T_TRACKS, b)
        return new_id


# ---------------------------------------------------------------------------------------------
# Analysefiler (ANLZ) – sti, beatgrid og waveforms til CDJ'en
# ---------------------------------------------------------------------------------------------

def _tag(fourcc, header_extra, body):
    hdr_len = 12 + len(header_extra)
    return fourcc + struct.pack(">II", hdr_len, hdr_len + len(body)) + header_extra + body


def _ppth(path):
    body = (path + "\x00").encode("utf-16-be")
    return _tag(b"PPTH", struct.pack(">I", len(body)), body)


def _pqtz(bpm, first_beat_ms, duration_s):
    """Beatgrid: én række per slag med takt-position, tempo (×100) og tid i ms."""
    beats = []
    if bpm > 0:
        step = 60000.0 / bpm
        t = first_beat_ms
        n = 0
        while t < duration_s * 1000.0:
            beats.append(struct.pack(">HHI", (n % 4) + 1, int(round(bpm * 100)), int(round(t))))
            t += step
            n += 1
    body = b"".join(beats)
    return _tag(b"PQTZ", struct.pack(">III", 0, 0x00080000, len(beats)), body)


def _pwav(cols):
    """Monokrom oversigt: 400 bytes (højde 0–31 i de 5 lave bits, hvidhed i de 3 høje)."""
    return _tag(b"PWAV", struct.pack(">II", 400, 0x00010000), bytes(cols))


def _pwv2(cols):
    return _tag(b"PWV2", struct.pack(">II", 100, 0x00010000), bytes(cols))


def _pvbr():
    return _tag(b"PVBR", struct.pack(">I", 0), b"\x00" * 1604)


def _pcob(kind):
    return _tag(b"PCOB", struct.pack(">IIi", kind, 0, -1), b"")


def _pco2(kind):
    return _tag(b"PCO2", struct.pack(">II", kind, 0), b"")


def _pwv3(cols):
    return _tag(b"PWV3", struct.pack(">III", 1, len(cols), 0x00960000), bytes(cols))


def _pwv4(cols6):
    return _tag(b"PWV4", struct.pack(">III", 6, len(cols6) // 6, 0), bytes(cols6))


def _pwv5(words):
    body = b"".join(struct.pack(">H", w) for w in words)
    return _tag(b"PWV5", struct.pack(">III", 2, len(words), 0x00960305), body)


def _anlz_file(sections):
    body = b"".join(sections)
    hdr_len = 28
    return b"PMAI" + struct.pack(">II", hdr_len, hdr_len + len(body)) + struct.pack(">IIII", 1, 0x00010000, 0x00010000, 0) + body


def _resample_max(bands, n):
    """Grupperer 150/s-kolonner ned til n kolonner (største værdi pr. gruppe)."""
    total = len(bands)
    out = []
    for i in range(n):
        a = i * total // n
        b = max(a + 1, (i + 1) * total // n)
        chunk = bands[a:b] if a < total else [(0, 0, 0)]
        out.append(tuple(max(c[k] for c in chunk) for k in range(3)))
    return out


def waveforms_from_bands(bands):
    """bands: liste af (lav, mellem, høj) 0–255 med 150 kolonner pr. sekund – MODULRs analyse.
    Returnerer rekordbox' formater: PWAV, PWV2, PWV3, PWV4, PWV5."""
    if not bands:
        bands = [(0, 0, 0)]
    detail = []
    color_detail = []
    for lo, mi, hi in bands:
        h = max(lo, mi, hi) * 31 // 255
        detail.append((h & 0x1F) | (((hi >> 5) & 0x7) << 5))
        color_detail.append(((lo >> 5) << 13) | ((mi >> 5) << 10) | ((hi >> 5) << 7) | (h << 2))
    prev = _resample_max(bands, 400)
    pwav = [(max(c) * 31 // 255) | ((c[2] >> 5) << 5) for c in prev]
    tiny = [max(c) * 15 // 255 for c in _resample_max(bands, 100)]
    cprev = []
    for lo, mi, hi in _resample_max(bands, 1200):
        top = max(lo, mi, hi)
        cprev += [top, top, max(lo, mi), lo, mi, hi]
    return pwav, tiny, detail, cprev, color_detail


def write_anlz(folder, usb_path, analysis):
    """Skriver ANLZ0000.DAT og .EXT ud fra MODULRs analyse (beatgrid + waveforms)."""
    import base64
    os.makedirs(folder, exist_ok=True)
    bpm = float(analysis.get("bpm") or 0)
    dur = float(analysis.get("duration") or 0)
    first = float(analysis.get("first_beat_ms") or 0)
    raw = base64.b64decode(analysis.get("bands") or "")
    bands = [(raw[i], raw[i + 1], raw[i + 2]) for i in range(0, len(raw) - 2, 3)]
    if not bands:
        bands = [(0, 0, 0)] * max(1, int(dur * 150))
    pwav, tiny, detail, cprev, cdet = waveforms_from_bands(bands)
    dat = _anlz_file([_ppth(usb_path), _pvbr(), _pqtz(bpm, first, dur), _pwav(pwav), _pwv2(tiny), _pcob(1), _pcob(0)])
    ext = _anlz_file([_ppth(usb_path), _pwv3(detail), _pcob(1), _pcob(0), _pco2(1), _pco2(0), _pwv5(cdet), _pwv4(cprev)])
    with open(os.path.join(folder, "ANLZ0000.DAT"), "wb") as f:
        f.write(dat)
    with open(os.path.join(folder, "ANLZ0000.EXT"), "wb") as f:
        f.write(ext)


# ---------------------------------------------------------------------------------------------
# USB: læs og skriv
# ---------------------------------------------------------------------------------------------

def pdb_path(root):
    return os.path.join(root, "PIONEER", "rekordbox", "export.pdb")


def read_usb(root):
    p = pdb_path(root)
    if not os.path.exists(p):
        return {"ok": False, "error": "Ingen rekordbox-database på USB'en (PIONEER/rekordbox/export.pdb). Eksportér mindst én playliste fra rekordbox først."}
    with open(p, "rb") as f:
        db = Pdb(f.read())
    artists = {a["id"]: a["name"] for a in db.all(T_ARTISTS)}
    keys = {k["id"]: k["name"] for k in db.all(T_KEYS)}
    arts = {a["id"]: a["path"] for a in db.all(T_ARTWORK)}
    tracks = []
    for t in db.all(T_TRACKS):
        tracks.append({"id": t["id"], "title": t["title"], "artist": artists.get(t["artist_id"], ""),
                       "bpm": t["bpm"], "key": keys.get(t["key_id"], ""), "duration": t["duration"],
                       "path": t["path"], "artwork": arts.get(t.get("artwork_id", 0), "")})
    nodes = db.all(T_PLAYLIST_TREE)
    entries = db.all(T_PLAYLIST_ENTRIES)
    for n in nodes:
        n["tracks"] = [e["track_id"] for e in sorted([e for e in entries if e["playlist_id"] == n["id"]],
                                                    key=lambda e: e["index"])]
    has_onelibrary = os.path.exists(os.path.join(root, "PIONEER", "rekordbox", "exportLibrary.db")) or \
        os.path.exists(os.path.join(root, "PIONEER", "rekordbox", "OneLibrary"))
    return {"ok": True, "tracks": tracks, "nodes": nodes, "onelibrary": has_onelibrary}


def safe_name(s, fallback):
    s = "".join(c for c in (s or "") if c not in '/\\:*?"<>|\x00').strip().strip(".")
    return (s or fallback)[:80]


def write_usb(root, plan):
    """
    plan = {
      "folders":   [{"key": "f1", "name": "...", "parent": <node-id eller "key" eller 0>}],
      "playlists": [{"key": "p1", "name": "...", "parent": ..., "tracks": [<track>, ...]}],
      "add_to":    [{"playlist": <eksisterende node-id>, "tracks": [<track>, ...]}]
    }
    <track> = {"source": "/sti/fil.wav", "title", "artist", "album", "genre", "key" (fx "8A"),
               "bpm", "duration", "year", "sample_rate", "bitrate", "depth", "artwork": "/sti/cover.jpg",
               "analysis": {...}}
    """
    p = pdb_path(root)
    with open(p, "rb") as f:
        original = f.read()
    db = Pdb(original)

    # 1) Backup af hele rekordbox-mappen
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(root, "PIONEER", "MODULR-backup-" + stamp)
    shutil.copytree(os.path.join(root, "PIONEER", "rekordbox"), backup)

    copied = {}            # kilde-sti -> track-id
    existing_by_path = {t["path"]: t["id"] for t in db.all(T_TRACKS)}
    contents = os.path.join(root, "Contents")
    log = []

    def ensure_track(tr):
        src = tr["source"]
        if src in copied:
            return copied[src]
        ext = os.path.splitext(src)[1].lower().lstrip(".")
        artist = safe_name(tr.get("artist"), "Unknown Artist")
        album = safe_name(tr.get("album"), "UnknownAlbum")
        fname = safe_name(os.path.basename(src), "track." + ext)
        usb_rel = "/Contents/%s/%s/%s" % (artist, album, fname)
        if usb_rel in existing_by_path:
            copied[src] = existing_by_path[usb_rel]
            return copied[src]
        dest = os.path.join(contents, artist, album, fname)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if not os.path.exists(dest) or os.path.getsize(dest) != os.path.getsize(src):
            shutil.copy2(src, dest)

        artist_id = db.find_or_add(T_ARTISTS, tr.get("artist") or "")
        album_id = db.find_or_add(T_ALBUMS, tr.get("album") or "", {"artist_id": artist_id})
        genre_id = db.find_or_add(T_GENRES, tr.get("genre") or "")
        key_id = db.find_or_add(T_KEYS, tr.get("key") or "")
        artwork_id = 0
        if tr.get("artwork") and os.path.exists(tr["artwork"]):
            next_art = db.max_id(T_ARTWORK) + 1
            art_rel = "/PIONEER/Artwork/00001/a%d.jpg" % next_art
            art_dest = os.path.join(root, art_rel.lstrip("/"))
            os.makedirs(os.path.dirname(art_dest), exist_ok=True)
            shutil.copy2(tr["artwork"], art_dest)                        # lille (80×80) til lister
            big = tr.get("artwork_m") if tr.get("artwork_m") and os.path.exists(tr["artwork_m"]) else tr["artwork"]
            shutil.copy2(big, art_dest.replace(".jpg", "_m.jpg"))         # stor (240×240) til afspilleren
            artwork_id = db.add_named(T_ARTWORK, art_rel)

        next_id = max([t["id"] for t in db.all(T_TRACKS)] + [0]) + 1
        anlz_rel = "/PIONEER/USBANLZ/P%03X/%08X/ANLZ0000.DAT" % (0x800 + (next_id >> 12) % 0x800, next_id)
        write_anlz(os.path.join(root, os.path.dirname(anlz_rel).lstrip("/")), usb_rel, tr.get("analysis") or {
            "bpm": tr.get("bpm"), "duration": tr.get("duration")})
        tid = db.add_track({
            "title": tr.get("title") or os.path.splitext(fname)[0], "artist_id": artist_id, "album_id": album_id,
            "genre_id": genre_id, "key_id": key_id, "artwork_id": artwork_id, "bpm": tr.get("bpm") or 0,
            "duration": int(round(tr.get("duration") or 0)), "year": tr.get("year") or 0,
            "sample_rate": tr.get("sample_rate") or 44100, "bitrate": tr.get("bitrate") or 0,
            "depth": tr.get("depth") or 16, "file_size": os.path.getsize(dest), "ext": ext,
            "filename": fname, "path": usb_rel, "analyze_path": anlz_rel, "comment": tr.get("comment", ""),
        })
        assert tid == next_id
        copied[src] = tid
        existing_by_path[usb_rel] = tid
        log.append("Kopieret: " + usb_rel)
        return tid

    keymap = {}

    def resolve_parent(v):
        if isinstance(v, str):
            return keymap[v]
        return int(v or 0)

    for fo in plan.get("folders", []):
        keymap[fo["key"]] = db.add_playlist_node(fo["name"], resolve_parent(fo.get("parent")), True)
    for pl in plan.get("playlists", []):
        pid = db.add_playlist_node(pl["name"], resolve_parent(pl.get("parent")), False)
        keymap[pl["key"]] = pid
        for tr in pl.get("tracks", []):
            db.add_playlist_entry(pid, ensure_track(tr))
    for add in plan.get("add_to", []):
        pid = resolve_parent(add["playlist"])
        for tr in add.get("tracks", []):
            db.add_playlist_entry(pid, ensure_track(tr))
    db.bump_sequence()

    # 2) Tjek: den nye database skal kunne læses igen, og alt det gamle skal stadig være der
    check = Pdb(bytes(db.data))
    old = Pdb(original)
    for t in (T_TRACKS, T_ARTISTS, T_ALBUMS, T_KEYS, T_PLAYLIST_TREE, T_PLAYLIST_ENTRIES, T_ARTWORK, T_GENRES):
        before = old.all(t)
        after = check.all(t)
        if t == T_PLAYLIST_TREE:
            # Nye playlister lægges øverst, så søskende rykker én ned – rækkefølgen må ændre sig,
            # men alle mapper og playlister skal stadig være der med samme navn og placering.
            def strip(rows):
                return [{k: v for k, v in r.items() if k != "sort"} for r in rows]
            before, after = strip(before), strip(after)
        if len(after) < len(before) or any(b not in after for b in before):
            raise PdbError("Kontrol fejlede for tabel %d – intet er ændret på USB'en" % t)

    # 3) Skriv atomisk
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".modulr-")
    with os.fdopen(fd, "wb") as f:
        f.write(bytes(db.data))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
    return {"ok": True, "backup": backup, "log": log, "keys": keymap}


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "brug: read|write <usb-rod>"}))
        return 2
    cmd, root = sys.argv[1], sys.argv[2]
    try:
        if cmd == "read":
            res = read_usb(root)
        elif cmd == "write":
            res = write_usb(root, json.load(sys.stdin))
        else:
            res = {"ok": False, "error": "ukendt kommando"}
    except Exception as e:  # noqa
        res = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
