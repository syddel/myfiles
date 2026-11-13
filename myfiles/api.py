"""JSON API under /api."""

import os
import re
import secrets
from pathlib import Path
from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from sqlalchemy import delete, func, literal, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, aliased
from starlette.requests import ClientDisconnect

from . import auth
from .auth import current_user, get_db
from .models import Node, Share, User
from . import quotas
from .storage import Storage, file_kind, guess_mime
from .zipstream import ZipEntry, stream_zip

router = APIRouter()

ROOT_NAME = "Home"  # display name of each user's top-level folder
# Colors a user can pick for their folder icons (the frontend maps each to its shades).
FOLDER_COLORS = (
    "amber", "yellow", "orange", "red", "rose", "pink", "fuchsia", "purple", "violet", "indigo",
    "blue", "sky", "cyan", "teal", "emerald", "green", "lime", "brown", "gray", "charcoal",
)
DEFAULT_FOLDER_COLOR = "amber"
THEMES = ("system", "light", "dark")  # "system" follows the device's light/dark setting
USERNAME_RE = re.compile(r"^[a-z0-9_.-]{3,32}$")
MIN_PASSWORD_LENGTH = 8
SEARCH_LIMIT = 200


# ---------------------------------------------------------------- helpers


def node_out(node: Node, path: str | None = None, share: str | None = None) -> dict:
    out = {
        "id": node.id,
        "parent_id": node.parent_id,
        "name": node.name,
        "is_dir": node.is_dir,
        "size": node.size,
        "mime_type": node.mime_type,
        "kind": "folder" if node.is_dir else file_kind(node.name, node.mime_type),
        "created_at": node.created_at.isoformat() + "Z",
        "updated_at": node.updated_at.isoformat() + "Z",
        "share": share,  # "read" / "readwrite" for shared folders
    }
    if path is not None:
        out["path"] = path
    return out


def share_modes(db: Session, user: User) -> dict[int, str]:
    """Folder id -> share mode, for all of the user's shared folders."""
    return dict(db.execute(select(Share.node_id, Share.mode).where(Share.user_id == user.id)).all())


def clean_name(name: str) -> str:
    name = name.strip()
    if not name or name in (".", "..") or "/" in name or len(name) > 255:
        raise HTTPException(400, "Invalid name")
    if any(ord(c) < 32 for c in name):
        raise HTTPException(400, "Name contains control characters")
    return name


def get_root(db: Session, user: User) -> Node:
    return db.scalars(select(Node).where(Node.user_id == user.id, Node.parent_id.is_(None))).one()


def get_node(db: Session, user: User, node_id: int) -> Node:
    node = db.get(Node, node_id)
    if node is None or node.user_id != user.id:
        raise HTTPException(404, "Not found")
    return node


def get_folder(db: Session, user: User, node_id: int) -> Node:
    node = get_node(db, user, node_id)
    if not node.is_dir:
        raise HTTPException(400, "Not a folder")
    return node


def name_taken(db: Session, parent_id: int, name: str) -> bool:
    return db.scalar(select(Node.id).where(Node.parent_id == parent_id, Node.name == name)) is not None


def unique_name(db: Session, parent_id: int, name: str) -> str:
    """Return name, or 'name (n).ext' if it's already taken in the folder."""
    if not name_taken(db, parent_id, name):
        return name
    stem, dot, ext = name.rpartition(".")
    if not stem:  # no extension, or a dotfile like ".bashrc"
        stem, dot, ext = name, "", ""
    n = 1
    while True:
        candidate = f"{stem} ({n}){dot}{ext}"
        if not name_taken(db, parent_id, candidate):
            return candidate
        n += 1


def breadcrumb(db: Session, folder: Node) -> list[dict]:
    crumbs = []
    node: Node | None = folder
    while node is not None:
        crumbs.append({"id": node.id, "name": node.name or ROOT_NAME})
        node = db.get(Node, node.parent_id) if node.parent_id else None
    return crumbs[::-1]


def folder_paths(db: Session, user: User) -> dict[int, str]:
    """Map every folder id of the user to its display path, e.g. '/Photos/2024'."""
    rows = db.execute(select(Node.id, Node.parent_id, Node.name).where(Node.user_id == user.id, Node.is_dir)).all()
    by_id = {r.id: r for r in rows}
    paths: dict[int, str] = {}

    def path_of(folder_id: int) -> str:
        if folder_id not in paths:
            row = by_id[folder_id]
            paths[folder_id] = "" if row.parent_id is None else f"{path_of(row.parent_id)}/{row.name}"
        return paths[folder_id]

    for folder_id in by_id:
        path_of(folder_id)
    return paths


