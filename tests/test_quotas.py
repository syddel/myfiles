import pytest
from sqlalchemy import inspect, text

from myfiles import quotas
from myfiles.models import User, create_schema, make_engine
from tests.conftest import make_client
from tests.test_files import listing, upload
from tests.test_shares import anon

KB = 1024


@pytest.fixture
def small_default(settings):
    settings.default_quota_gb = 10 * KB / quotas.GB  # a 10 KB default quota, to keep tests fast
    return settings


def make_admin(settings, username):
    from myfiles.models import make_sessionmaker
    engine = make_engine(settings)
    with make_sessionmaker(engine)() as db:
        db.query(User).filter(User.username == username).update({"is_admin": True})
        db.commit()
    engine.dispose()


def test_parse_size():
    assert quotas.parse_size("50") == 50 * quotas.GB
    assert quotas.parse_size("50GB") == 50 * quotas.GB
    assert quotas.parse_size("500 mb") == 500 * 1024**2
    assert quotas.parse_size("1.5TB") == int(1.5 * 1024**4)
    assert quotas.parse_size("2GiB") == 2 * quotas.GB
    for bad in ("", "lots", "5 parsecs", "-3GB"):
        with pytest.raises(ValueError):
            quotas.parse_size(bad)


def test_default_quota_is_15_gb(client, user):
    assert client.get("/api/stats").json()["quota_bytes"] == 15 * quotas.GB


def test_upload_refused_over_quota(small_default, tmp_path):
    client = make_client(small_default)
    root = client.post("/api/auth/register", json={"username": "alice", "password": "12345678"}).json()["root_id"]
    upload(client, root, "a.bin", b"x" * (6 * KB))
    stats = client.get("/api/stats").json()
    assert (stats["used_bytes"], stats["quota_bytes"]) == (6 * KB, 10 * KB)

    r = client.post("/api/upload", params={"parent_id": root, "name": "b.bin"}, content=b"x" * (5 * KB))
    assert r.status_code == 413
    assert "Not enough space" in r.json()["detail"] and "4 KB" in r.json()["detail"]
    assert set(listing(client, root)) == {"a.bin"}
    assert not any((small_default.storage_path / "tmp").iterdir())  # nothing left behind

    upload(client, root, "c.bin", b"x" * (4 * KB))  # exactly fills it
    r = client.post("/api/upload", params={"parent_id": root, "name": "d.bin"}, content=b"x")
    assert r.status_code == 413
    # Deleting frees space again.
    a = listing(client, root)["a.bin"]
    client.post("/api/nodes/delete", json={"ids": [a["id"]]})
    upload(client, root, "d.bin", b"x" * KB)


def test_quota_checked_without_content_length(small_default):
    client = make_client(small_default)
    root = client.post("/api/auth/register", json={"username": "alice", "password": "12345678"}).json()["root_id"]

    def chunks():  # streamed body: no Content-Length up front
        for _ in range(20):
            yield b"x" * KB

    r = client.post("/api/upload", params={"parent_id": root, "name": "big.bin"}, content=chunks())
    assert r.status_code == 413
    assert listing(client, root) == {}
    assert not any((small_default.storage_path / "tmp").iterdir())


def test_share_uploads_count_against_owner(small_default):
    client = make_client(small_default)
    root = client.post("/api/auth/register", json={"username": "alice", "password": "12345678"}).json()["root_id"]
    folder = client.post("/api/folders", json={"parent_id": root, "name": "Drop"}).json()
    token = client.put(f"/api/shares/{folder['id']}", json={"mode": "readwrite"}).json()["token"]
    visitor = anon(small_default)
    r = visitor.post(f"/api/s/{token}/upload", params={"parent_id": folder["id"], "name": "v.bin"}, content=b"x" * (8 * KB))
    assert r.status_code == 201
    assert client.get("/api/stats").json()["used_bytes"] == 8 * KB
    r = visitor.post(f"/api/s/{token}/upload", params={"parent_id": folder["id"], "name": "w.bin"}, content=b"x" * (8 * KB))
    assert r.status_code == 413
    # Visitors aren't told anything about the owner's quota.
    assert r.json()["detail"] == "There isn't enough space left in this shared folder"


