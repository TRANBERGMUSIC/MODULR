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
import math
import os
import shutil
import re
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

    def delete_rows(self, t, pred):
        """Markér rækker som slettede (som rekordbox gør): tilstedeværelses-bit ryddes og sidens tæller
        tælles ned. Rækkens bytes bliver liggende, men læses ikke længere. Returnerer antal slettede."""
        deleted = 0
        for p in self.table_pages(t):
            h = self.page_header(p)
            if not self.is_data_page(h):
                continue
            o = self.page_off(p)
            end = o + self.page_size
            n = h["num_rows"]
            gone = 0
            for g in range((n + 15) // 16):
                base = end - g * ROW_GROUP_SIZE
                present, tx = struct.unpack_from("<HH", self.data, base - 4)
                for r in range(16):
                    ri = g * 16 + r
                    if ri >= n or not (present >> r) & 1:
                        continue
                    pos = o + HEAP_START + struct.unpack_from("<H", self.data, base - 6 - 2 * r)[0]
                    row = self.read_track(pos) if t == T_TRACKS else self.read_named(pos, t)
                    if pred(row):
                        present &= ~(1 << r)
                        tx &= ~(1 << r)
                        gone += 1
                struct.pack_into("<HH", self.data, base - 4, present, tx)
            if gone:
                self.set_row_counts(p, n, max(0, h["num_valid"] - gone))
                self.data[o + 0x1B] |= 0x10                                    # "indeholder slettede rækker"
                struct.pack_into("<I", self.data, o + 0x10, self.sequence)
                deleted += gone
        return deleted

    def renumber_playlist(self, playlist_id, order=None):
        """Giv playlistens sange fortløbende numre 1, 2, 3 … (i `order` – en liste af track-id'er – hvis givet)."""
        rows = []
        for pos in self.rows(T_PLAYLIST_ENTRIES):
            e = self.read_named(pos, T_PLAYLIST_ENTRIES)
            if e["playlist_id"] == playlist_id:
                rows.append((e["index"], e["track_id"], pos))
        rows.sort()
        if order:
            rank = {tid: i for i, tid in enumerate(order)}
            rows.sort(key=lambda r: (rank.get(r[1], len(rank)), r[0]))
        for i, (_idx, _tid, pos) in enumerate(rows):
            struct.pack_into("<I", self.data, pos, i + 1)

    def set_analyze_path(self, track_id, new_path):
        """Ret sporets analyze_path på stedet (kun når den nye sti har samme længde – så intet andet flytter sig)."""
        for pos in self.rows(T_TRACKS):
            if self.read_track(pos)["id"] != track_id:
                continue
            o = struct.unpack_from("<H", self.data, pos + 0x5C + 2 + 2 * 14)[0]
            at = pos + o
            flags = self.data[at]
            old = decode_string(self.data, at)
            raw = new_path.encode("ascii")
            if not (flags & 1) or len(raw) != len(old):
                return False
            self.data[at + 1:at + 1 + len(raw)] = raw
            return True
        return False

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
    # rekordbox gemmer hele millisekunder rundet NED (55,873 ms → 55)
    beats = [struct.pack(">HHI", (n % 4) + 1, int(round(bpm * 100)), int(t))
             for n, t in enumerate(_beat_times(bpm, first_beat_ms, duration_s))]
    body = b"".join(beats)
    return _tag(b"PQTZ", struct.pack(">III", 0, 0x00080000, len(beats)), body)


def _pwav(cols):
    """Monokrom oversigt: 400 bytes (højde 0–31 i de 5 lave bits, hvidhed i de 3 høje)."""
    return _tag(b"PWAV", struct.pack(">II", 400, 0x00010000), bytes(cols))


def _pwv2(cols):
    return _tag(b"PWV2", struct.pack(">II", 100, 0x00010000), bytes(cols))


def _pvbr(total_samples=0):
    """Søgetabel: 401 felter. For CBR-MP3 skriver rekordbox nuller og sangens samlede antal samples til sidst."""
    return _tag(b"PVBR", struct.pack(">I", 0), b"\x00" * 1600 + struct.pack(">I", int(total_samples) & 0xFFFFFFFF))


# rekordbox' farvepalette til hot cues (color_code -> RGB), som CDJ'erne kender den.
HOTCUE_PALETTE = {
    0x01: (0x30, 0x5a, 0xff), 0x02: (0x50, 0x73, 0xff), 0x03: (0x50, 0x8c, 0xff), 0x04: (0x50, 0xa0, 0xff),
    0x05: (0x50, 0xb4, 0xff), 0x06: (0x50, 0xb0, 0xf2), 0x07: (0x50, 0xae, 0xe8), 0x08: (0x45, 0xac, 0xdb),
    0x09: (0x00, 0xe0, 0xff), 0x0a: (0x19, 0xda, 0xf0), 0x0b: (0x32, 0xd2, 0xe6), 0x0c: (0x21, 0xb4, 0xb9),
    0x0d: (0x20, 0xaa, 0xa0), 0x0e: (0x1f, 0xa3, 0x92), 0x0f: (0x19, 0xa0, 0x8c), 0x10: (0x14, 0xa5, 0x84),
    0x11: (0x14, 0xaa, 0x7d), 0x12: (0x10, 0xb1, 0x76), 0x13: (0x30, 0xd2, 0x6e), 0x14: (0x37, 0xde, 0x5a),
    0x15: (0x3c, 0xeb, 0x50), 0x16: (0x28, 0xe2, 0x14), 0x17: (0x7d, 0xc1, 0x3d), 0x18: (0x8c, 0xc8, 0x32),
    0x19: (0x9b, 0xd7, 0x23), 0x1a: (0xa5, 0xe1, 0x16), 0x1b: (0xa5, 0xdc, 0x0a), 0x1c: (0xaa, 0xd2, 0x08),
    0x1d: (0xb4, 0xc8, 0x05), 0x1e: (0xb4, 0xbe, 0x04), 0x1f: (0xba, 0xb4, 0x04), 0x20: (0xc3, 0xaf, 0x04),
    0x21: (0xe1, 0xaa, 0x00), 0x22: (0xff, 0xa0, 0x00), 0x23: (0xff, 0x96, 0x00), 0x24: (0xff, 0x8c, 0x00),
    0x25: (0xff, 0x75, 0x00), 0x26: (0xe0, 0x64, 0x1b), 0x27: (0xe0, 0x46, 0x1e), 0x28: (0xe0, 0x30, 0x1e),
    0x29: (0xe0, 0x28, 0x23), 0x2a: (0xe6, 0x28, 0x28), 0x2b: (0xff, 0x37, 0x6f), 0x2c: (0xff, 0x2d, 0x6f),
    0x2d: (0xff, 0x12, 0x7b), 0x2e: (0xf5, 0x1e, 0x8c), 0x2f: (0xeb, 0x2d, 0xa0), 0x30: (0xe6, 0x37, 0xb4),
    0x31: (0xde, 0x44, 0xcf), 0x32: (0xde, 0x44, 0x8d), 0x33: (0xe6, 0x30, 0xb4), 0x34: (0xe6, 0x19, 0xdc),
    0x35: (0xe6, 0x00, 0xff), 0x36: (0xdc, 0x00, 0xff), 0x37: (0xcc, 0x00, 0xff), 0x38: (0xb4, 0x32, 0xff),
    0x39: (0xb9, 0x3c, 0xff), 0x3a: (0xc5, 0x42, 0xff), 0x3b: (0xaa, 0x5a, 0xff), 0x3c: (0xaa, 0x72, 0xff),
    0x3d: (0x82, 0x72, 0xff), 0x3e: (0x64, 0x73, 0xff),
}


# rekordbox' standardfarver for hot cue A–H (aflæst fra 50 rekordbox-analyser)
REKORDBOX_HOTCUE_RGB = {1: (0xFF, 0x00, 0x17), 2: (0x00, 0xC4, 0xFF), 3: (0x33, 0xFF, 0x00), 4: (0x4D, 0x00, 0xFF),
                        5: (0x00, 0xFF, 0x30), 6: (0xFF, 0x5E, 0x00), 7: (0x00, 0x00, 0xFF), 8: (0xFF, 0xE8, 0x00)}


def nearest_hotcue_color(rgb):
    """Nærmeste farve i rekordbox' palette (så CDJ'ens pads lyser i samme farve som i MODULR)."""
    if not rgb:
        return 0, (0, 0, 0)
    r, g, b = rgb
    code = min(HOTCUE_PALETTE, key=lambda c: (HOTCUE_PALETTE[c][0] - r) ** 2 + (HOTCUE_PALETTE[c][1] - g) ** 2 + (HOTCUE_PALETTE[c][2] - b) ** 2)
    return code, HOTCUE_PALETTE[code]


def _cue_list(cues, hot):
    """cues: [(slot, ms)] – slot 0 = memory cue, 1–8 = hot cue A–H. Sorteret efter tid (memory) / slot (hot)."""
    # rekordbox skriver hot cues baglæns (H … A) og memory cues efter tid
    return sorted(cues, key=lambda c: -c[0]) if hot else sorted(cues, key=lambda c: c[1])


def _pcob(kind, cues=()):
    """Cue-liste i det gamle format: PCPT-poster á 0x38 bytes.
    rekordbox (og CDJ'en selv) lægger ALDRIG hot cue A–C her – kun D–H; A–C står kun i PCO2."""
    cues = _cue_list([c for c in cues if (c[0] > 0) == (kind == 1) and not (1 <= c[0] <= 3)], kind == 1)
    n = len(cues)
    body = b""
    for slot, ms, *_rest in cues:
        e = b"PCPT" + struct.pack(">II", 0x1C, 0x38)
        e += struct.pack(">IIIHH", slot, 0, 0x00010000, 0xFFFF, 0xFFFF)
        e += struct.pack(">B3sII", 1, b"\x00\x03\xe8", int(ms), 0xFFFFFFFF)
        e += b"\x00" * (0x38 - len(e))
        body += e
    return _tag(b"PCOB", struct.pack(">IHHi", kind, 0, n, -1), body)


def _pco2(kind, cues=()):
    """Udvidet cue-liste (nxs2/CDJ-3000): hot cues A–H med farve."""
    cues = _cue_list([c for c in cues if (c[0] > 0) == (kind == 1)], kind == 1)
    body = b""
    for c in cues:
        slot, ms = c[0], c[1]
        rgb = c[2] if len(c) > 2 else None
        e = b"PCP2" + struct.pack(">II", 0x10, 0x58)
        e += struct.pack(">IB3sII", slot, 1, b"\x00\x03\xe8", int(ms), 0xFFFFFFFF)
        e += struct.pack(">B7sHH", 0, b"\x01" + b"\x00" * 6, 0, 0)
        e += struct.pack(">I", 0)                      # ingen kommentar
        if slot > 0:
            # rekordbox skriver farvekode 0 og den præcise RGB (standardfarverne A–H)
            r, g, b = rgb if rgb else REKORDBOX_HOTCUE_RGB.get(slot, (0, 255, 0))
            e += struct.pack(">BBBB", 0, r, g, b)
        else:
            e += b"\x00\x00\x00\x00"
        e += b"\x00" * (0x58 - len(e))
        body += e
    return _tag(b"PCO2", struct.pack(">IHH", kind, len(cues), 0), body)


def _pwv3(cols):
    return _tag(b"PWV3", struct.pack(">III", 1, len(cols), 0x00960000), bytes(cols))


def _pwv4(cols6):
    return _tag(b"PWV4", struct.pack(">III", 6, len(cols6) // 6, 0), bytes(cols6))


def _pwv5(words):
    body = b"".join(struct.pack(">H", w) for w in words)
    return _tag(b"PWV5", struct.pack(">III", 2, len(words), 0x00960305), body)


PSSI_KEY = [0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2, 0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1]
# MODULRs sektioner → rekordbox' phrase-typer i mood "High" (elektronisk musik)
PHRASE_KIND = {"intro": 1, "main": 2, "buildup": 2, "breakdown": 3, "drop": 5, "outro": 6}


def _pssi(phrases, beat_count, end_hint=None):
    """Sangens opbygning til CDJ-3000 (PHRASE-visning, Lighting). Format som rekordbox 6/7 skriver det:
    u32 24 · u16 antal · [mood u16 · u32 0 · u16 0 · end_beat u16 · u16 0 · bank u8 · u8 0] · 24 bytes pr. phrase.
    Alt fra mood og frem er XOR-maskeret med en nøgle der afhænger af antallet (som rekordbox gør)."""
    rows = []
    last = 0
    for ph in sorted(phrases or [], key=lambda p: int(p.get("beat", 0))):
        beat = int(ph.get("beat", 0))
        kind = PHRASE_KIND.get(ph.get("kind"), 0)
        if kind == 0 or beat < 1 or (beat_count and beat > beat_count) or beat <= last:
            continue
        rows.append((beat, kind))
        last = beat
    if not rows:
        return None
    end_beat = int(end_hint) if end_hint else (int(beat_count) - 1 if beat_count else rows[-1][0])
    if beat_count:
        end_beat = min(end_beat, int(beat_count))
    n = len(rows)
    data = struct.pack(">HIHHHBB", 1, 0, 0, max(rows[-1][0], end_beat), 0, 0, 0)
    for i, (beat, kind) in enumerate(rows):
        data += struct.pack(">HHHBBBBBBHHHBBBBH", i + 1, beat, kind, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    key = [(k + n) % 256 for k in PSSI_KEY]
    masked = bytes(b ^ key[i % len(key)] for i, b in enumerate(data))
    # 14 bytes af den maskerede del hører til tag-headeren (len_header = 32), resten er phrases
    return _tag(b"PSSI", struct.pack(">IH", 24, n) + masked[:14], masked[14:])


def _beat_times(bpm, first_beat_ms, duration_s):
    """Slagenes præcise tider i ms – samme liste som PQTZ skrives fra."""
    out = []
    if bpm > 0:
        step = 60000.0 / bpm
        t = float(first_beat_ms)
        while t < duration_s * 1000.0:
            if t >= 0:
                out.append(t)
            t += step
    return out


def _pqtz_count(bpm, first_beat_ms, duration_s):
    return len(_beat_times(bpm, first_beat_ms, duration_s))


def _pwv6(cols3):
    return _tag(b"PWV6", struct.pack(">II", 3, len(cols3) // 3), bytes(cols3))


def _pwv7(cols3):
    return _tag(b"PWV7", struct.pack(">III", 3, len(cols3) // 3, 0x00960000), bytes(cols3))


def _pwvc(levels):
    return _tag(b"PWVC", struct.pack(">H", 0), struct.pack(">HHH", *levels))


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


def _ref(values, q=0.99):
    """Sangens reference-niveau (99 %-percentil), så waveformen fylder som i rekordbox."""
    v = sorted(values)
    return max(1, v[min(len(v) - 1, int(len(v) * q))]) if v else 1


# Kalibreret mod 50 rekordbox-analyser fra en rigtig USB (bas dominerer ~53 %, diskant ~32 %, mellem ~15 %).
# Vægtene gælder MODULRs gemte bånd (allerede normaliseret pr. bånd) og er de SAMME som i appen
# (Core/LibraryModel.swift: WaveColor.rekordboxWeights) – så MODULR, CDJ og rekordbox viser samme farver.
RB_WEIGHTS = (1.0, 1.5, 2.6)
# Oversigten (PWV4) måler rå styrke pr. bånd – ikke farveforhold – og rekordbox' har en svag diskant:
# rød dominerer ~56 %, grøn ~37 %, blå ~8 %; snit-styrke R:G:B ≈ 53:42:26 (målt på 49 rekordbox-analyser,
# farvebytes bekræftet mod foto af CDJ-3000). Samme vægte i appen: WaveColor.overviewWeights.
OV_WEIGHTS = (1.0, 1.5, 1.25)


def _weighted(lo, mi, hi):
    return (lo * RB_WEIGHTS[0], mi * RB_WEIGHTS[1], hi * RB_WEIGHTS[2])


def _rgb7(lo, mi, hi, refs=None):
    """RGB (0–7 pr. kanal) som rekordbox: rød = bas, grøn = mellem (vokal/synth), blå = diskant."""
    v = _weighted(lo, mi, hi)
    top = max(v)
    if top <= 0:
        return 7, 7, 7
    return tuple(int(round(7 * x / top)) for x in v)


def _smooth_cols(bands, n):
    """n kolonner: 60 % gennemsnit + 40 % top (bløde, læsbare toppe – som MODULRs egen waveform)."""
    total = len(bands)
    out = []
    for i in range(n):
        a = i * total // n
        b = max(a + 1, (i + 1) * total // n)
        chunk = bands[a:b] if a < total else [(0, 0, 0)]
        k = len(chunk)
        out.append(tuple(0.6 * sum(c[j] for c in chunk) / k + 0.4 * max(c[j] for c in chunk) for j in range(3)))
    return out


def waveforms_from_bands(bands):
    """bands: liste af (lav, mellem, høj) 0–255 med 150 kolonner pr. sekund – MODULRs analyse.
    Returnerer rekordbox' formater: PWAV, PWV2, PWV3, PWV4, PWV5 – skaleret som rekordbox' egne filer."""
    if not bands:
        bands = [(0, 0, 0)]
    ref = _ref([max(c) for c in bands], 0.995)
    refs = None
    detail = []
    color_detail = []
    for lo, mi, hi in bands:
        # højde skaleret så snittet rammer rekordbox' (≈10,3 af 31)
        h = min(31, int(round(max(lo, mi, hi) / ref * 36.3)))
        r, g, b = _rgb7(lo, mi, hi, refs)
        detail.append(h | (b << 5))                    # blå visning: højde + hvidhed (diskant)
        color_detail.append((r << 13) | (g << 10) | (b << 7) | (h << 2))
    prev = _smooth_cols(bands, 400)
    pref = _ref([max(c) for c in prev])
    pwav = []
    for lo, mi, hi in prev:
        h = min(25, int(round(max(lo, mi, hi) / pref * 24)))
        # "hvidhed" (diskant) – rekordbox' snit er ≈3,7 af 7
        pwav.append(h | (int(round(_rgb7(lo, mi, hi, refs)[2] * 0.59)) << 5))
    tiny = [min(15, int(round(max(c) / pref * 15.7))) for c in _smooth_cols(bands, 100)]
    cols = _smooth_cols(bands, 1200)
    def ov(c):
        return (c[0] * OV_WEIGHTS[0], c[1] * OV_WEIGHTS[1], c[2] * OV_WEIGHTS[2])
    cref = _ref([max(ov(c)) for c in cols])
    cprev = []
    for c in cols:
        sl, sm, sh = (min(127, int(round(x / cref * 120))) for x in ov(c))
        # byte 0–2 som rekordbox (Deep Symmetry: "hvidhed" og energi under ~10 kHz), fundet ved regression på
        # 49 rekordbox-analyser: byte0 ≈ 9,75·√(sum) − 6,9 (R² 0,78) · byte0 + byte1 ≈ 256 (median præcis 256)
        # · byte2 ≈ 0,82·lav + 0,46·mellem + 0,21·høj (R² 0,89). Digital stilhed = seks nuller.
        total = sl + sm + sh
        if total == 0:
            cprev += [0, 0, 0, 0, 0, 0]
            continue
        b0 = max(0, min(127, int(round(9.75 * math.sqrt(total) - 6.9))))
        b1 = max(0, min(255, 256 - b0))
        b2 = max(0, min(127, int(round(0.82 * sl + 0.46 * sm + 0.21 * sh))))
        cprev += [b0, b1, b2, sl, sm, sh]
    return pwav, tiny, detail, cprev, color_detail


def three_band(bands):
    """CDJ-3000's 3-bånds-waveform (.2EX): pr. kolonne (mellem, høj, lav).
    Detalje: 150 kolonner/s (op til ca. 120). Oversigt: 1200 kolonner (op til ca. 45) – som rekordbox."""
    if not bands:
        bands = [(0, 0, 0)]
    refs = [_ref([c[k] for c in bands], 0.995) for k in range(3)]
    detail = []
    for lo, mi, hi in bands:
        # rekordbox' 3-bånds-detalje: snit mellem ≈38, høj ≈34, lav ≈17 (bassen tegnes svagere)
        detail += [min(127, int(mi / refs[1] * 177)), min(127, int(hi / refs[2] * 175)), min(127, int(lo / refs[0] * 70))]
    cols = _smooth_cols(bands, 1200)
    prefs = [_ref([c[k] for c in cols]) for k in range(3)]
    prev = []
    for lo, mi, hi in cols:
        prev += [min(63, int(mi / prefs[1] * 43)), min(63, int(hi / prefs[2] * 42.5)), min(63, int(lo / prefs[0] * 48))]
    return prev, detail



MODULR_MARK = ".modulr"
# Tælles op hver gang MODULRs analysefiler ændrer udseende/indhold (så appen kan se forældede sange på stikket).
# 3 = rekordbox-farver (RB_WEIGHTS), hot cues A–C kun i PCO2, phrases. 4 = oversigt med egne vægte (OV_WEIGHTS). 5 = oversigtens byte 0–2 som rekordbox. 6 = højder/hvidhed/3-bånd kalibreret mod rekordbox.
ANLZ_FORMAT = 6


def anlz_folder_number(analyze_path):
    m = re.match(r"^/PIONEER/USBANLZ/P([0-9A-F]{3})/([0-9A-F]{8})/", analyze_path or "")
    return (int(m.group(1), 16), int(m.group(2), 16)) if m else None


def is_modulr_anlz(analyze_path, folder):
    """Er analysefilerne lavet af MODULR? (Mærkefil – eller ældre MODULR: mappe P800+ uden .2EX.)"""
    if not folder or not os.path.isdir(folder):
        return False
    if os.path.exists(os.path.join(folder, MODULR_MARK)):
        return True
    n = anlz_folder_number(analyze_path)
    return bool(n and n[0] >= 0x800 and not os.path.exists(os.path.join(folder, "ANLZ0000.2EX")))


def may_write_anlz(root, analyze_path, usb_rel):
    """MODULR må skrive sangens analyse, medmindre rekordbox' egen analyse ligger der (i databasens mappe
    eller i den mappe CDJ'en kigger i). MODULR-mapper har et mærke; mangler analysen helt, må vi også."""
    for rel in {analyze_path or "", anlz_hash_path(usb_rel)}:
        if not rel:
            continue
        folder = os.path.join(root, os.path.dirname(rel).lstrip("/"))
        has_files = any(os.path.exists(os.path.join(folder, "ANLZ0000." + e)) for e in ("DAT", "EXT", "2EX"))
        if has_files and not is_modulr_anlz(rel, folder):
            return False
    return True


def anlz_hash_path(usb_rel):
    """Den sti CDJ'en SELV regner ud fra lydfilens sti – spilleren ignorerer analyze_path i databasen.
    rekordbox' CreateAnlzFileFolderPath (fundet af rhythmbox-to-pioneer-xdj-exporter, PIONEER.md):
    rullende hash over UTF-16-tegn, modulo 200003, P-mappen er 7 spredte bits af resultatet.
    Kontrolleret mod alle 138 sange på en rigtig rekordbox-USB (alle passer)."""
    h = 0
    for cu in struct.unpack("<%dH" % (len(usb_rel.encode("utf-16-le")) // 2), usb_rel.encode("utf-16-le")):
        t = (h * 0x5BC9 + cu) & 0xFFFFFFFF
        h = (t * 0x93B5 + cu) & 0xFFFFFFFF
    r = h % 200003
    p = ((r >> 0) & 1) | ((r >> 1) & 2) | ((r >> 4) & 4) | ((r >> 4) & 8) | ((r >> 5) & 0x10) | ((r >> 8) & 0x20) | ((r >> 10) & 0x40)
    return "/PIONEER/USBANLZ/P%03X/%08X/ANLZ0000.DAT" % (p, r)


def new_anlz_path(root, usb_rel, taken):
    """Analysemappen SKAL ligge hvor CDJ'en forventer den (anlz_hash_path) – ellers ingen waveform/grid/cues.
    Hvis en ANDEN sang allerede har den mappe (sjældent: hash-kollision), skrives der ikke oven i den."""
    rel = anlz_hash_path(usb_rel)
    owner = taken.setdefault("owner", {}).get(rel)
    if owner not in (None, usb_rel):
        taken.setdefault("collisions", set()).add(usb_rel)
        return rel
    taken.setdefault("paths", set()).add(rel)
    taken["owner"][rel] = usb_rel
    return rel


def misplaced_anlz(root, db):
    """MODULR-sange hvis analyse ikke ligger hvor CDJ'en kigger: [(track, gammel mappe, ny analyze_path)]."""
    out = []
    for t in db.all(T_TRACKS):
        ap = t.get("analyze_path") or ""
        if not ap or not t.get("path"):
            continue
        folder = os.path.join(root, os.path.dirname(ap).lstrip("/"))
        want = anlz_hash_path(t["path"])
        if ap != want and is_modulr_anlz(ap, folder):
            out.append((t, folder, want))
    return out


def anlz_collides(taken, usb_rel):
    return usb_rel in taken.get("collisions", set())


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
    p6, p7 = three_band(bands)
    # Cues: [(slot, ms, rgb)] – slot 0 = memory cue, 1–8 = hot cue A–H
    cues = []
    for h in analysis.get("hot_cues") or []:
        slot = int(h.get("slot") or 0)
        if 1 <= slot <= 8:
            rgb = tuple(int(x) for x in h.get("rgb")) if h.get("rgb") else None
            cues.append((slot, max(0, int(round(float(h.get("ms") or 0)))), rgb))
    seen_ms = set()
    for m in analysis.get("memory_cues") or []:
        ms = max(0, int(round(float(m))))
        if ms not in seen_ms:
            seen_ms.add(ms)
            cues.append((0, ms, None))
    samples = 0
    if usb_path.lower().endswith(".mp3"):
        samples = int(round(dur * float(analysis.get("sample_rate") or 44100)))
    dat = _anlz_file([_ppth(usb_path), _pvbr(samples), _pqtz(bpm, first, dur), _pwav(pwav), _pwv2(tiny),
                      _pcob(1, cues), _pcob(0, cues)])
    sections = [_ppth(usb_path), _pwv3(detail), _pcob(1, cues), _pcob(0, cues), _pco2(1, cues), _pco2(0, cues),
                _pwv5(cdet), _pwv4(cprev)]
    pssi = _pssi(analysis.get("phrases"), _pqtz_count(bpm, first, dur), analysis.get("phrase_end_beat"))
    if pssi:
        sections.append(pssi)                      # rekordbox lægger PSSI sidst i .EXT
    ext = _anlz_file(sections)
    ex2 = _anlz_file([_ppth(usb_path), _pwv7(p7), _pwv6(p6), _pwvc((0x5B, 0x8A, 0x18C))])
    for name, data in (("ANLZ0000.DAT", dat), ("ANLZ0000.EXT", ext), ("ANLZ0000.2EX", ex2), (MODULR_MARK, ("MODULR\nformat=%d\n" % ANLZ_FORMAT).encode())):
        with open(os.path.join(folder, name), "wb") as f:
            f.write(data)


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
    return {"ok": True, "tracks": tracks, "nodes": nodes, "onelibrary": has_onelibrary,
            "misplaced": len(misplaced_anlz(root, db))}


def safe_name(s, fallback):
    s = "".join(c for c in (s or "") if c not in '/\\:*?"<>|\x00').strip().strip(".")
    return (s or fallback)[:80]


MAX_BACKUPS = 5


def _backup(root):
    """Backup af hele rekordbox-mappen – de 5 nyeste gemmes, ældre ryddes op."""
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    base = os.path.join(root, "PIONEER")
    backup = os.path.join(base, "MODULR-backup-" + stamp)
    if os.path.exists(backup):
        backup += "-%d" % os.getpid()
    shutil.copytree(os.path.join(base, "rekordbox"), backup)
    old = sorted(d for d in os.listdir(base) if d.startswith("MODULR-backup-"))
    for d in old[:-MAX_BACKUPS]:
        shutil.rmtree(os.path.join(base, d), ignore_errors=True)
    return backup


def _save_atomic(p, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".modulr-")
    with os.fdopen(fd, "wb") as f:
        f.write(bytes(data))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)


def edit_usb(root, plan):
    """Ændringer i det der allerede ligger på USB'en – udføres med det samme (med backup og kontrol).
    plan = {
      "remove":   [{"playlist": id, "tracks": [track-id, …]}],   # fjern fra playliste (sangen bliver på USB'en)
      "add":      [{"playlist": id, "tracks": [track-id, …]}],   # sæt eksisterende USB-sange i en playliste
      "order":    [{"playlist": id, "tracks": [track-id, …]}],   # ny rækkefølge
      "delete":   [track-id, …]                                   # slet sangen helt fra USB'en
    }"""
    p = pdb_path(root)
    with open(p, "rb") as f:
        original = f.read()
    db = Pdb(original)
    old = Pdb(original)
    tracks = {t["id"]: t for t in db.all(T_TRACKS)}
    playlists = {n["id"] for n in db.all(T_PLAYLIST_TREE) if not n.get("folder")}
    log = []
    touched = set()

    removed_pairs = set()                 # (playlist, track)
    for op in plan.get("remove", []):
        pid = int(op["playlist"])
        ids = {int(x) for x in op.get("tracks", [])}
        n = db.delete_rows(T_PLAYLIST_ENTRIES, lambda e: e["playlist_id"] == pid and e["track_id"] in ids)
        removed_pairs |= {(pid, t) for t in ids}
        touched.add(pid)
        log.append("Fjernet %d fra playliste %d" % (n, pid))

    delete = {int(x) for x in plan.get("delete", []) if int(x) in tracks}
    files_to_remove = []
    if delete:
        pls = {e["playlist_id"] for e in db.all(T_PLAYLIST_ENTRIES) if e["track_id"] in delete}
        db.delete_rows(T_PLAYLIST_ENTRIES, lambda e: e["track_id"] in delete)
        touched |= pls
        db.delete_rows(T_TRACKS, lambda t: t["id"] in delete)
        for tid in delete:
            t = tracks[tid]
            if t.get("path"):
                files_to_remove.append(os.path.join(root, t["path"].lstrip("/")))
            ap = t.get("analyze_path") or ""
            if ap.startswith("/PIONEER/USBANLZ/"):
                files_to_remove.append(os.path.join(root, os.path.dirname(ap).lstrip("/")))
            log.append("Slettet: " + (t.get("title") or t.get("path", "")))

    for op in plan.get("add", []):
        pid = int(op["playlist"])
        if pid not in playlists:
            raise PdbError("Playlisten findes ikke på USB'en")
        for tid in op.get("tracks", []):
            tid = int(tid)
            if tid in tracks and tid not in delete:
                db.add_playlist_entry(pid, tid)
        touched.add(pid)

    moved = set()
    move_files = []          # (gammel mappe, ny mappe)
    if plan.get("repair"):
        owners = {t.get("analyze_path"): t["path"] for t in db.all(T_TRACKS)}
        for t, old_folder, want in misplaced_anlz(root, db):
            if t["id"] in delete:
                continue
            new_folder = os.path.join(root, os.path.dirname(want).lstrip("/"))
            if owners.get(want) not in (None, t["path"]) or (os.path.exists(new_folder) and not is_modulr_anlz(want, new_folder)):
                log.append("⚠︎ Kan ikke flytte (mappen bruges af en anden sang): " + t["title"])
                continue
            if db.set_analyze_path(t["id"], want):
                moved.add(t["id"])
                move_files.append((old_folder, new_folder))
                log.append("Waveform-filer flyttet derhen hvor CDJ'en kigger: " + t["title"])

    for pid in touched:
        db.renumber_playlist(pid)
    for op in plan.get("order", []):
        db.renumber_playlist(int(op["playlist"]), [int(x) for x in op.get("tracks", [])])
        touched.add(int(op["playlist"]))
    db.bump_sequence()

    # Kontrol: kun det vi bad om må være forsvundet – alt andet skal stå uændret
    check = Pdb(bytes(db.data))
    def strip_moved(rows):
        return [{k: v for k, v in r.items() if not (k == "analyze_path" and r["id"] in moved)} for r in rows]
    for t in (T_TRACKS, T_ARTISTS, T_ALBUMS, T_KEYS, T_PLAYLIST_TREE, T_ARTWORK, T_GENRES):
        before = [r for r in old.all(t) if not (t == T_TRACKS and r["id"] in delete)]
        after = check.all(t)
        if t == T_TRACKS and moved:
            before, after = strip_moved(before), strip_moved(after)
        if any(b not in after for b in before):
            raise PdbError("Kontrol fejlede for tabel %d – intet er ændret på USB'en" % t)
    def key(e):
        return (e["playlist_id"], e["track_id"])
    before = {key(e) for e in old.all(T_PLAYLIST_ENTRIES)
              if e["track_id"] not in delete and key(e) not in removed_pairs}
    after = {key(e) for e in check.all(T_PLAYLIST_ENTRIES)}
    if not before <= after:
        raise PdbError("Kontrol fejlede for playlisterne – intet er ændret på USB'en")
    if any(t in delete for _pl, t in after):
        raise PdbError("Kontrol fejlede: en slettet sang står stadig i en playliste – intet er ændret")

    # Analysefilerne kopieres på plads FØR databasen gemmes (så de findes, når CDJ'en kigger)
    for src, dst in move_files:
        os.makedirs(dst, exist_ok=True)
        for name in os.listdir(src):
            shutil.copy2(os.path.join(src, name), os.path.join(dst, name))
    backup = _backup(root)
    _save_atomic(p, db.data)
    for src, _dst in move_files:
        shutil.rmtree(src, ignore_errors=True)
    # Filerne slettes først, når databasen er gemt
    for f in files_to_remove:
        try:
            if os.path.isdir(f):
                shutil.rmtree(f)
            elif os.path.exists(f):
                os.remove(f)
        except OSError:
            pass
    return {"ok": True, "backup": backup, "log": log}


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
    backup = _backup(root)

    copied = {}            # kilde-sti -> track-id
    existing_by_path = {t["path"]: t["id"] for t in db.all(T_TRACKS)}
    anlz_by_path = {t["path"]: t.get("analyze_path", "") for t in db.all(T_TRACKS)}
    taken_anlz = {"paths": set(anlz_by_path.values()), "owner": {v: k for k, v in anlz_by_path.items()}}
    moved_anlz = set()      # spor hvis analysemappe er flyttet ind i rekordbox' område
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
            # Sangen ligger der allerede: lagt på af MODULR → opdatér waveform, grid og cues.
            # (rekordbox' egne analysefiler røres aldrig.)
            ap = anlz_by_path.get(usb_rel, "")
            folder = os.path.join(root, os.path.dirname(ap).lstrip("/")) if ap else ""
            if may_write_anlz(root, ap, usb_rel) and tr.get("analysis"):
                tr["analysis"].setdefault("sample_rate", tr.get("sample_rate") or 44100)
                if ap != anlz_hash_path(usb_rel):
                    # Lagt på af en ældre MODULR i en mappe CDJ'en ikke kigger i → flyt derhen hvor den kigger
                    rel = new_anlz_path(root, usb_rel, taken_anlz)
                    if anlz_collides(taken_anlz, usb_rel):
                        log.append("⚠︎ Analysemappen deles med en anden sang – waveform springes over: " + usb_rel)
                        return copied[src]
                    if db.set_analyze_path(copied[src], rel):
                        moved_anlz.add(copied[src])
                        ap = rel
                        folder = os.path.join(root, os.path.dirname(rel).lstrip("/"))
                write_anlz(folder, usb_rel, tr["analysis"])
                log.append("Opdateret waveform, grid og cues: " + usb_rel)
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
        anlz_rel = new_anlz_path(root, usb_rel, taken_anlz)
        an = dict(tr.get("analysis") or {"bpm": tr.get("bpm"), "duration": tr.get("duration")})
        an.setdefault("sample_rate", tr.get("sample_rate") or 44100)
        if anlz_collides(taken_anlz, usb_rel):
            log.append("⚠︎ Analysemappen deles med en anden sang – waveform springes over: " + usb_rel)
        else:
            write_anlz(os.path.join(root, os.path.dirname(anlz_rel).lstrip("/")), usb_rel, an)
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

    # Ret MODULR-sange fra ældre versioner, hvis analyse ligger forkert (uden at du skal sende dem igen)
    for t, old_folder, want in misplaced_anlz(root, db):
        new_folder = os.path.join(root, os.path.dirname(want).lstrip("/"))
        if taken_anlz["owner"].get(want) not in (None, t["path"]) or os.path.exists(new_folder):
            continue
        os.makedirs(new_folder, exist_ok=True)
        for name in os.listdir(old_folder):
            shutil.copy2(os.path.join(old_folder, name), os.path.join(new_folder, name))
        if db.set_analyze_path(t["id"], want):
            moved_anlz.add(t["id"])
            taken_anlz["owner"][want] = t["path"]
            anlz_by_path[t["path"]] = want
            log.append("Waveform-filer flyttet derhen hvor CDJ'en kigger: " + t["title"])

    for fo in plan.get("folders", []):
        keymap[fo["key"]] = db.add_playlist_node(fo["name"], resolve_parent(fo.get("parent")), True)
    for pl in plan.get("playlists", []):
        pid = db.add_playlist_node(pl["name"], resolve_parent(pl.get("parent")), False)
        keymap[pl["key"]] = pid
        for tr in pl.get("tracks", []):
            db.add_playlist_entry(pid, ensure_track(tr))
    # Opdatér analysen på sange der allerede ligger på stikket – ramt via track-id, aldrig en ny kopi
    rows = {t["id"]: t for t in db.all(T_TRACKS)}
    for item in plan.get("refresh", []):
        row = rows.get(int(item.get("usb_track_id", 0)))
        an = (item.get("track") or {}).get("analysis")
        if not row or not an:
            continue
        usb_rel = row["path"]
        ap = row.get("analyze_path") or ""
        if not may_write_anlz(root, ap, usb_rel):
            log.append("Sprunget over (rekordbox' egen analyse): " + row["title"])
            continue
        an.setdefault("sample_rate", row.get("sample_rate") or 44100)
        want = anlz_hash_path(usb_rel)
        if ap != want:
            if taken_anlz["owner"].get(want) not in (None, usb_rel):
                log.append("⚠︎ Analysemappen deles med en anden sang – springes over: " + row["title"])
                continue
            if db.set_analyze_path(row["id"], want):
                moved_anlz.add(row["id"])
                taken_anlz["owner"][want] = usb_rel
        write_anlz(os.path.join(root, os.path.dirname(want).lstrip("/")), usb_rel, an)
        log.append("Opdateret waveform, grid og cues: " + row["title"])
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
        if t == T_TRACKS and moved_anlz:
            # Kun analysestien må ændre sig – og kun på de spor vi har flyttet
            def strip_moved(rows):
                return [{k: v for k, v in r.items() if not (k == "analyze_path" and r["id"] in moved_anlz)} for r in rows]
            before, after = strip_moved(before), strip_moved(after)
        if len(after) < len(before) or any(b not in after for b in before):
            raise PdbError("Kontrol fejlede for tabel %d – intet er ændret på USB'en" % t)

    # 3) Skriv atomisk
    _save_atomic(p, db.data)
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
        elif cmd == "edit":
            res = edit_usb(root, json.load(sys.stdin))
        else:
            res = {"ok": False, "error": "ukendt kommando"}
    except Exception as e:  # noqa
        res = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
