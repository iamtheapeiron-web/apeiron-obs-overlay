"""Validate the produced PE and the exact runtime bytes it embeds."""
import argparse
import hashlib
import struct
from pathlib import Path
import xml.etree.ElementTree as ET

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("exe", type=Path)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("--extract", type=Path)
    args = parser.parse_args()
    b = args.exe.read_bytes()
    pe = struct.unpack_from("<I", b, 0x3c)[0]
    assert b[:2] == b"MZ" and b[pe:pe+4] == b"PE\0\0"
    machine, count = struct.unpack_from("<HH", b, pe+4)
    assert machine == 0x8664
    optional_size = struct.unpack_from("<H", b, pe+20)[0]
    optional = pe+24
    assert struct.unpack_from("<H", b, optional)[0] == 0x20b
    assert struct.unpack_from("<H", b, optional+68)[0] == 2, "GUI subsystem"
    flags = struct.unpack_from("<H", b, optional+70)[0]
    assert flags & 0x100 and flags & 0x40, "NX and ASLR"
    sections = []
    for i in range(count):
        offset = optional+optional_size+i*40
        vsize, rva, rawsize, raw = struct.unpack_from("<IIII", b, offset+8)
        sections.append((rva, max(vsize,rawsize), raw))
    def file_offset(rva):
        for start, size, raw in sections:
            if start <= rva < start+size:
                return raw+rva-start
        raise AssertionError(f"RVA outside sections: {rva:x}")
    resource_rva, resource_size = struct.unpack_from("<II", b, optional+112+2*8)
    assert resource_rva and resource_size
    root = file_offset(resource_rva)
    resources = {}
    def walk(relative, path=()):
        named, ids = struct.unpack_from("<HH", b, root+relative+12)
        for i in range(named+ids):
            name, item = struct.unpack_from("<II", b, root+relative+16+i*8)
            key = name
            if name & 0x80000000:
                position = root+(name & 0x7fffffff)
                length = struct.unpack_from("<H", b, position)[0]
                key = b[position+2:position+2+length*2].decode("utf-16le")
            if item & 0x80000000:
                walk(item & 0x7fffffff, path+(key,))
            else:
                rva, size = struct.unpack_from("<II", b, root+item)
                offset = file_offset(rva)
                resources[path+(key,)] = b[offset:offset+size]
    walk(0)
    types = {key[0] for key in resources}
    assert {3, 14, 16, 24} <= types, "Icons, group icon, version and manifest"
    icons = [value for key, value in resources.items() if key[0] == 3]
    assert len(icons) == 7
    group = next(value for key,value in resources.items() if key[0] == 14)
    assert struct.unpack_from("<HHH", group) == (0,1,7)
    version = next(value for key,value in resources.items() if key[0] == 16)
    for value in ("APEIRON OBS Overlay", "0.2.0-beta.1", "0.2.0.4 (beta1)"):
        assert value.encode("utf-16le") in version, f"Missing version field {value}"
    fixed = version.find(struct.pack("<I",0xfeef04bd))
    assert fixed >= 0 and struct.unpack_from("<IIII",version,fixed+8) == (2,4,2,4)
    manifest = next(value for key,value in resources.items() if key[0] == 24)
    tree = ET.fromstring(manifest)
    requested = next(element for element in tree.iter() if element.tag.endswith("requestedExecutionLevel"))
    assert requested.attrib == {"level":"asInvoker","uiAccess":"false"}
    for name in ("overlay.ps1","APEIRON.ico","APEIRON_icon.png"):
        data = (args.runtime/name).read_bytes()
        offset = b.find(data)
        assert offset >= 0, f"Different embedded runtime: {name}"
        extracted = b[offset:offset+len(data)]
        assert hashlib.sha256(data).digest() == hashlib.sha256(extracted).digest()
        if args.extract:
            args.extract.mkdir(parents=True,exist_ok=True)
            (args.extract/name).write_bytes(extracted)
    print("PASS: Windows x64 GUI PE; NX/ASLR; 7 embedded icons; icon group; version 0.2.0.4; asInvoker manifest; all three embedded runtime files match source byte for byte.")
    print("EXE SHA256:",hashlib.sha256(b).hexdigest())

if __name__ == "__main__":
    main()
