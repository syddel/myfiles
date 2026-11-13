"""Admin endpoints under /api/admin (admin accounts only)."""

from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from . import quotas
from .auth import get_db, require_admin
from .models import Node, User

router = APIRouter(prefix="/admin")


def admin_user_out(user: User, used: int, files: int, settings) -> dict:
    return {
        "id": user.id,
        "username": user.username,
        "is_admin": user.is_admin,
        "created_at": user.created_at.isoformat() + "Z",
        "file_count": files,
        "used_bytes": used,
        "quota_mode": quotas.quota_mode(user),  # default | custom | unlimited
        "quota_bytes": quotas.quota_of(user, settings),  # effective quota; None = unlimited
    }


def _usage(db: Session) -> dict[int, tuple[int, int]]:
    """user id -> (bytes used, number of files)"""
    rows = db.execute(
        select(Node.user_id, func.coalesce(func.sum(Node.size), 0), func.count(Node.id))
        .where(Node.is_dir.is_(False))
        .group_by(Node.user_id)
    ).all()
    return {user_id: (int(used), files) for user_id, used, files in rows}


@router.get("/users")
def list_users(request: Request, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    settings = request.app.state.settings
    usage = _usage(db)
    users = db.scalars(select(User).order_by(User.username)).all()
    return {
        "default_quota_bytes": quotas.default_quota(settings),
        "users": [admin_user_out(u, *usage.get(u.id, (0, 0)), settings) for u in users],
    }


class QuotaChange(BaseModel):
    mode: Literal["default", "custom", "unlimited"]
    gb: float | None = None  # required for "custom"


@router.put("/users/{user_id}/quota")
def set_quota(
    user_id: int, body: QuotaChange, request: Request,
    admin: User = Depends(require_admin), db: Session = Depends(get_db),
):
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(404, "No such user")
    if body.mode == "default":
        user.quota_bytes = None
    elif body.mode == "unlimited":
        user.quota_bytes = quotas.UNLIMITED
    else:
        if body.gb is None or not 0 < body.gb <= 1_000_000:
            raise HTTPException(400, "Enter a quota in GB, greater than 0")
        user.quota_bytes = int(body.gb * quotas.GB)
    db.commit()
    used, files = _usage(db).get(user.id, (0, 0))
    return admin_user_out(user, used, files, request.app.state.settings)
