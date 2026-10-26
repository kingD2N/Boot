#!/usr/bin/env python3
"""ota_boot.py - Ambil satu partisi (default: boot) dari ROM OTA/recovery Xiaomi
(zip berisi payload.bin, atau payload.bin langsung) TANPA mengunduh seluruh ROM.

Zip & payload.bin dibaca lewat HTTP Range, jadi untuk ROM 5,4 GB hanya
~ukuran partisi (sekitar 100 MB) yang diunduh. Hasil diverifikasi dengan
SHA-256 dari manifest payload.

Pemakaian:
  ota_boot.py <url-atau-path-zip> <output.img> [--partition boot]

Kode keluar:
  0 sukses
  2 sumber tidak bisa diakses (HTTP error / file tidak ada)  -> coba mirror lain
  3 server tidak mendukung HTTP Range                       -> unduh penuh
  4 bukan zip OTA ber-payload / format tidak didukung        -> unduh penuh
  5 hash hasil tidak cocok
Hanya pakai pustaka standar Python (zstd opsional via modul 'zstandard').
"""
import argparse
import bz2
import hashlib
import io
import lzma
import os
import struct
import sys
import time
import urllib.error
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

UA = "Mozilla/5.0 (X11; Linux x86_64) ota_boot/1.0"


def log(msg):
    print(f"[ota_boot] {msg}", file=sys.stderr, flush=True)


