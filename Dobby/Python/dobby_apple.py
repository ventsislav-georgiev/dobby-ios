"""Apple glue for the shared a4k tree (#482). Copied into the bundle next to it by
scripts/copy-python.sh; PythonRuntime.swift calls the three functions below with one
JSON string each and gets one JSON string back, so Swift never builds Python objects.

The a4k tree itself is Android's, unchanged. The one place it reaches for the platform
is RAR (a4k_bg_services/_archive.py `from java import jclass`), so this module installs
a `java` stand-in whose RarExtractor is the system libarchive through ctypes. libarchive
ships in the macOS and iOS dyld shared cache (the iOS SDK exports libarchive.tbd), so no
extractor package is added to the app.
"""
import ctypes
import json
import os
import sys
import types

_MAX_ENTRY_BYTES = 32 * 1024 * 1024  # Android RarExtractor.MAX_ENTRY_BYTES


class _Sink(object):
    """Stands in for the Java sinks: rows as lists of strings, plus the last progress call."""

    def __init__(self):
        self.rows = []
        self.last_progress = None

    def add(self, *fields):
        self.rows.append([str(f) for f in fields])

    def progress(self, done, count, total):
        self.last_progress = [bool(done), int(count), int(total)]


def _safe_name(name):
    # RarExtractor.safeName: the base name only, never a path from the archive.
    base = (name or "").strip().replace("\\", "/").rsplit("/", 1)[-1]
    if base in ("", ".", ".."):
        return "entry-%x" % (hash(name) & 0xFFFFFFFF)
    return base


class RarExtractor(object):
    """libarchive read of any archive it knows (RAR4, RAR5, 7z, zip), flattened into dest."""

    _lib = None

    @classmethod
    def _libarchive(cls):
        if cls._lib is None:
            lib = ctypes.CDLL("/usr/lib/libarchive.2.dylib")
            vp = ctypes.c_void_p
            for fn, res, args in (
                ("archive_read_new", vp, []),
                ("archive_read_support_format_all", ctypes.c_int, [vp]),
                ("archive_read_support_filter_all", ctypes.c_int, [vp]),
                ("archive_read_open_filename", ctypes.c_int, [vp, ctypes.c_char_p, ctypes.c_size_t]),
                ("archive_read_next_header", ctypes.c_int, [vp, ctypes.POINTER(vp)]),
                ("archive_read_data", ctypes.c_ssize_t, [vp, vp, ctypes.c_size_t]),
                ("archive_read_free", ctypes.c_int, [vp]),
                ("archive_error_string", ctypes.c_char_p, [vp]),
                ("archive_entry_pathname", ctypes.c_char_p, [vp]),
                ("archive_entry_filetype", ctypes.c_uint, [vp]),
                ("archive_entry_is_encrypted", ctypes.c_int, [vp]),
            ):
                f = getattr(lib, fn)
                f.restype, f.argtypes = res, args
            cls._lib = lib
        return cls._lib

    @classmethod
    def extract(cls, archive_path, dest_dir):
        lib = cls._libarchive()
        os.makedirs(dest_dir, exist_ok=True)
        a = lib.archive_read_new()
        written = []
        try:
            lib.archive_read_support_format_all(a)
            lib.archive_read_support_filter_all(a)
            if lib.archive_read_open_filename(a, os.fsencode(archive_path), 65536) != 0:
                raise IOError("libarchive: %s" % (lib.archive_error_string(a) or b"open failed").decode("utf-8", "replace"))
            entry = ctypes.c_void_p()
            buf = ctypes.create_string_buffer(65536)
            while True:
                rc = lib.archive_read_next_header(a, ctypes.byref(entry))
                if rc == 1:  # ARCHIVE_EOF
                    break
                if rc < -20:  # ARCHIVE_FATAL; WARN/RETRY still carry a usable header
                    raise IOError("libarchive: %s" % (lib.archive_error_string(a) or b"").decode("utf-8", "replace"))
                if lib.archive_entry_filetype(entry) != 0o100000 or lib.archive_entry_is_encrypted(entry) == 1:
                    continue  # directories, links and encrypted entries, as RarExtractor skips them
                raw = lib.archive_entry_pathname(entry) or b""
                out = os.path.join(dest_dir, _safe_name(raw.decode("utf-8", "replace")))
                size, ok = 0, True
                with open(out, "wb") as f:
                    while True:
                        n = lib.archive_read_data(a, buf, len(buf))
                        if n == 0:
                            break
                        size += max(n, 0)
                        if n < 0 or size > _MAX_ENTRY_BYTES:
                            ok = False
                            break
                        f.write(buf.raw[:n])
                if ok:
                    written.append(out)
                else:
                    os.remove(out)  # a truncated file must not pass for a subtitle
        finally:
            lib.archive_read_free(a)
        # One line per unpack: the RAR route is otherwise invisible in a capture.
        sys.stderr.write("dobby_apple: libarchive unpacked %d entries from %s\n"
                         % (len(written), os.path.basename(archive_path)))
        return written


def _install_java_shim():
    if "java" in sys.modules:
        return
    shim = types.ModuleType("java")
    shim.jclass = lambda name: RarExtractor
    sys.modules["java"] = shim


_install_java_shim()


def info(_params_json):
    """Version line for the logs, and the imports a first search would pay, paid up front."""
    import ssl
    import a4k_search  # noqa: F401
    import a4k_subs  # noqa: F401
    import bs4  # noqa: F401
    import requests  # noqa: F401
    return json.dumps({"version": sys.version.split()[0], "openssl": ssl.OPENSSL_VERSION})


def search(params_json):
    import a4k_search
    sink = _Sink()
    total = a4k_search.run_search(params_json, sink)
    return json.dumps({"providers": total, "progress": sink.last_progress,
                       "rows": [r[:5] for r in sink.rows]})  # hash, title, seeds, size, provider


def subs(params_json):
    import a4k_subs
    sink = _Sink()
    count = a4k_subs.search(params_json, sink)
    return json.dumps({"count": count, "rows": sink.rows})  # service, lang, name, args


def download(params_json):
    import a4k_subs
    filepath, error = a4k_subs.download(params_json)
    return json.dumps({"file": filepath, "error": error})


if __name__ == "__main__":
    # Self-check on the host (`python3 Dobby/Python/dobby_apple.py`): libarchive reads a zip the
    # same way it reads a RAR, so a zip fixture covers the hostile-name and size-cap guards.
    import tempfile
    import zipfile
    tmp = tempfile.mkdtemp()
    fixture, dest = os.path.join(tmp, "fixture.zip"), os.path.join(tmp, "out", "dest")
    with zipfile.ZipFile(fixture, "w") as z:
        z.writestr("../escape.srt", "outside")
        z.writestr("Season 1\\ep1.srt", "nested")
        z.writestr("big.srt", "x" * 2048)
    _MAX_ENTRY_BYTES = 1024
    written = sorted(os.path.basename(p) for p in RarExtractor.extract(fixture, dest))
    assert written == ["ep1.srt", "escape.srt"], written
    assert not os.path.exists(os.path.join(tmp, "out", "escape.srt")), "an archive name escaped dest"
    assert not os.path.exists(os.path.join(dest, "big.srt")), "an entry over the cap was kept"
    assert open(os.path.join(dest, "escape.srt")).read() == "outside"
    print("dobby_apple self-check: OK", written)