def subtree(db: Session, user: User, ids: list[int]) -> list[tuple[int, str | None, int]]:
    """(id, storage_key, depth) for the given nodes and everything beneath them."""
    tree = (
        select(Node.id, Node.storage_key, literal(0).label("depth"))
        .where(Node.id.in_(ids), Node.user_id == user.id, Node.parent_id.is_not(None))
        .cte("tree", recursive=True)
    )
    child = aliased(Node)
    tree = tree.union_all(
        select(child.id, child.storage_key, tree.c.depth + 1).join(tree, child.parent_id == tree.c.id)
    )
    return [tuple(r) for r in db.execute(select(tree.c.id, tree.c.storage_key, tree.c.depth)).all()]


def get_or_create_folder(db: Session, user: User, parent: Node, name: str) -> Node:
    # Retry because parallel uploads of the same folder may race to create it.
    for _ in range(5):
        existing = db.scalar(select(Node).where(Node.parent_id == parent.id, Node.name == name))
        if existing:
            if not existing.is_dir:
                raise HTTPException(409, f"'{name}' already exists and is not a folder")
            return existing
        folder = Node(user_id=user.id, parent_id=parent.id, name=name, is_dir=True)
        db.add(folder)
        try:
            db.commit()
            return folder
        except IntegrityError:
            db.rollback()
    raise HTTPException(409, "Could not create folder")


def insert_with_unique_name(db: Session, node: Node) -> Node:
    wanted = node.name
    for _ in range(5):
        node.name = unique_name(db, node.parent_id, wanted)
        db.add(node)
        try:
            db.commit()
            return node
        except IntegrityError:
            db.rollback()
    raise HTTPException(409, "Could not pick a unique name")


# ---------------------------------------------------------------- auth


class Credentials(BaseModel):
    username: str
    password: str
    invite_code: str = ""


class PasswordChange(BaseModel):
    current_password: str
    new_password: str


class Preferences(BaseModel):
    # Only the fields that are sent are changed.
    folder_color: str | None = None
    theme: str | None = None


def user_out(db: Session, user: User) -> dict:
    return {
        "id": user.id,
        "username": user.username,
        "root_id": get_root(db, user).id,
        "folder_color": user.folder_color or DEFAULT_FOLDER_COLOR,
        "theme": user.theme or "system",
        "is_admin": user.is_admin,
    }


@router.get("/config")
def public_config(request: Request):
    settings = request.app.state.settings
    return {
        "app_name": settings.app_name,
        "registration_open": settings.registration_open,
        "invite_required": settings.registration_mode == "invite",
        "max_upload_bytes": settings.max_upload_bytes,
    }


@router.post("/auth/register", status_code=201)
def register(body: Credentials, request: Request, response: Response, db: Session = Depends(get_db)):
    settings = request.app.state.settings
    if not settings.registration_open:
        raise HTTPException(403, "Registration is closed")
    if settings.registration_mode == "invite" and not secrets.compare_digest(
        body.invite_code.encode(), settings.invite_code.encode()
    ):
        raise HTTPException(403, "Invalid invite code")
    username = body.username.strip().lower()
    if not USERNAME_RE.match(username):
        raise HTTPException(400, "Username must be 3-32 characters: letters, digits, '.', '_' or '-'")
    if len(body.password) < MIN_PASSWORD_LENGTH:
        raise HTTPException(400, f"Password must be at least {MIN_PASSWORD_LENGTH} characters")
    if db.scalar(select(User.id).where(User.username == username)):
        raise HTTPException(409, "Username is already taken")
    try:
        user = auth.create_user(db, username, body.password)
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "Username is already taken")
    auth.start_session(db, request, response, user)
    return user_out(db, user)


@router.post("/auth/login")
def login(body: Credentials, request: Request, response: Response, db: Session = Depends(get_db)):
    user = db.scalar(select(User).where(User.username == body.username.strip().lower()))
    if user is None or not auth.verify_password(user.password_hash, body.password):
        raise HTTPException(401, "Wrong username or password")
    auth.start_session(db, request, response, user)
    return user_out(db, user)


@router.post("/auth/logout", status_code=204)
def logout(request: Request, response: Response, db: Session = Depends(get_db)):
    auth.end_session(db, request, response)


