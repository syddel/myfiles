from sqlalchemy import inspect, text

from myfiles.models import create_schema, make_engine
from myfiles.shares import MAX_FAILED_UNLOCKS, failed_unlocks
from tests.test_files import listing
from tests.test_shares import anon, setup_tree


def protect(client, node_id, password, mode="read"):
    client.put(f"/api/shares/{node_id}", json={"mode": mode})
    r = client.put(f"/api/shares/{node_id}/password", json={"password": password})
    assert r.status_code == 200, r.text
    return r.json()


def test_password_protected_folder(client, user, settings):
    photos, _ = setup_tree(client, user)
    share = protect(client, photos["id"], "letmein", mode="readwrite")
    assert share["has_password"] is True
    token = share["token"]
    a = listing(client, photos["id"])["a.jpg"]

    visitor = anon(settings)
    # Locked: nothing about the folder is revealed and nothing is reachable.
    assert visitor.get(f"/api/s/{token}").json() == {"locked": True, "app_name": "MyFiles"}
    assert visitor.get(f"/api/s/{token}/folders/{photos['id']}").status_code == 401
    assert visitor.get(f"/api/s/{token}/files/{a['id']}/content").status_code == 401
    assert visitor.get(f"/api/s/{token}/zip", params={"ids": photos["id"]}).status_code == 401
    r = visitor.post(f"/api/s/{token}/upload", params={"parent_id": photos["id"], "name": "x"}, content=b"x")
    assert r.status_code == 401

    assert visitor.post(f"/api/s/{token}/unlock", json={"password": "wrong"}).status_code == 403
    r = visitor.post(f"/api/s/{token}/unlock", json={"password": "letmein"})
    assert r.status_code == 204
    assert "httponly" in r.headers["set-cookie"].lower()

    info = visitor.get(f"/api/s/{token}").json()
    assert info["locked"] is False and info["name"] == "Photos"
    assert visitor.get(f"/api/s/{token}/files/{a['id']}/content").content == b"A"
    r = visitor.post(f"/api/s/{token}/upload", params={"parent_id": photos["id"], "name": "x.txt"}, content=b"x")
    assert r.status_code == 201

    # Another visitor still needs the password.
    assert anon(settings).get(f"/api/s/{token}/files/{a['id']}/content").status_code == 401


def test_password_protected_file(client, user, settings):
    photos, _ = setup_tree(client, user)
    a = listing(client, photos["id"])["a.jpg"]
    token = protect(client, a["id"], "secret1")["token"]
    visitor = anon(settings)
    assert visitor.get(f"/api/s/{token}").json()["locked"] is True
    assert visitor.get(f"/api/s/{token}/files/{a['id']}/content").status_code == 401
    visitor.post(f"/api/s/{token}/unlock", json={"password": "secret1"})
    assert visitor.get(f"/api/s/{token}").json()["name"] == "a.jpg"
    assert visitor.get(f"/api/s/{token}/files/{a['id']}/content").content == b"A"


def test_unlock_cookie_only_opens_its_own_link(client, user, settings):
    photos, private = setup_tree(client, user)
    t1 = protect(client, photos["id"], "same-pass")["token"]
    t2 = protect(client, private["id"], "same-pass")["token"]
    visitor = anon(settings)
    visitor.post(f"/api/s/{t1}/unlock", json={"password": "same-pass"})
    assert visitor.get(f"/api/s/{t1}").json()["locked"] is False
    assert visitor.get(f"/api/s/{t2}").json()["locked"] is True


def test_changing_or_removing_password(client, user, settings):
    photos, _ = setup_tree(client, user)
    token = protect(client, photos["id"], "first")["token"]
    visitor = anon(settings)
    visitor.post(f"/api/s/{token}/unlock", json={"password": "first"})
    assert visitor.get(f"/api/s/{token}").json()["locked"] is False

    # A new password locks out everyone who unlocked with the old one.
    protect(client, photos["id"], "second")
    assert visitor.get(f"/api/s/{token}").json()["locked"] is True
    assert visitor.post(f"/api/s/{token}/unlock", json={"password": "first"}).status_code == 403
    assert visitor.post(f"/api/s/{token}/unlock", json={"password": "second"}).status_code == 204
    assert visitor.get(f"/api/s/{token}").json()["locked"] is False

    # Removing it opens the link to anyone again; the link itself doesn't change.
    r = client.put(f"/api/shares/{photos['id']}/password", json={"password": None}).json()
    assert r["has_password"] is False and r["token"] == token
    assert anon(settings).get(f"/api/s/{token}").json()["locked"] is False
    # Changing the mode keeps the password.
    protect(client, photos["id"], "third")
    assert client.put(f"/api/shares/{photos['id']}", json={"mode": "readwrite"}).json()["has_password"] is True


def test_share_password_validation(client, user, settings):
    photos, private = setup_tree(client, user)
    assert client.put(f"/api/shares/{photos['id']}/password", json={"password": "abc"}).status_code == 404  # not shared
    client.put(f"/api/shares/{photos['id']}", json={"mode": "read"})
    assert client.put(f"/api/shares/{photos['id']}/password", json={"password": "abc"}).status_code == 400
    assert anon(settings).put(f"/api/shares/{photos['id']}/password", json={"password": "abcd"}).status_code == 401


def test_too_many_wrong_passwords(client, user, settings):
    photos, _ = setup_tree(client, user)
    token = protect(client, photos["id"], "right-one")["token"]
    visitor = anon(settings)
    try:
        for _ in range(MAX_FAILED_UNLOCKS):
            assert visitor.post(f"/api/s/{token}/unlock", json={"password": "nope"}).status_code == 403
        # Even the right password is refused until the wait is over.
        assert visitor.post(f"/api/s/{token}/unlock", json={"password": "right-one"}).status_code == 429
    finally:
        failed_unlocks._failures.clear()


def test_existing_database_gets_password_column(settings):
    engine = make_engine(settings)
    with engine.begin() as conn:
        # The shares table as it was before share passwords existed.
        conn.execute(text("CREATE TABLE shares (id INTEGER PRIMARY KEY, token VARCHAR(64), node_id INTEGER, "
                          "user_id INTEGER, mode VARCHAR(16), created_at DATETIME)"))
    create_schema(engine)
    assert "password_hash" in {c["name"] for c in inspect(engine).get_columns("shares")}
    create_schema(engine)  # running it again is harmless
    engine.dispose()
