"""Per-user storage quotas.

users.quota_bytes holds a user's own quota: NULL means "use DEFAULT_QUOTA_GB from
.env" and -1 means unlimited. Usage is the total size of the user's files.
"""

import re

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .config import Settings
from .models import Node, User

GB = 1024**3
UNLIMITED = -1

_UNITS = {"": GB, "b": 1, "k": 1024, "kb": 1024, "m": 1024**2, "mb": 1024**2,
          "g": GB, "gb": GB, "t": 1024**4, "tb": 1024**4}
_SIZE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*([a-zA-Z]*)\s*$")


def parse_size(text: str) -> int:
    """'50', '50GB', '500 MB', '1.5TB' -> bytes. A bare number means GB."""
    m = _SIZE_RE.match(text)
    unit = m.group(2).lower().removesuffix("ib").removesuffix("i") if m else ""
    if not m or unit not in _UNITS:
        raise ValueError(f"Not a size: {text!r} (examples: 50GB, 500MB, 1.5TB)")
    return int(float(m.group(1)) * _UNITS[unit])


def default_quota(settings: Settings) -> int | None:
    """The default quota in bytes, or None for unlimited."""
    return int(settings.default_quota_gb * GB) if settings.default_quota_gb > 0 else None


def quota_of(user: User, settings: Settings) -> int | None:
    """The user's quota in bytes, or None for unlimited."""
    if user.quota_bytes is None:
        return default_quota(settings)
    return None if user.quota_bytes < 0 else user.quota_bytes


def quota_mode(user: User) -> str:
    if user.quota_bytes is None:
        return "default"
    return "unlimited" if user.quota_bytes < 0 else "custom"


def used_bytes(db: Session, user_id: int, latest: bool = False) -> int:
    """Total size of the user's files. latest=True uses a locking read, which always sees the
    newest committed rows (a plain read in a REPEATABLE READ transaction may see a snapshot)."""
    query = select(func.coalesce(func.sum(Node.size), 0)).where(Node.user_id == user_id, Node.is_dir.is_(False))
    if latest:
        query = query.with_for_update(read=True)
    return int(db.scalar(query))


def format_size(n: int | None) -> str:
    if n is None:
        return "unlimited"
    for unit, size in (("TB", 1024**4), ("GB", GB), ("MB", 1024**2), ("KB", 1024)):
        if n >= size:
            value = n / size
            return f"{value:.1f} {unit}".replace(".0 ", " ")
    return f"{n} B"


def check_room(db: Session, settings: Settings, owner: User, incoming: int, used: int | None = None,
               for_visitor: bool = False) -> None:
    """Raise 413 if adding `incoming` bytes would take `owner` over their quota."""
    quota = quota_of(owner, settings)
    if quota is None:
        return
    if used is None:
        used = used_bytes(db, owner.id)
    if used + incoming <= quota:
        return
    if for_visitor:
        # Don't tell anonymous visitors anything about the owner's account.
        raise HTTPException(413, "There isn't enough space left in this shared folder")
    left = max(quota - used, 0)
    raise HTTPException(
        413,
        f"Not enough space: {format_size(incoming)} needed, but only {format_size(left)} "
        f"of your {format_size(quota)} quota is left",
    )