def test_admin_quota_management(small_default):
    admin = make_client(small_default)
    admin.post("/api/auth/register", json={"username": "boss", "password": "12345678"})
    user = make_client(small_default)
    alice_root = user.post("/api/auth/register", json={"username": "alice", "password": "12345678"}).json()["root_id"]
    upload(user, alice_root, "a.bin", b"x" * (3 * KB))

    # Not an admin yet: no access.
    assert admin.get("/api/admin/users").status_code == 403
    make_admin(small_default, "boss")
    assert admin.get("/api/auth/me").json()["is_admin"] is True
    assert user.get("/api/auth/me").json()["is_admin"] is False
    assert user.get("/api/admin/users").status_code == 403
    assert anon(small_default).get("/api/admin/users").status_code == 401

    data = admin.get("/api/admin/users").json()
    assert data["default_quota_bytes"] == 10 * KB
    alice = {u["username"]: u for u in data["users"]}["alice"]
    assert (alice["used_bytes"], alice["file_count"], alice["quota_mode"], alice["quota_bytes"]) == (3 * KB, 1, "default", 10 * KB)

    # Custom quota (in GB): 1 GB lets her upload more than the 10 KB default.
    r = admin.put(f"/api/admin/users/{alice['id']}/quota", json={"mode": "custom", "gb": 1}).json()
    assert (r["quota_mode"], r["quota_bytes"]) == ("custom", quotas.GB)
    upload(user, alice_root, "b.bin", b"x" * (20 * KB))
    assert user.get("/api/stats").json()["quota_bytes"] == quotas.GB

    # Unlimited, then back to default (she's now over it: kept files, no new uploads).
    assert admin.put(f"/api/admin/users/{alice['id']}/quota", json={"mode": "unlimited"}).json()["quota_bytes"] is None
    assert user.get("/api/stats").json()["quota_bytes"] is None
    admin.put(f"/api/admin/users/{alice['id']}/quota", json={"mode": "default"})
    r = user.post("/api/upload", params={"parent_id": alice_root, "name": "c.bin"}, content=b"x")
    assert r.status_code == 413
    assert set(listing(user, alice_root)) == {"a.bin", "b.bin"}

    assert admin.put(f"/api/admin/users/{alice['id']}/quota", json={"mode": "custom"}).status_code == 400
    assert admin.put(f"/api/admin/users/{alice['id']}/quota", json={"mode": "custom", "gb": -5}).status_code == 400
    assert admin.put("/api/admin/users/99999/quota", json={"mode": "default"}).status_code == 404
    assert user.put(f"/api/admin/users/{alice['id']}/quota", json={"mode": "unlimited"}).status_code == 403


def test_unlimited_default(settings):
    settings.default_quota_gb = 0
    client = make_client(settings)
    client.post("/api/auth/register", json={"username": "alice", "password": "12345678"})
    assert client.get("/api/stats").json()["quota_bytes"] is None


def test_existing_database_gets_quota_columns(settings):
    engine = make_engine(settings)
    with engine.begin() as conn:
        conn.execute(text("CREATE TABLE users (id INTEGER PRIMARY KEY, username VARCHAR(32), "
                          "password_hash VARCHAR(255), created_at DATETIME)"))
        conn.execute(text("INSERT INTO users (id, username, password_hash, created_at) "
                          "VALUES (1, 'old', 'x', '2026-01-01 00:00:00')"))
    create_schema(engine)
    assert {"quota_bytes", "is_admin"} <= {c["name"] for c in inspect(engine).get_columns("users")}
    with engine.connect() as conn:
        # Existing users get the default quota and aren't admins.
        assert conn.execute(text("SELECT quota_bytes, is_admin FROM users")).one() == (None, 0)
    engine.dispose()


def test_latest_usage_sees_other_transactions(client, user, settings):
    """The final quota check must see uploads that another request committed meanwhile, even
    after this transaction already read usage (MariaDB REPEATABLE READ keeps a snapshot)."""
    from myfiles.models import Node, make_sessionmaker

    engine = make_engine(settings)
    Session = make_sessionmaker(engine)
    with Session() as mine, Session() as other:
        uid = mine.scalar(text("SELECT id FROM users WHERE username = 'alice'"))
        assert quotas.used_bytes(mine, uid) == 0  # starts this transaction's snapshot
        other.add(Node(user_id=uid, parent_id=user["root_id"], name="x.bin", is_dir=False, size=500))
        other.commit()
        assert quotas.used_bytes(mine, uid, latest=True) == 500
        mine.rollback()
    engine.dispose()
