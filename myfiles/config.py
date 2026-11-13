"""Settings, loaded from environment variables and the .env file."""

import os
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import URL

ENV_FILE = os.environ.get("MYFILES_ENV_FILE", ".env")


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=ENV_FILE, env_file_encoding="utf-8", extra="ignore")

    # Where uploaded files are kept.
    storage_path: Path

    # MariaDB connection.
    db_host: str = "localhost"
    db_port: int = 3306
    db_name: str = "myfiles"
    db_user: str = "myfiles"
    db_password: str = ""
    db_socket: str = ""  # e.g. /run/mysqld/mysqld.sock; overrides host/port when set
    database_url: str = ""  # full SQLAlchemy URL; overrides all DB_* settings when set

    # Name shown on the login screen, in the header and in the browser tab.
    app_name: str = "MyFiles"

    # Public address of the site, used to build share links,
    # e.g. https://myfiles.example.com or https://example.com/files
    base_url: str = ""

    # HTTP server.
    host: str = "127.0.0.1"
    port: int = 8000
    trusted_proxies: str = "127.0.0.1"

    # Accounts and sessions.
    registration_mode: Literal["open", "invite", "closed"] = "invite"
    invite_code: str = ""
    session_lifetime_days: int = 30
    cookie_secure: Literal["auto", "true", "false"] = "auto"

    # Uploads (0 = unlimited).
    max_upload_size_mb: int = 0

    # Storage quota for users who don't have their own (GB; 0 = unlimited).
    default_quota_gb: float = 15

    # Built frontend.
    static_path: Path = Path(__file__).resolve().parent.parent / "frontend" / "dist"

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_size_mb * 1024 * 1024

    @property
    def sqlalchemy_url(self) -> str | URL:
        if self.database_url:
            return self.database_url
        query = {"charset": "utf8mb4"}
        if self.db_socket:
            query["unix_socket"] = self.db_socket
        return URL.create(
            "mariadb+pymysql",
            username=self.db_user,
            password=self.db_password,
            host=None if self.db_socket else self.db_host,
            port=None if self.db_socket else self.db_port,
            database=self.db_name,
            query=query,
        )

    @property
    def registration_open(self) -> bool:
        if self.registration_mode == "invite":
            return bool(self.invite_code)
        return self.registration_mode == "open"


@lru_cache
def get_settings() -> Settings:
    return Settings()
