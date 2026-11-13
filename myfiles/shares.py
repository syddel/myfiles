"""Sharing folders and files by link: owner endpoints under /api/shares, public ones under /api/s/{token}.

A shared folder can be read-only or read & write (visitors may upload); a shared file is always read-only.
A share can also have a password: visitors then need the link *and* the password.
"""

import hashlib
import hmac
import re
import secrets
import threading
import time
from collections import defaultdict, deque
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from . import auth
from .api import ROOT_NAME, file_response, folder_paths, get_node, node_out, receive_upload, zip_response
from .auth import current_user, get_db
from .models import Node, Share, User

router = APIRouter()

# Share tokens: 32 URL-safe characters (192 random bits). Also used to route /{token} to the app.
TOKEN_REGEX = r"[A-Za-z0-9_-]{32}"
TOKEN_RE = re.compile(TOKEN_REGEX)

ShareMode = Literal["read", "readwrite"]

MIN_SHARE_PASSWORD_LENGTH = 4
UNLOCK_COOKIE_DAYS = 7
# Wrong share passwords allowed per visitor and link before they have to wait.
MAX_FAILED_UNLOCKS = 10
FAILED_UNLOCK_WINDOW = 10 * 60  # seconds


def new_token() -> str:
    return secrets.token_urlsafe(24)


def share_url(request: Request, token: str) -> str | None:
    base = request.app.state.settings.base_url.rstrip("/")
    return f"{base}/{token}" if base else None


# ---------------------------------------------------------------- owner


def node_path(node: Node, folder_paths_: dict[int, str]) -> str:
    if node.is_dir:
        return folder_paths_.get(node.id, "")
    return f"{folder_paths_.get(node.parent_id, '')}/{node.name}"


def share_out(request: Request, share: Share, node: Node, folder_paths_: dict[int, str]) -> dict:
    return {
        "node_id": node.id,
        "parent_id": node.parent_id,
        "is_dir": node.is_dir,
        "kind": node_out(node)["kind"],
        "path": node_path(node, folder_paths_),
        "name": node.name or ROOT_NAME,
        "mode": share.mode,
        "has_password": share.password_hash is not None,
        "token": share.token,
        "url": share_url(request, share.token),
        "created_at": share.created_at.isoformat() + "Z",
    }


class ShareSettings(BaseModel):
    mode: ShareMode


class SharePassword(BaseModel):
    password: str | None  # None removes the password


