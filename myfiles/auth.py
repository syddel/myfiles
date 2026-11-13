"""Password hashing, sessions and request dependencies."""

import hashlib
import secrets
from datetime import timedelta
from typing import Iterator

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import Depends, HTTPException, Request, Response
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from .models import AuthSession, Node, User, utcnow

COOKIE_NAME = "myfiles_session"
_hasher = PasswordHasher()


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _hasher.verify(password_hash, password)
    except (VerificationError, InvalidHashError):
        return False


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def get_db(request: Request) -> Iterator[Session]:
    db = request.app.state.SessionLocal()
    try:
        yield db
    finally:
        db.close()


def create_user(db: Session, username: str, password: str) -> User:
    """Create a user and their root folder."""
    user = User(username=username.lower(), password_hash=hash_password(password))
    db.add(user)
    db.flush()
    db.add(Node(user_id=user.id, parent_id=None, name="", is_dir=True))
    db.commit()
    return user


def start_session(db: Session, request: Request, response: Response, user: User) -> None:
    settings = request.app.state.settings
    now = utcnow()
    db.execute(delete(AuthSession).where(AuthSession.expires_at < now))
    token = secrets.token_urlsafe(32)
    lifetime = timedelta(days=settings.session_lifetime_days)
    db.add(AuthSession(token_hash=_token_hash(token), user_id=user.id, expires_at=now + lifetime))
    db.commit()
    response.set_cookie(
        COOKIE_NAME,
        token,
        max_age=int(lifetime.total_seconds()),
        httponly=True,
        samesite="lax",
        secure=cookie_secure(request),
        path="/",
    )


def cookie_secure(request: Request) -> bool:
    """Whether cookies get the Secure flag (COOKIE_SECURE; "auto" = when the request came over HTTPS)."""
    setting = request.app.state.settings.cookie_secure
    if setting == "auto":
        return request.url.scheme == "https"
    return setting == "true"


def end_session(db: Session, request: Request, response: Response) -> None:
    token = request.cookies.get(COOKIE_NAME)
    if token:
        db.execute(delete(AuthSession).where(AuthSession.token_hash == _token_hash(token)))
        db.commit()
    response.delete_cookie(COOKIE_NAME, path="/")


def current_user(request: Request, db: Session = Depends(get_db)) -> User:
    token = request.cookies.get(COOKIE_NAME)
    if token:
        user = db.scalar(
            select(User)
            .join(AuthSession, AuthSession.user_id == User.id)
            .where(AuthSession.token_hash == _token_hash(token), AuthSession.expires_at > utcnow())
        )
        if user:
            return user
    raise HTTPException(401, "Not signed in")


def require_admin(user: User = Depends(current_user)) -> User:
    if not user.is_admin:
        raise HTTPException(403, "Only administrators can do this")
    return user