class Fail(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


# ----------------------------------------------------------------- sumber data
class LocalSource:
    def __init__(self, path):
        if not os.path.isfile(path):
            raise Fail(2, f"file tidak ada: {path}")
        self.f = open(path, "rb")
        self.size = os.path.getsize(path)

    def read(self, off, n):
        self.f.seek(off)
        return self.f.read(n)


class HttpSource:
    def __init__(self, url):
        self.url = url
        data, total = self._get(0, 0, probe=True)
        self.size = total
        log(f"Ukuran remote: {total / 1048576:.1f} MiB (Range didukung)")

    def _get(self, off, end, probe=False):
        last = None
        for attempt in range(5):
            req = urllib.request.Request(
                self.url, headers={"Range": f"bytes={off}-{end}", "User-Agent": UA})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    if r.status != 206:
                        raise Fail(3, f"server membalas {r.status}, bukan 206 (Range tidak didukung)")
                    cr = r.headers.get("Content-Range", "")
                    total = int(cr.rsplit("/", 1)[1]) if "/" in cr else None
                    if probe:
                        if not total:
                            raise Fail(3, "Content-Range tanpa ukuran total")
                        r.read()
                        return b"", total
                    data = r.read()
                    if len(data) != end - off + 1:
                        raise IOError(f"data terpotong {len(data)}/{end - off + 1}")
                    return data, total
            except Fail:
                raise
            except urllib.error.HTTPError as e:
                if e.code in (403, 404, 410):
                    raise Fail(2, f"HTTP {e.code} untuk {self.url}")
                if e.code == 416:
                    raise Fail(3, "HTTP 416 (Range ditolak)")
                last = e
            except Exception as e:  # jaringan putus, timeout, dsb.
                last = e
            time.sleep(2 * (attempt + 1))
        raise Fail(2, f"gagal mengambil data: {last}")

    def read(self, off, n):
        if n <= 0:
            return b""
        return self._get(off, off + n - 1)[0]


class SourceFile(io.RawIOBase):
    """File-like (seekable) di atas sumber, dengan cache blok kecil untuk zipfile."""
    BLK = 256 * 1024

    def __init__(self, src):
        self.src, self.pos, self.cache = src, 0, {}

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        self.pos = {0: off, 1: self.pos + off, 2: self.src.size + off}[whence]
        return self.pos

    def _blk(self, i):
        if i not in self.cache:
            if len(self.cache) > 64:
                self.cache.clear()
            start = i * self.BLK
            self.cache[i] = self.src.read(start, min(self.BLK, self.src.size - start))
        return self.cache[i]

    def readinto(self, b):
        n = min(len(b), max(0, self.src.size - self.pos))
        out = bytearray()
        while len(out) < n:
            i, o = divmod(self.pos + len(out), self.BLK)
            out += self._blk(i)[o:o + n - len(out)]
        b[:n] = out
        self.pos += n
        return n


# ----------------------------------------------------------------- protobuf mini
def varint(buf, i):
    shift = val = 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7


def fields(buf):
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = varint(buf, i)
        elif wt == 1:
            v, i = buf[i:i + 8], i + 8
        elif wt == 2:
            ln, i = varint(buf, i)
            v, i = buf[i:i + ln], i + ln
        elif wt == 5:
            v, i = buf[i:i + 4], i + 4
        else:
            raise Fail(4, f"wire type protobuf tidak dikenal: {wt}")
        yield fn, v


# update_metadata.proto
OP_REPLACE, OP_REPLACE_BZ, OP_ZERO, OP_DISCARD, OP_REPLACE_XZ, OP_ZSTD = 0, 1, 6, 7, 8, 14
OP_NAMES = {0: "REPLACE", 1: "REPLACE_BZ", 6: "ZERO", 7: "DISCARD", 8: "REPLACE_XZ", 14: "ZSTD"}


def parse_manifest(buf):
    block_size, parts = 4096, []
    for fn, v in fields(buf):
        if fn == 3:
            block_size = v
        elif fn == 13:
            p = {"name": "", "size": None, "hash": None, "ops": []}
            for pf, pv in fields(v):
                if pf == 1:
                    p["name"] = pv.decode()
                elif pf == 7:  # new_partition_info
                    for qf, qv in fields(pv):
                        if qf == 1:
                            p["size"] = qv
                        elif qf == 2:
                            p["hash"] = bytes(qv)
                elif pf == 8:  # InstallOperation
                    op = {"type": 0, "off": 0, "len": 0, "dst": []}
                    for of, ov in fields(pv):
                        if of == 1:
                            op["type"] = ov
                        elif of == 2:
                            op["off"] = ov
                        elif of == 3:
                            op["len"] = ov
                        elif of == 6:
                            e = {1: 0, 2: 0}
                            for ef, ev in fields(ov):
                                e[ef] = ev
                            op["dst"].append((e[1], e[2]))
                    p["ops"].append(op)
            parts.append(p)
    return block_size, parts


def decompress(op, data):
    t = op["type"]
    if t == OP_REPLACE:
        return data
    if t == OP_REPLACE_BZ:
        return bz2.decompress(data)
    if t == OP_REPLACE_XZ:
        return lzma.decompress(data)
    if t == OP_ZSTD:
        try:
            import zstandard
        except ImportError:
            raise Fail(4, "operasi ZSTD butuh modul python 'zstandard' (pip install zstandard)")
        return zstandard.ZstdDecompressor().decompressobj().decompress(data)
    raise Fail(4, f"operasi payload {t} tidak didukung (bukan OTA full?)")


# ----------------------------------------------------------------- utama
def extract(source, out, partition):
    src = HttpSource(source) if source.startswith(("http://", "https://")) else LocalSource(source)
    magic = src.read(0, 4)
    if magic == b"CrAU":  # payload.bin mentah
        log("Sumber adalah payload.bin langsung")
        return extract_payload(src, 0, out, partition)
    if magic != b"PK\x03\x04":
        raise Fail(4, "sumber bukan file zip / payload.bin")
    f = SourceFile(src)
    try:
        z = zipfile.ZipFile(io.BufferedReader(f, buffer_size=65536))
    except zipfile.BadZipFile as e:
        raise Fail(4, f"zip rusak: {e}")
    names = z.namelist()

    # zip non-A/B / berisi image langsung
    direct = [n for n in names if n.rsplit("/", 1)[-1] == f"{partition}.img"]
    if direct:
        log(f"Zip berisi {direct[0]} langsung, mengekstrak...")
        with z.open(direct[0]) as r, open(out, "wb") as w:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                w.write(chunk)
        return

    if "payload.bin" not in names:
        raise Fail(4, "zip tidak berisi payload.bin maupun image partisi")
    info = z.getinfo("payload.bin")
    if info.compress_type != zipfile.ZIP_STORED:
        raise Fail(4, "payload.bin terkompresi di dalam zip (tidak bisa dibaca acak)")
    lh = src.read(info.header_offset, 30)
    if lh[:4] != b"PK\x03\x04":
        raise Fail(4, "local header payload.bin tidak valid")
    nlen, xlen = struct.unpack("<HH", lh[26:30])
    base = info.header_offset + 30 + nlen + xlen
    log(f"payload.bin: {info.file_size / 1048576:.1f} MiB @ offset {base}")
    extract_payload(src, base, out, partition)


def extract_payload(src, base, out, partition):
    hdr = src.read(base, 24)
    if hdr[:4] != b"CrAU":
        raise Fail(4, "magic payload bukan CrAU")
    ver, msize = struct.unpack(">QQ", hdr[4:20])
    sigsize = struct.unpack(">I", hdr[20:24])[0] if ver >= 2 else 0
    hlen = 24 if ver >= 2 else 20
    manifest = src.read(base + hlen, msize)
    data_base = base + hlen + msize + sigsize
    bs, parts = parse_manifest(manifest)
    log(f"Payload v{ver}, block {bs}, partisi: {', '.join(p['name'] for p in parts)}")

    part = next((p for p in parts if p["name"] == partition), None)
    if not part:
        raise Fail(4, f"partisi '{partition}' tidak ada di payload")
    types = {OP_NAMES.get(o["type"], str(o["type"])) for o in part["ops"]}
    total = sum(o["len"] for o in part["ops"])
    size = part["size"] or max(s + n for o in part["ops"] for s, n in o["dst"]) * bs
    log(f"Partisi {partition}: {size} byte, {len(part['ops'])} operasi ({', '.join(sorted(types))}), unduh {total / 1048576:.1f} MiB")

    def job(op):
        if op["type"] in (OP_ZERO, OP_DISCARD):
            return op, None
        return op, decompress(op, src.read(data_base + op["off"], op["len"]))

    tmp = out + ".part"
    with open(tmp, "wb") as w:
        w.truncate(size)
        with ThreadPoolExecutor(max_workers=8) as ex:
            for op, data in ex.map(job, part["ops"]):
                pos = 0
                for start, nblk in op["dst"]:
                    ln = nblk * bs
                    w.seek(start * bs)
                    if data is None:
                        w.write(b"\0" * ln)
                    else:
                        w.write(data[pos:pos + ln])
                        pos += ln
        w.truncate(size)

    if part["hash"]:
        h = hashlib.sha256()
        with open(tmp, "rb") as r:
            for chunk in iter(lambda: r.read(1 << 20), b""):
                h.update(chunk)
        if h.digest() != part["hash"]:
            os.unlink(tmp)
            raise Fail(5, "SHA-256 partisi hasil TIDAK cocok dengan manifest")
        log(f"SHA-256 cocok dengan manifest: {h.hexdigest()}")
    else:
        log("Manifest tidak menyimpan hash partisi, verifikasi dilewati")
    os.replace(tmp, out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("out")
    ap.add_argument("--partition", default="boot")
    a = ap.parse_args()
    try:
        extract(a.source, a.out, a.partition)
    except Fail as e:
        log(f"GAGAL: {e}")
        sys.exit(e.code)
    log(f"Selesai -> {a.out}")


if __name__ == "__main__":
    main()