@router.get("/auth/me")
def me(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return user_out(db, user)


@router.post("/auth/password", status_code=204)
def change_password(body: PasswordChange, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if not auth.verify_password(user.password_hash, body.current_password):
        raise HTTPException(403, "Current password is wrong")
    if len(body.new_password) < MIN_PASSWORD_LENGTH:
        raise HTTPException(400, f"Password must be at least {MIN_PASSWORD_LENGTH} characters")
    user.password_hash = auth.hash_password(body.new_password)
    db.commit()


@router.put("/auth/preferences")
def set_preferences(body: Preferences, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Per-user display preferences: folder icon color and light/dark theme."""
    if body.folder_color is not None:
        if body.folder_color not in FOLDER_COLORS:
            raise HTTPException(400, "Unknown folder color")
        user.folder_color = body.folder_color
    if body.theme is not None:
        if body.theme not in THEMES:
            raise HTTPException(400, "Unknown theme")
        user.theme = body.theme
    db.commit()
    return user_out(db, user)


# ---------------------------------------------------------------- browsing


@router.get("/folders/{folder_id}")
def list_folder(folder_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    folder = get_folder(db, user, folder_id)
    items = db.scalars(select(Node).where(Node.parent_id == folder.id)).all()
    shares = share_modes(db, user)
    return {
        "folder": node_out(folder, share=shares.get(folder.id)),
        "breadcrumb": breadcrumb(db, folder),
        "items": [node_out(n, share=shares.get(n.id)) for n in items],
    }


@router.get("/folders")
def all_folders(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Every folder of the user, for the "Move to" picker."""
    rows = db.execute(
        select(Node.id, Node.parent_id, Node.name).where(Node.user_id == user.id, Node.is_dir)
    ).all()
    return [{"id": r.id, "parent_id": r.parent_id, "name": r.name or ROOT_NAME} for r in rows]


@router.get("/search")
def search(q: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    q = q.strip().lower()
    if not q:
        return []
    pattern = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
    nodes = db.scalars(
        select(Node)
        .where(Node.user_id == user.id, Node.parent_id.is_not(None), func.lower(Node.name).like(pattern, escape="\\"))
        .order_by(Node.is_dir.desc(), Node.name)
        .limit(SEARCH_LIMIT)
    ).all()
    paths = folder_paths(db, user)
    shares = share_modes(db, user)
    return [node_out(n, path=paths[n.parent_id] or "/", share=shares.get(n.id)) for n in nodes]


@router.get("/stats")
def stats(request: Request, user: User = Depends(current_user), db: Session = Depends(get_db)):
    used, count = db.execute(
        select(func.coalesce(func.sum(Node.size), 0), func.count(Node.id)).where(
            Node.user_id == user.id, Node.is_dir.is_(False)
        )
    ).one()
    disk = request.app.state.storage.disk_usage()
    return {
        "used_bytes": int(used),
        "file_count": count,
        "quota_bytes": quotas.quota_of(user, request.app.state.settings),  # None = unlimited
        "disk_free": disk.free,
        "disk_total": disk.total,
    }


# ---------------------------------------------------------------- create


class NewFolder(BaseModel):
    parent_id: int
    name: str


@router.post("/folders", status_code=201)
def create_folder(body: NewFolder, user: User = Depends(current_user), db: Session = Depends(get_db)):
    parent = get_folder(db, user, body.parent_id)
    name = clean_name(body.name)
    if name_taken(db, parent.id, name):
        raise HTTPException(409, f"'{name}' already exists here")
    folder = Node(user_id=user.id, parent_id=parent.id, name=name, is_dir=True)
    db.add(folder)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, f"'{name}' already exists here")
    return node_out(folder)


def _prepare_upload_folder(db: Session, user: User, parent_id: int, relative_dir: str) -> int:
    folder = get_folder(db, user, parent_id)
    for part in relative_dir.split("/"):
        if part.strip():
            folder = get_or_create_folder(db, user, folder, clean_name(part))
    return folder.id


def _finish_upload(
    db: Session, storage: Storage, settings, user: User, parent_id: int, name: str, tmp: Path, size: int,
    for_visitor: bool,
) -> dict:
    # Final quota check. Locking the user's row makes simultaneous uploads by the same
    # user take turns here, so they can't each squeeze in under the limit together.
    # Usage is then read with a locking read, which sees other uploads that finished
    # meanwhile (a plain read in MariaDB's REPEATABLE READ could show an older snapshot).
    user_id = user.id  # read now: after rollback() it would trigger a reload of the user
    db.rollback()
    db.execute(select(User.id).where(User.id == user_id).with_for_update())
    used = quotas.used_bytes(db, user_id, latest=True)
    quotas.check_room(db, settings, user, size, used=used, for_visitor=for_visitor)
    key = storage.new_key()
    final = storage.path_for(user.id, key)
    final.parent.mkdir(parents=True, exist_ok=True)
    os.replace(tmp, final)
    node = Node(
        user_id=user.id, parent_id=parent_id, name=name, is_dir=False,
        size=size, mime_type=guess_mime(name), storage_key=key,
    )
    try:
        insert_with_unique_name(db, node)
    except BaseException:
        final.unlink(missing_ok=True)
        raise
    return node_out(node)


async def receive_upload(
    request: Request, db: Session, owner: User, parent_id: int, name: str, relative_dir: str,
    for_visitor: bool = False,
) -> dict:
    """Stream the request body into a new file owned by `owner` (parent_id must already be authorised).

    The upload counts against the owner's quota, also when a share-link visitor sends it.
    """
    settings = request.app.state.settings
    storage: Storage = request.app.state.storage
    limit = settings.max_upload_bytes
    declared = request.headers.get("content-length")
    declared = int(declared) if declared and declared.isdigit() else None
    if limit and declared and declared > limit:
        raise HTTPException(413, "File is too large")
    name = clean_name(name)

    # Refuse up front if the file can't fit, before any of it is sent.
    used = await run_in_threadpool(quotas.used_bytes, db, owner.id)
    quotas.check_room(db, settings, owner, declared or 0, used=used, for_visitor=for_visitor)
    quota = quotas.quota_of(owner, settings)

    target_id = await run_in_threadpool(_prepare_upload_folder, db, owner, parent_id, relative_dir)

    tmp = storage.temp_path()
    size = 0
    try:
        with open(tmp, "wb") as f:
            async for chunk in request.stream():
                size += len(chunk)
                if limit and size > limit:
                    raise HTTPException(413, "File is too large")
                if quota is not None and used + size > quota:  # no Content-Length, or it was wrong
                    quotas.check_room(db, settings, owner, size, used=used, for_visitor=for_visitor)
                await run_in_threadpool(f.write, chunk)
        return await run_in_threadpool(
            _finish_upload, db, storage, settings, owner, target_id, name, tmp, size, for_visitor
        )
    except ClientDisconnect:
        raise HTTPException(400, "Upload was cancelled")
    finally:
        tmp.unlink(missing_ok=True)


@router.post("/upload", status_code=201)
async def upload(
    request: Request,
    parent_id: int,
    name: str,
    relative_dir: str = "",
    user: User = Depends(current_user),
    db: Session = Depends(get_db),
):
    """Upload one file. The request body is the raw file content.

    relative_dir (e.g. "Photos/2024") creates sub-folders under parent_id,
    which is how folder uploads keep their structure.
    """
    return await receive_upload(request, db, user, parent_id, name, relative_dir)


# ---------------------------------------------------------------- read


INLINE_KINDS = {"pdf", "image", "audio", "video"}


def file_response(storage: Storage, node: Node, download: bool) -> FileResponse:
    if node.is_dir:
        raise HTTPException(400, "Folders can't be downloaded this way")
    path = storage.path_for(node.user_id, node.storage_key)
    if not path.is_file():
        raise HTTPException(404, "File content is missing from storage")

    media_type = node.mime_type or "application/octet-stream"
    kind = file_kind(node.name, node.mime_type)
    disposition = "attachment"
    if not download and kind in INLINE_KINDS:
        disposition = "inline"
    elif not download and kind == "text":
        # Never render uploaded HTML/SVG/JS as a page on our origin.
        disposition, media_type = "inline", "text/plain; charset=utf-8"

    headers = {"X-Content-Type-Options": "nosniff", "Cache-Control": "private, no-cache"}
    if disposition == "inline" and kind != "pdf":
        headers["Content-Security-Policy"] = "sandbox"
    return FileResponse(
        path, media_type=media_type, filename=node.name,
        content_disposition_type=disposition, headers=headers,
    )


@router.get("/files/{file_id}/content")
def file_content(
    file_id: int,
    request: Request,
    download: bool = False,
    user: User = Depends(current_user),
    db: Session = Depends(get_db),
):
    return file_response(request.app.state.storage, get_node(db, user, file_id), download)


def _unique_top_level(name: str, used: set[str]) -> str:
    candidate, n = name, 1
    stem, dot, ext = name.rpartition(".")
    if not stem:
        stem, dot, ext = name, "", ""
    while candidate in used:
        candidate = f"{stem} ({n}){dot}{ext}"
        n += 1
    used.add(candidate)
    return candidate


def attachment_header(filename: str) -> str:
    ascii_name = filename.encode("ascii", "replace").decode().replace('"', "'").replace("?", "_")
    return f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(filename)}"


def zip_response(db: Session, storage: Storage, selected: list[Node], app_name: str) -> StreamingResponse:
    """Stream the selected files and folders (with everything inside them) as one zip."""
    # Load every node beneath the selected folders in one query.
    tree = select(Node.id).where(Node.id.in_([n.id for n in selected if n.is_dir])).cte("tree", recursive=True)
    tree = tree.union_all(select(Node.id).where(Node.parent_id == tree.c.id))
    children: dict[int, list[Node]] = {}
    for node in db.scalars(select(Node).where(Node.id.in_(select(tree.c.id)))):
        children.setdefault(node.parent_id, []).append(node)

    entries: list[ZipEntry] = []

    def add(node: Node, path: str) -> None:
        if node.is_dir:
            entries.append(ZipEntry(path + "/", None, 0, node.updated_at))
            for child in sorted(children.get(node.id, []), key=lambda n: n.name):
                add(child, f"{path}/{child.name}")
        else:
            entries.append(ZipEntry(path, storage.path_for(node.user_id, node.storage_key), node.size, node.updated_at))

    used: set[str] = set()
    for node in selected:
        add(node, _unique_top_level(node.name or ROOT_NAME, used))

    if len(selected) == 1:
        zip_name = f"{selected[0].name or ROOT_NAME}.zip"
    else:
        zip_name = f"{app_name} download.zip"
    return StreamingResponse(
        stream_zip(entries),
        media_type="application/zip",
        headers={"Content-Disposition": attachment_header(zip_name), "Cache-Control": "no-store"},
    )


@router.get("/zip")
def download_zip(
    request: Request,
    ids: list[int] = Query(),
    user: User = Depends(current_user),
    db: Session = Depends(get_db),
):
    """Download files and folders (with everything inside them) as one zip."""
    selected = [get_node(db, user, i) for i in dict.fromkeys(ids)]
    return zip_response(db, request.app.state.storage, selected, request.app.state.settings.app_name)


# ---------------------------------------------------------------- update


class Rename(BaseModel):
    name: str


class Move(BaseModel):
    ids: list[int]
    target_id: int


class DeleteMany(BaseModel):
    ids: list[int]


@router.patch("/nodes/{node_id}")
def rename(node_id: int, body: Rename, user: User = Depends(current_user), db: Session = Depends(get_db)):
    node = get_node(db, user, node_id)
    if node.parent_id is None:
        raise HTTPException(400, "The root folder can't be renamed")
    name = clean_name(body.name)
    if name != node.name:
        if name_taken(db, node.parent_id, name):
            raise HTTPException(409, f"'{name}' already exists here")
        node.name = name
        if not node.is_dir:
            node.mime_type = guess_mime(name)
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            raise HTTPException(409, f"'{name}' already exists here")
    return node_out(node)


@router.post("/nodes/move")
def move(body: Move, user: User = Depends(current_user), db: Session = Depends(get_db)):
    target = get_folder(db, user, body.target_id)
    nodes = [get_node(db, user, i) for i in dict.fromkeys(body.ids)]

    # A folder can't be moved into itself or one of its own sub-folders.
    moving = {n.id for n in nodes}
    ancestor: Node | None = target
    while ancestor is not None:
        if ancestor.id in moving:
            raise HTTPException(400, "A folder can't be moved into itself")
        ancestor = db.get(Node, ancestor.parent_id) if ancestor.parent_id else None

    names = set()
    for node in nodes:
        if node.parent_id is None:
            raise HTTPException(400, "The root folder can't be moved")
        if node.parent_id == target.id:
            continue
        if node.name in names or name_taken(db, target.id, node.name):
            raise HTTPException(409, f"'{node.name}' already exists in the destination")
        names.add(node.name)
    for node in nodes:
        node.parent_id = target.id
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "An item with the same name already exists in the destination")
    return {"moved": len(nodes)}


@router.post("/nodes/delete")
def delete_nodes(body: DeleteMany, request: Request, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if not body.ids:
        return {"deleted": 0}
    rows = subtree(db, user, body.ids)
    # Delete deepest rows first so no row outlives its parent.
    by_depth: dict[int, list[int]] = {}
    for node_id, _, depth in rows:
        by_depth.setdefault(depth, []).append(node_id)
    db.execute(delete(Share).where(Share.node_id.in_([node_id for node_id, _, _ in rows])))
    for depth in sorted(by_depth, reverse=True):
        db.execute(delete(Node).where(Node.id.in_(by_depth[depth])))
    db.commit()
    storage: Storage = request.app.state.storage
    for _, key, _ in rows:
        if key:
            storage.delete(user.id, key)
    return {"deleted": len(rows)}
