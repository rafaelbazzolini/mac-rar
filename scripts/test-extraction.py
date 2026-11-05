"""Integration checks for the actual C extraction engine; uses only Python's stdlib."""
import ctypes
import gzip
import io
import pathlib
import subprocess
import tarfile
import tempfile
import zipfile
import struct
import zlib

root = pathlib.Path(__file__).resolve().parent.parent
library = root / '.build/libArchiveBridge.dylib'
library.parent.mkdir(exist_ok=True)
subprocess.run(['clang', '-dynamiclib', '-ISources/ArchiveBridge/include',
                'Sources/ArchiveBridge/ArchiveBridge.c', '-larchive', '-o', str(library)], cwd=root, check=True)
engine = ctypes.CDLL(str(library)).macrar_extract
engine.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
engine.restype = ctypes.c_int

with tempfile.TemporaryDirectory() as temp:
    base = pathlib.Path(temp).resolve()
    payload = b'MacRar integration test\n'
    def extract(source, succeeds):
        destination = base / (source.name + '-output')
        destination.mkdir()
        error = ctypes.create_string_buffer(4096)
        result = engine(bytes(source), bytes(destination), error, len(error))
        assert (result == 0) == succeeds, (source.name, error.value)
        print('PASS', source.name)
        return destination

    # A valid RAR4 stored-file fixture (CRC-protected headers and payload).
    def rar_header(kind, flags, body):
        header = struct.pack('<BHH', kind, flags, 7 + len(body)) + body
        return struct.pack('<H', zlib.crc32(header) & 0xffff) + header
    name = b'rar-test.txt'
    file_body = struct.pack('<IIBIIBBHI', len(payload), len(payload), 3,
                            zlib.crc32(payload), 0, 20, 0x30, len(name), 0o100644) + name
    archive = base / 'sample.rar'
    archive.write_bytes(b'Rar!\x1a\x07\x00' + rar_header(0x73, 0, b'\x00' * 6)
                        + rar_header(0x74, 0x8000, file_body) + payload + rar_header(0x7b, 0, b''))
    assert (extract(archive, True) / 'rar-test.txt').read_bytes() == payload

    # RAR directory headers must never be passed to the data decompressor.
    directory = b'pasta'
    directory_body = struct.pack('<IIBIIBBHI', 0, 0, 3, 0, 0, 20, 0x33,
                                 len(directory), 0o40755) + directory
    nested_name = b'pasta/test.txt'
    nested_body = struct.pack('<IIBIIBBHI', len(payload), len(payload), 3,
                             zlib.crc32(payload), 0, 20, 0x30,
                             len(nested_name), 0o100644) + nested_name
    archive = base / 'directories.rar'
    archive.write_bytes(b'Rar!\x1a\x07\x00' + rar_header(0x73, 0, b'\x00' * 6)
                        + rar_header(0x74, 0x80e0, directory_body)
                        + rar_header(0x74, 0x8000, nested_body) + payload
                        + rar_header(0x7b, 0, b''))
    assert (extract(archive, True) / 'pasta/test.txt').read_bytes() == payload

    archive = base / 'sample.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as out:
        out.writestr('pasta/olá.txt', payload)
    assert (extract(archive, True) / 'pasta/olá.txt').read_bytes() == payload

    for extension, mode in [('tar', 'w'), ('tar.gz', 'w:gz'), ('tar.bz2', 'w:bz2'), ('tar.xz', 'w:xz')]:
        archive = base / ('sample.' + extension)
        with tarfile.open(archive, mode) as out:
            info = tarfile.TarInfo('nested/test.txt')
            info.size = len(payload)
            out.addfile(info, io.BytesIO(payload))
        assert (extract(archive, True) / 'nested/test.txt').read_bytes() == payload

    archive = base / 'plain.txt.gz'
    archive.write_bytes(gzip.compress(payload))
    assert (extract(archive, True) / 'plain.txt').read_bytes() == payload

    (base / 'input.txt').write_bytes(payload)
    archive = base / 'sample.7z'
    subprocess.run(['/usr/bin/tar', '--format', '7zip', '-cf', str(archive), '-C', str(base), 'input.txt'], check=True)
    assert (extract(archive, True) / 'input.txt').read_bytes() == payload

    for name, path in [('traversal.zip', '../escape.txt'), ('absolute.zip', str(base / 'escape.txt'))]:
        archive = base / name
        with zipfile.ZipFile(archive, 'w') as out:
            out.writestr(path, payload)
        extract(archive, False)
        assert not (base / 'escape.txt').exists()

    archive = base / 'symlink.tar'
    with tarfile.open(archive, 'w') as out:
        info = tarfile.TarInfo('link')
        info.type = tarfile.SYMTYPE
        info.linkname = '/tmp'
        out.addfile(info)
    extract(archive, False)

    archive = base / 'invalid.rar'
    archive.write_bytes(b'not an archive')
    extract(archive, False)
print('All extraction checks passed.')
