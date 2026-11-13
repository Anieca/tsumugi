#!/usr/bin/env python3
"""Mozc OSS 辞書テキストを Tsumugi のバイナリ辞書 (system.dict) にコンパイルする。

usage: build_dict.py <mozc_dictionary_oss_dir> <out_file>

レイアウト (リトルエンディアン):
  header   u32 x 16 : magic 'TSMG', version, numReadings, numEntries,
                      readingBlobSize, surfaceBlobSize, connDim, unknownId, 予約...
  readingOffsets u32 x (R+1)   読み blob へのオフセット (UTF-8 バイト順ソート済み)
  entryStart     u32 x (R+1)   読みごとのエントリ範囲
  entries        12B x E       u16 lid, u16 rid, i16 cost, u16 surfaceLen, u32 surfaceOff
  posFlags       u8 x dim (4B 境界までパディング)  bit0=付属語 bit1=接頭辞
  conn           i16 x dim*dim (4B 境界までパディング)  conn[rid*dim + lid]
  readingBlob, surfaceBlob
"""
import array
import glob
import os
import struct
import sys


def pad4(b: bytes) -> bytes:
    return b + b"\0" * ((4 - len(b) % 4) % 4)


def main():
    src, out = sys.argv[1], sys.argv[2]

    # --- 品詞 ID ---
    pos = {}
    with open(os.path.join(src, "id.def"), encoding="utf-8") as f:
        for line in f:
            i, name = line.rstrip("\n").split(" ", 1)
            pos[int(i)] = name
    unknown_id = next(i for i, n in pos.items() if n.startswith("名詞,一般,*,*,*,*,*"))

    def flags(name: str) -> int:
        p = name.split(",")
        fl = 0
        functional = (
            p[0] in ("助詞", "助動詞", "記号")
            or (len(p) > 1 and p[1] in ("接尾", "非自立"))
        )
        if functional:
            fl |= 1
        if p[0] == "接頭詞":
            fl |= 2
        return fl

    # --- 接続コスト ---
    with open(os.path.join(src, "connection_single_column.txt")) as f:
        dim = int(f.readline())
        conn = array.array("h", (int(x) if int(x) < 32767 else 32767 for x in f))
    assert len(conn) == dim * dim, (len(conn), dim)
    pos_flags = bytes(flags(pos.get(i, "")) for i in range(dim))

    # --- 単語 ---
    by_reading = {}
    n = 0
    for path in sorted(glob.glob(os.path.join(src, "dictionary0*.txt"))):
        with open(path, encoding="utf-8") as f:
            for line in f:
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 5:
                    continue
                reading, lid, rid, cost, surface = cols[0], int(cols[1]), int(cols[2]), int(cols[3]), cols[4]
                by_reading.setdefault(reading.encode("utf-8"), []).append((min(cost, 32767), lid, rid, surface))
                n += 1

    readings = sorted(by_reading)
    reading_blob = bytearray()
    reading_offsets = array.array("I")
    entry_start = array.array("I")
    entries = bytearray()
    surface_blob = bytearray()
    surface_index = {}
    count = 0
    for r in readings:
        reading_offsets.append(len(reading_blob))
        reading_blob += r
        entry_start.append(count)
        for cost, lid, rid, surface in sorted(by_reading[r]):
            off = surface_index.get(surface)
            sb = surface.encode("utf-8")
            if off is None:
                off = len(surface_blob)
                surface_index[surface] = off
                surface_blob += sb
            entries += struct.pack("<HHhHI", lid, rid, cost, len(sb), off)
            count += 1
    reading_offsets.append(len(reading_blob))
    entry_start.append(count)

    header = struct.pack(
        "<16I", 0x474D5354, 1, len(readings), count, len(reading_blob), len(surface_blob), dim, unknown_id,
        0, 0, 0, 0, 0, 0, 0, 0,
    )
    with open(out, "wb") as f:
        f.write(header)
        f.write(reading_offsets.tobytes())
        f.write(entry_start.tobytes())
        f.write(bytes(entries))
        f.write(pad4(pos_flags))
        f.write(pad4(conn.tobytes()))
        f.write(bytes(reading_blob))
        f.write(bytes(surface_blob))
    print(f"readings={len(readings)} entries={count} dim={dim} unknownId={unknown_id} size={os.path.getsize(out)/1e6:.1f}MB")


if __name__ == "__main__":
    main()
