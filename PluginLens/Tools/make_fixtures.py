#!/usr/bin/env python3 -I
"""Builds privacy-safe ProjectData fixtures from real .logicx projects.

Only the 40 bytes of each validated plugin record (flags, 12-byte name, manufacturer, type,
subtype, 16 flag/size bytes) are kept, plus the 4-byte magic. Everything else in the original
(track names, text, plugin state blobs, automation) is dropped, and gaps are zero filled.
No audio is involved: ProjectData never contains audio, it lives in Media/.

usage: make_fixtures.py <out_dir> <name>=<path/to/X.logicx>[@ghost] ...

'@ghost' rewrites the manufacturer code of the first AU record to 'Zzzz' so the fixture contains a plugin
that is not installed on any machine (every sample plugin on the author's machine is installed).
"""
import glob, os, re, sys

AU = {b'xfua', b'umua', b'fmua', b'imua'}

def printable(b): return all(0x20 <= c <= 0x7e for c in b)

def records(d):
    out = []
    for m in re.finditer(rb'xfua|umua|fmua|imua|GAME', d):
        i, t = m.start(), m.group()
        if t == b'GAME':
            ns, ok = i - 12, True
        else:
            ns = i - 16
            ok = i >= 4 and printable(d[i-4:i]) and printable(d[i+4:i+8])
        if ns < 2 or not ok or d[ns-2] not in (1, 2) or d[ns-1] not in (1, 2):
            continue
        f = d[ns:ns+12]
        if 0 not in f: continue
        nul = f.index(0)
        txt = f[:nul]
        if nul > 0 and printable(txt) and chr(txt[0]).isalnum() and not any(f[nul:]):
            out.append((ns, d[ns-2:ns+40]))
    return out

def build(d, max_records=40, ghost=False):
    recs = records(d)
    seen, keep = set(), []
    for ns, blob in recs:
        key = blob[2:2+30]
        if ghost and blob[14:18] != b'GAME' and not any(k[0] == 'g' for k in seen):
            seen.add('g' + blob[2:14].hex()); blob = blob[:14] + b'zzzZ' + blob[18:]
        keep.append(blob)  # keep duplicates: the parser must de-duplicate
        if len(keep) >= max_records: break
    out = bytearray(b'\x23\x47\xc0\xab' + b'\x00' * 60)  # header, zero padded to 64
    for blob in keep:
        out += b'\x00' * 24 + blob
    out += b'\x00' * 64
    return bytes(out)

def main():
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    for spec in sys.argv[2:]:
        name, path = spec.split('=', 1)
        ghost = path.endswith('@ghost')
        path = path.removesuffix('@ghost')
        pds = glob.glob(os.path.join(path, 'Alternatives', '*', 'ProjectData'))
        d = open(pds[0], 'rb').read()
        fx = build(d, ghost=ghost)
        open(os.path.join(out_dir, name + '.projectdata'), 'wb').write(fx)
        print(name, len(fx), 'bytes,', len(records(d)), 'records in source')

if __name__ == '__main__':
    main()
