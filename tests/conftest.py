import os

import pytest
from fastapi.testclient import TestClient

from myfiles.app import create_app
from myfiles.config import Settings
from myfiles.models import Base, make_engine

# e.g. TEST_DATABASE_URL="mariadb+pymysql://myfiles:pass@localhost/myfiles_test?charset=utf8mb4"
TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL", "")


@pytest.fixture
def settings(tmp_path):
    url = TEST_DATABASE_URL or f"sqlite:///{tmp_path / 'test.db'}"
    s = Settings(
        _env_file=None,
        storage_path=tmp_path / "storage",
        database_url=url,
        registration_mode="open",
        static_path=tmp_path / "no-frontend",
    )
    engine = make_engine(s)
    Base.metadata.drop_all(engine)
    engine.dispose()
    return s


def make_client(settings) -> TestClient:
    client = TestClient(create_app(settings))
    client.headers["X-Requested-With"] = "myfiles"
    return client


@pytest.fixture
def client(settings):
    return make_client(settings)


@pytest.fixture
def user(client):
    r = client.post("/api/auth/register", json={"username": "alice", "password": "correct horse"})
    assert r.status_code == 201, r.text
    return r.json()