@router.get("/shares")
def list_shares(request: Request, user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.execute(select(Share, Node).join(Node, Node.id == Share.node_id).where(Share.user_id == user.id)).all()
    paths = folder_paths(db, user)
    out = [share_out(request, share, node, paths) for share, node in rows]
    return sorted(out, key=lambda s: s["path"].lower())


@router.get("/shares/{node_id}")
def get_share(node_id: int, request: Request, user: User = Depends(current_user), db: Session = Depends(get_db)):
    node = get_node(db, user, node_id)
    share = db.scalar(select(Share).where(Share.node_id == node.id))
    if share is None:
        return None
    return share_out(request, share, node, folder_paths(db, user))


@router.put("/shares/{node_id}")
def set_share(
    node_id: int, body: ShareSettings, request: Request,
    user: User = Depends(current_user), db: Session = Depends(get_db),
):
    """Share a folder or file, or change the mode of an existing share (the link stays the same)."""
    node = get_node(db, user, node_id)
    if not node.is_dir and body.mode != "read":
        raise HTTPException(400, "Files can only be shared read-only")
    share = db.scalar(select(Share).where(Share.node_id == node.id))
    if share is None:
        share = Share(token=new_token(), node_id=node.id, user_id=user.id, mode=body.mode)
        db.add(share)
    else:
        share.mode = body.mode
    db.commit()
    return share_out(request, share, node, folder_paths(db, user))


@router.put("/shares/{node_id}/password")
def set_share_password(
    node_id: int, body: SharePassword, request: Request,
    user: User = Depends(current_user), db: Session = Depends(get_db),
):
    """Set, change or (with null) remove a share's password.

    Changing or removing it signs out every visitor who unlocked the link with the old password.
    """
    node = get_node(db, user, node_id)
    share = db.scalar(select(Share).where(Share.node_id == node.id))
    if share is None:
        raise HTTPException(404, "This item isn't shared")
    if body.password is None:
        share.password_hash = None
    else:
        if len(body.password) < MIN_SHARE_PASSWORD_LENGTH:
            raise HTTPException(400, f"The password must be at least {MIN_SHARE_PASSWORD_LENGTH} characters")
        share.password_hash = auth.hash_password(body.password)
    db.commit()
    return share_out(request, share, node, folder_paths(db, user))


@router.delete("/shares/{node_id}", status_code=204)
def stop_sharing(node_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    node = get_node(db, user, node_id)
    db.execute(delete(Share).where(Share.node_id == node.id))
    db.commit()


# ---------------------------------------------------------------- share passwords


def _unlock_cookie_name(token: str) -> str:
    return f"myfiles_share_{token}"


def _unlock_proof(share: Share) -> str:
    # Keyed with the password hash, so it can't be forged without the database, and
    # it stops matching as soon as the password is changed or removed.
    return hmac.new(share.password_hash.encode(), share.token.encode(), hashlib.sha256).hexdigest()


def is_unlocked(request: Request, share: Share) -> bool:
    if share.password_hash is None:
        return True
    cookie = request.cookies.get(_unlock_cookie_name(share.token), "")
    return hmac.compare_digest(cookie, _unlock_proof(share))


class _FailedUnlocks:
    """Counts wrong share passwords per (visitor IP, link) to slow down guessing."""

    def __init__(self):
        self._lock = threading.Lock()
        self._failures: dict[tuple[str, str], deque[float]] = defaultdict(deque)

    def _recent(self, key: tuple[str, str], now: float) -> deque[float]:
        times = self._failures[key]
        while times and times[0] < now - FAILED_UNLOCK_WINDOW:
            times.popleft()
        return times

    def blocked(self, key: tuple[str, str]) -> bool:
        with self._lock:
            return len(self._recent(key, time.monotonic())) >= MAX_FAILED_UNLOCKS

    def record(self, key: tuple[str, str]) -> None:
        with self._lock:
            now = time.monotonic()
            self._recent(key, now).append(now)

    def clear(self, key: tuple[str, str]) -> None:
        with self._lock:
            self._failures.pop(key, None)


failed_unlocks = _FailedUnlocks()


class Unlock(BaseModel):
    password: str


@router.post("/s/{token}/unlock", status_code=204)
def unlock_share(token: str, body: Unlock, request: Request, response: Response, db: Session = Depends(get_db)):
    """Check a share's password; on success the visitor's browser gets a cookie for this link."""
    share = load_share(db, token)
    if share.password_hash is None:
        return
    key = (request.client.host if request.client else "", share.token)
    if failed_unlocks.blocked(key):
        raise HTTPException(429, "Too many wrong passwords. Please wait a few minutes and try again.")
    if not auth.verify_password(share.password_hash, body.password):
        failed_unlocks.record(key)
        raise HTTPException(403, "Wrong password")
    failed_unlocks.clear(key)
    response.set_cookie(
        _unlock_cookie_name(share.token),
        _unlock_proof(share),
        max_age=UNLOCK_COOKIE_DAYS * 24 * 3600,
        httponly=True,
        samesite="lax",
        secure=auth.cookie_secure(request),
        path="/",
    )


# ---------------------------------------------------------------- public (anyone with the link)


def load_share(db: Session, token: str) -> Share:
    share = db.scalar(select(Share).where(Share.token == token)) if TOKEN_RE.fullmatch(token) else None
    if share is None:
        raise HTTPException(404, "This link doesn't exist or sharing has been turned off")
    return share


def open_share(db: Session, token: str, request: Request) -> Share:
    """The share behind a link, if the visitor may see it (password entered, when there is one)."""
    share = load_share(db, token)
    if not is_unlocked(request, share):
        raise HTTPException(401, "password_required")
    return share


def shared_node(db: Session, share: Share, node_id: int) -> Node:
    """A node inside the shared folder (or the shared folder itself), else 404."""
    node = db.get(Node, node_id)
    if node is not None and node.user_id == share.user_id:
        ancestor: Node | None = node
        while ancestor is not None:
            if ancestor.id == share.node_id:
                return node
            ancestor = db.get(Node, ancestor.parent_id) if ancestor.parent_id else None
    raise HTTPException(404, "Not found")


def shared_folder(db: Session, share: Share, node_id: int) -> Node:
    node = shared_node(db, share, node_id)
    if not node.is_dir:
        raise HTTPException(400, "Not a folder")
    return node


def public_node_out(node: Node) -> dict:
    out = node_out(node)
    out.pop("share", None)
    return out


@router.get("/s/{token}")
def public_share_info(token: str, request: Request, db: Session = Depends(get_db)):
    share = load_share(db, token)
    app_name = request.app.state.settings.app_name
    if not is_unlocked(request, share):
        # Reveal nothing about the shared item until the password has been entered.
        return {"locked": True, "app_name": app_name}
    folder = db.get(Node, share.node_id)
    owner = db.get(User, share.user_id)
    return {
        "locked": False,
        "name": folder.name or ROOT_NAME,
        "mode": share.mode,
        "owner": owner.username,
        "root_id": folder.id,
        "is_dir": folder.is_dir,
        "node": public_node_out(folder),  # for a shared file: its size, type, dates
        "app_name": app_name,
    }


@router.get("/s/{token}/folders/{folder_id}")
def public_list_folder(token: str, folder_id: int, request: Request, db: Session = Depends(get_db)):
    share = open_share(db, token, request)
    folder = shared_folder(db, share, folder_id)
    crumbs = []
    node: Node | None = folder
    while node is not None:
        crumbs.append({"id": node.id, "name": node.name or ROOT_NAME})
        if node.id == share.node_id:
            break
        node = db.get(Node, node.parent_id)
    items = db.scalars(select(Node).where(Node.parent_id == folder.id)).all()
    return {"folder": public_node_out(folder), "breadcrumb": crumbs[::-1], "items": [public_node_out(n) for n in items]}


@router.get("/s/{token}/files/{file_id}/content")
def public_file_content(token: str, file_id: int, request: Request, download: bool = False, db: Session = Depends(get_db)):
    share = open_share(db, token, request)
    return file_response(request.app.state.storage, shared_node(db, share, file_id), download)


@router.get("/s/{token}/zip")
def public_zip(token: str, request: Request, ids: list[int] = Query(), db: Session = Depends(get_db)):
    share = open_share(db, token, request)
    selected = [shared_node(db, share, i) for i in dict.fromkeys(ids)]
    return zip_response(db, request.app.state.storage, selected, request.app.state.settings.app_name)


def _upload_owner(db: Session, token: str, request: Request, parent_id: int) -> User:
    share = open_share(db, token, request)
    if share.mode != "readwrite":
        raise HTTPException(403, "This shared folder is read-only")
    shared_folder(db, share, parent_id)
    return db.get(User, share.user_id)


@router.post("/s/{token}/upload", status_code=201)
async def public_upload(
    token: str, request: Request, parent_id: int, name: str, relative_dir: str = "",
    db: Session = Depends(get_db),
):
    """Upload into a read/write share. Visitors can add files but never change or delete existing ones."""
    owner = await run_in_threadpool(_upload_owner, db, token, request, parent_id)
    node = await receive_upload(request, db, owner, parent_id, name, relative_dir, for_visitor=True)
    node.pop("share", None)
    return node
