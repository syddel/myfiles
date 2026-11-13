"""On-disk file storage.

Files are stored under random keys; names and folder structure live in the
database, so renaming or moving a file never touches the disk.
"""

import mimetypes
import shutil
import uuid
from pathlib import Path

EXTRA_TYPES = {
    ".md": "text/markdown",
    ".mkv": "video/x-matroska",
    ".webm": "video/webm",
    ".m4v": "video/mp4",
    ".mov": "video/quicktime",
    ".flac": "audio/flac",
    ".opus": "audio/opus",
    ".m4a": "audio/mp4",
    ".ogg": "audio/ogg",
    ".wav": "audio/wav",
    ".webp": "image/webp",
    ".avif": "image/avif",
    ".heic": "image/heic",
    ".yaml": "application/yaml",
    ".yml": "application/yaml",
    ".toml": "application/toml",
    ".log": "text/plain",
    ".7z": "application/x-7z-compressed",
    ".rar": "application/vnd.rar",
}

TEXT_EXTENSIONS = {
    "txt", "md", "log", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "ini", "cfg",
    "conf", "env", "py", "js", "mjs", "ts", "jsx", "tsx", "vue", "svelte", "html", "htm",
    "css", "scss", "less", "sh", "bash", "zsh", "fish", "c", "h", "cpp", "hpp", "cc", "java",
    "kt", "go", "rs", "rb", "php", "pl", "lua", "sql", "r", "swift", "cs", "dart", "srt",
    "vtt", "tex", "bat", "ps1", "gitignore", "dockerfile", "makefile", "properties", "diff",
    "patch",
}
TEXT_MIME_TYPES = {
    "application/json", "application/xml", "application/javascript", "application/x-sh",
    "application/yaml", "application/toml", "application/sql", "application/x-httpd-php",
}
ARCHIVE_MIME_TYPES = {
    "application/zip", "application/x-tar", "application/gzip", "application/x-7z-compressed",
    "application/vnd.rar", "application/x-bzip2", "application/x-xz", "application/zstd",
}


def guess_mime(name: str) -> str:
    suffix = Path(name).suffix.lower()
    if suffix in EXTRA_TYPES:
        return EXTRA_TYPES[suffix]
    return mimetypes.guess_type(name, strict=False)[0] or "application/octet-stream"


def file_kind(name: str, mime: str | None) -> str:
    """Broad category used for icons and in-browser previews."""
    mime = mime or ""
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else name.lower()
    if mime == "application/pdf":
        return "pdf"
    for kind in ("image", "audio", "video"):
        if mime.startswith(kind + "/"):
            return kind
    if mime.startswith("text/") or mime in TEXT_MIME_TYPES or ext in TEXT_EXTENSIONS:
        return "text"
    if mime in ARCHIVE_MIME_TYPES:
        return "archive"
    return "other"


class Storage:
    def __init__(self, root: Path):
        self.root = root.expanduser().resolve()
        self.files_dir = self.root / "files"
        self.tmp_dir = self.root / "tmp"

    def init(self) -> None:
        self.files_dir.mkdir(parents=True, exist_ok=True)
        self.tmp_dir.mkdir(parents=True, exist_ok=True)
        probe = self.tmp_dir / ".write-test"
        try:
            probe.write_bytes(b"ok")
            probe.unlink()
        except OSError as exc:
            raise RuntimeError(f"STORAGE_PATH {self.root} is not writable: {exc}") from exc
        # Leftovers from uploads interrupted by a restart.
        for leftover in self.tmp_dir.iterdir():
            leftover.unlink(missing_ok=True)

    def new_key(self) -> str:
        return uuid.uuid4().hex

    def path_for(self, user_id: int, key: str) -> Path:
        return self.files_dir / str(user_id) / key[:2] / key

    def temp_path(self) -> Path:
        return self.tmp_dir / uuid.uuid4().hex

    def delete(self, user_id: int, key: str) -> None:
        self.path_for(user_id, key).unlink(missing_ok=True)

    def delete_user(self, user_id: int) -> None:
        shutil.rmtree(self.files_dir / str(user_id), ignore_errors=True)

    def disk_usage(self) -> shutil._ntuple_diskusage:
        return shutil.disk_usage(self.root)
