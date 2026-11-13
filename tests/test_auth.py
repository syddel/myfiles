from tests.conftest import make_client


def test_register_login_logout(client):
    r = client.post("/api/auth/register", json={"username": "Bob", "password": "hunter22!"})
    assert r.status_code == 201
    assert r.json()["username"] == "bob"
    assert client.get("/api/auth/me").json()["username"] == "bob"

    assert client.post("/api/auth/logout").status_code == 204
    assert client.get("/api/auth/me").status_code == 401

    assert client.post("/api/auth/login", json={"username": "bob", "password": "nope"}).status_code == 401
    assert client.post("/api/auth/login", json={"username": "BOB", "password": "hunter22!"}).status_code == 200
    assert client.get("/api/auth/me").status_code == 200


def test_register_validation(client, user):
    assert client.post("/api/auth/register", json={"username": "alice", "password": "12345678"}).status_code == 409
    assert client.post("/api/auth/register", json={"username": "x", "password": "12345678"}).status_code == 400
    assert client.post("/api/auth/register", json={"username": "carol", "password": "short"}).status_code == 400


def test_invite_and_closed_modes(settings):
    settings.registration_mode = "invite"
    settings.invite_code = "secret"
    client = make_client(settings)
    body = {"username": "dave", "password": "12345678"}
    assert client.get("/api/config").json()["invite_required"] is True
    assert client.post("/api/auth/register", json=body).status_code == 403
    assert client.post("/api/auth/register", json={**body, "invite_code": "secret"}).status_code == 201

    settings.registration_mode = "closed"
    assert client.get("/api/config").json()["registration_open"] is False
    assert client.post("/api/auth/register", json={**body, "username": "erin"}).status_code == 403


def test_change_password(client, user):
    r = client.post("/api/auth/password", json={"current_password": "wrong", "new_password": "newpassword"})
    assert r.status_code == 403
    r = client.post("/api/auth/password", json={"current_password": "correct horse", "new_password": "newpassword"})
    assert r.status_code == 204
    assert client.post("/api/auth/login", json={"username": "alice", "password": "newpassword"}).status_code == 200


def test_mutations_require_ajax_header(client, user):
    r = client.post("/api/folders", json={"parent_id": user["root_id"], "name": "x"},
                    headers={"X-Requested-With": ""})
    assert r.status_code == 403


def test_folder_color_preference(client, user, settings):
    assert user["folder_color"] == "amber"  # default
    r = client.put("/api/auth/preferences", json={"folder_color": "green"})
    assert r.status_code == 200 and r.json()["folder_color"] == "green"
    assert client.get("/api/auth/me").json()["folder_color"] == "green"
    assert client.post("/api/auth/login", json={"username": "alice", "password": "correct horse"}).json()["folder_color"] == "green"
    assert client.put("/api/auth/preferences", json={"folder_color": "chartreuse"}).status_code == 400
    for color in ("charcoal", "fuchsia", "lime", "brown"):
        assert client.put("/api/auth/preferences", json={"folder_color": color}).json()["folder_color"] == color
    client.put("/api/auth/preferences", json={"folder_color": "green"})

    # It's per user: someone else still has the default.
    other = make_client(settings)
    bob = other.post("/api/auth/register", json={"username": "bob", "password": "12345678"}).json()
    assert bob["folder_color"] == "amber"
    assert client.get("/api/auth/me").json()["folder_color"] == "green"


def test_existing_database_gets_folder_color_column(settings):
    from sqlalchemy import inspect, text

    from myfiles.models import create_schema, make_engine

    engine = make_engine(settings)
    with engine.begin() as conn:
        # The users table as it was before folder colors existed.
        conn.execute(text("CREATE TABLE users (id INTEGER PRIMARY KEY, username VARCHAR(32), "
                          "password_hash VARCHAR(255), created_at DATETIME)"))
    create_schema(engine)
    assert {"folder_color", "theme"} <= {c["name"] for c in inspect(engine).get_columns("users")}
    engine.dispose()


def test_theme_preference(client, user):
    assert user["theme"] == "system"  # default: follow the device
    r = client.put("/api/auth/preferences", json={"theme": "dark"}).json()
    assert r["theme"] == "dark" and r["folder_color"] == "amber"  # other preferences untouched
    client.put("/api/auth/preferences", json={"folder_color": "blue"})
    me = client.get("/api/auth/me").json()
    assert (me["theme"], me["folder_color"]) == ("dark", "blue")
    assert client.put("/api/auth/preferences", json={"theme": "sepia"}).status_code == 400
    assert client.put("/api/auth/preferences", json={"theme": "light"}).json()["theme"] == "light"
