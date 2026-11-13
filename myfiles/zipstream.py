"""Stream a zip archive without building it on disk or in memory first."""

import zipfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterator

CHUNK_SIZE = 1024 * 1024

# Unix permissions recorded in the archive (unzip applies the user's umask on top).
# Without them, unzip creates folders you can't open.
DIR_ATTR = (0o40755 << 16) | 0x10  # drwxr-xr-x, plus the MS-DOS directory flag
FILE_ATTR = 0o100644 << 16  # -rw-r--r--


@dataclass
class ZipEntry:
    path: str  # path inside the archive; folders end with "/"
    source: Path | None  # file on disk, None for folders
    size: int
    modified: datetime


class _Sink:
    """Write-only, unseekable file object that collects bytes for the generator to yield."""

    def __init__(self):
        self.buffer = bytearray()
        self.position = 0

    def write(self, data) -> int:
        self.buffer += data
        self.position += len(data)
        return len(data)

    def tell(self) -> int:
        return self.position

    def flush(self) -> None:
        pass

    def take(self) -> bytes:
        data = bytes(self.buffer)
        self.buffer.clear()
        return data


def stream_zip(entries: list[ZipEntry]) -> Iterator[bytes]:
    """Yield a zip archive of the entries, chunk by chunk.

    Files are stored uncompressed: it's much faster, and photos, music and
    video don't compress anyway. Zip64 is used automatically for big files.
    """
    sink = _Sink()
    with zipfile.ZipFile(sink, mode="w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for entry in entries:
            info = zipfile.ZipInfo(entry.path, date_time=_zip_time(entry.modified))
            info.create_system = 3  # Unix, so external_attr is read as Unix permissions
            info.external_attr = DIR_ATTR if entry.source is None else FILE_ATTR
            if entry.source is None:
                archive.writestr(info, b"")
            else:
                info.file_size = entry.size  # lets zipfile decide on Zip64 up front
                try:
                    source = open(entry.source, "rb")
                except FileNotFoundError:
                    continue
                with source, archive.open(info, "w", force_zip64=entry.size > 0xFFFFFFFF) as dest:
                    while chunk := source.read(CHUNK_SIZE):
                        dest.write(chunk)
                        yield sink.take()
            yield sink.take()
    yield sink.take()


def _zip_time(dt: datetime) -> tuple[int, int, int, int, int, int]:
    # Zip timestamps can't go before 1980.
    return max(dt.timetuple()[:6], (1980, 1, 1, 0, 0, 0))
