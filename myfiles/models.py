"""Database models and engine setup."""

from datetime import datetime, timezone

from sqlalchemy import BigInteger, DateTime, ForeignKey, Index, String, create_engine, inspect, text
from sqlalchemy.dialects import mysql
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker

from .config import Settings

TABLE_ARGS = {"mysql_engine": "InnoDB", "mysql_charset": "utf8mb4"}

# File names are compared exactly (case- and accent-sensitive), like on Linux.
FileName = String(255).with_variant(mysql.VARCHAR(255, collation="utf8mb4_bin"), "mysql", "mariadb")


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    __table_args__ = TABLE_ARGS

    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(32), unique=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    folder_color: Mapped[str | None] = mapped_column(String(16))  # one of FOLDER_COLORS; None = default
    theme: Mapped[str | None] = mapped_column(String(8))  # "system", "light" or "dark"; None = "system"
    # Storage quota in bytes: None = DEFAULT_QUOTA_GB from .env, -1 = unlimited (see quotas.py).
    quota_bytes: Mapped[int | None] = mapped_column(BigInteger)
    is_admin: Mapped[bool] = mapped_column(default=False, server_default=text("0"))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class AuthSession(Base):
    __tablename__ = "sessions"
    __table_args__ = TABLE_ARGS

    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime, index=True)


class Node(Base):
    """A file or folder. Each user has one root folder (parent_id NULL)."""

    __tablename__ = "nodes"
    __table_args__ = (
        Index("ux_nodes_parent_name", "parent_id", "name", unique=True),
        Index("ix_nodes_user_parent", "user_id", "parent_id"),
        TABLE_ARGS,
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    parent_id: Mapped[int | None] = mapped_column(ForeignKey("nodes.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(FileName)
    is_dir: Mapped[bool] = mapped_column(default=False)
    size: Mapped[int] = mapped_column(BigInteger, default=0)
    mime_type: Mapped[str | None] = mapped_column(String(255))
    storage_key: Mapped[str | None] = mapped_column(String(32))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, onupdate=utcnow)


class Share(Base):
    """A folder or file shared with anyone who has the link. One share per item."""

    __tablename__ = "shares"
    __table_args__ = TABLE_ARGS

    id: Mapped[int] = mapped_column(primary_key=True)
    token: Mapped[str] = mapped_column(String(64), unique=True)
    node_id: Mapped[int] = mapped_column(ForeignKey("nodes.id", ondelete="CASCADE"), unique=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    mode: Mapped[str] = mapped_column(String(16))  # "read" or "readwrite"
    password_hash: Mapped[str | None] = mapped_column(String(255))  # argon2; None = no password
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


# Columns added after their table was first released: (table, column, SQL type).
# create_all() only creates missing tables, so existing databases get these via ALTER TABLE.
ADDED_COLUMNS = [
    ("shares", "password_hash", "VARCHAR(255) NULL"),
    ("users", "folder_color", "VARCHAR(16) NULL"),
    ("users", "theme", "VARCHAR(8) NULL"),
    ("users", "quota_bytes", "BIGINT NULL"),
    ("users", "is_admin", "BOOLEAN NOT NULL DEFAULT 0"),
]


def create_schema(engine: Engine) -> None:
    """Create missing tables, then add any columns that newer versions introduced."""
    Base.metadata.create_all(engine)
    inspector = inspect(engine)
    for table, column, sql_type in ADDED_COLUMNS:
        if column not in {c["name"] for c in inspector.get_columns(table)}:
            with engine.begin() as conn:
                conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {column} {sql_type}"))


def make_engine(settings: Settings) -> Engine:
    url = settings.sqlalchemy_url
    if str(url).startswith("sqlite"):
        return create_engine(url, connect_args={"check_same_thread": False})
    # pool_recycle stays under MariaDB's default wait_timeout (8h).
    return create_engine(url, pool_pre_ping=True, pool_recycle=3600)


def make_sessionmaker(engine: Engine) -> sessionmaker:
    return sessionmaker(bind=engine, expire_on_commit=False)
