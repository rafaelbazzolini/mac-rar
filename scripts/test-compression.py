"""Round-trip tests of creation, AES encryption, inspection and cancellation."""
import ctypes as c
import pathlib
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
library = root / '.build/libCompressionTests.dylib'
subprocess.run(['clang', '-dynamiclib', '-ISources/ArchiveBridge/include',
                'Sources/ArchiveBridge/ArchiveBridge.c', '-larchive', '-o', str(library)], cwd=root, check=True)
api = c.CDLL(str(library))
api.macrar_writer_open.argtypes = [c.c_char_p, c.c_char_p, c.c_char_p, c.c_int, c.c_char_p, c.c_void_p, c.c_char_p, c.c_size_t]
api.macrar_writer_open.restype = c.c_void_p
api.macrar_writer_add.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p, c.c_char_p, c.c_size_t]
api.macrar_writer_close.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t]
api.macrar_writer_abort.argtypes = [c.c_void_p]
api.macrar_extract_options.argtypes = [c.c_char_p, c.c_char_p, c.c_char_p, c.c_void_p, c.c_char_p, c.c_size_t]
api.macrar_inspect.argtypes = [c.c_char_p, c.c_char_p, c.c_int, c.c_void_p, c.c_void_p, c.c_void_p, c.c_char_p, c.c_size_t]
api.macrar_cancel_new.restype = c.c_void_p
api.macrar_cancel.argtypes = [c.c_void_p]
api.macrar_cancel_free.argtypes = [c.c_void_p]

with tempfile.TemporaryDirectory() as temp:
    base = pathlib.Path(temp).resolve()
    source = base / 'original.txt'
    payload = ('Olá MacRar! ' * 10000).encode()
    source.write_bytes(payload)
    directory = base / 'empty-folder'
    directory.mkdir()
    error = c.create_string_buffer(4096)
    cases = [('zip', '', 0, ''), ('zip', '', 9, ''), ('zip', '', 6, 'senha ç secreta'),
             ('7zip', '', 1, ''), ('7zip', '', 9, ''), ('paxr', '', -1, ''),
             ('paxr', 'gzip', 6, ''), ('paxr', 'bzip2', 6, ''),
             ('paxr', 'xz', 6, '')]
    for i, (format_name, filter_name, level, password) in enumerate(cases):
        archive = base / f'test-{i}'
        writer = api.macrar_writer_open(bytes(archive), format_name.encode(), filter_name.encode(), level,
                                        password.encode(), None, error, len(error))
        assert writer, error.value
        assert api.macrar_writer_add(writer, bytes(source), 'pasta/olá.txt'.encode(), error, len(error)) == 0, error.value
        assert api.macrar_writer_add(writer, bytes(directory), b'empty-folder', error, len(error)) == 0, error.value
        assert api.macrar_writer_close(writer, error, len(error)) == 0, error.value
        assert api.macrar_inspect(bytes(archive), password.encode(), 1, None, None, None, error, len(error)) == 0, error.value
        destination = base / f'output-{i}'
        destination.mkdir()
        assert api.macrar_extract_options(bytes(archive), bytes(destination), password.encode(), None, error, len(error)) == 0, error.value
        assert (destination / 'pasta/olá.txt').read_bytes() == payload
        assert (destination / 'empty-folder').is_dir()
        if password:
            assert api.macrar_inspect(bytes(archive), b'wrong', 1, None, None, None, error, len(error)) != 0
            print('PASS wrong password rejected')
        print('PASS round trip', format_name, filter_name, level, 'encrypted' if password else '')

    token = api.macrar_cancel_new()
    api.macrar_cancel(token)
    writer = api.macrar_writer_open(bytes(base / 'cancelled.zip'), b'zip', b'', 6, b'', token, error, len(error))
    assert writer, error.value
    assert api.macrar_writer_add(writer, bytes(source), b'file.txt', error, len(error)) != 0
    api.macrar_writer_abort(writer)
    api.macrar_cancel_free(token)
    print('PASS cancellation')

    writer = api.macrar_writer_open(bytes(base / 'links.zip'), b'zip', b'', 6, b'', None, error, len(error))
    link = base / 'link'
    link.symlink_to(source)
    assert api.macrar_writer_add(writer, bytes(link), b'link', error, len(error)) != 0
    assert api.macrar_writer_add(writer, bytes(source), b'../escape', error, len(error)) != 0
    api.macrar_writer_abort(writer)
    print('PASS unsafe inputs rejected')

    corrupted = base / 'corrupted.zip'
    with zipfile.ZipFile(corrupted, 'w', zipfile.ZIP_STORED) as out:
        out.writestr('test.txt', b'INTEGRITY_PAYLOAD')
    corrupted.write_bytes(corrupted.read_bytes().replace(b'INTEGRITY_PAYLOAD', b'DAMAGED___PAYLOAD'))
    assert api.macrar_inspect(bytes(corrupted), b'', 1, None, None, None, error, len(error)) != 0
    print('PASS corrupted data rejected')
print('All compression checks passed.')
