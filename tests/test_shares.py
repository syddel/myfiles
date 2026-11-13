import io
import zipfile

from fastapi.testclient import TestClient

from myfiles.app import create_app
from tests.conftest import make_client
from tests.test_files import listing, upload


def setup_tree(client, user):
    """Photos/{a.jpg, 2024/b.jpg}, Private/secret.txt"""
    root = user["root_id"]
    upload(client, root, "a.jpg", b"A", relative_dir="Photos")
    upload(client, root, "b.jpg", b"B", relative_dir="Photos/2024")
    upload(client, root, "secret.txt", b"S", relative_dir="Private")
    items = listing(client, root)
    return items["Photos"], items["Private"]


def anon(settings) -> TestClient:
    """A visitor who isn't signed in."""
    c = TestClient(create_app(settings))
    c.headers["X-Requested-With"] = "myfiles"
    return c


def test_share_lifecycle(client, user, settings):
    photos, _ = setup_tree(client, user)
    assert client.get(f"/api/shares/{photos['id']}").json() is None

    share = client.put(f"/api/shares/{photos['id']}", json={"mode": "read"}).json()
    assert share["mode"] == "read" and len(share["token"]) == 32 and share["path"] == "/Photos"
    assert share["url"] is None  # BASE_URL not set

    # Changing the mode keeps the same link.
    again = client.put(f"/api/shares/{photos['id']}", json={"mode": "readwrite"}).json()
    assert again["token"] == share["token"] and again["mode"] == "readwrite"

    assert listing(client, user["root_id"])["Photos"]["share"] == "readwrite"
    assert [s["name"] for s in client.get("/api/shares").json()] == ["Photos"]

    assert client.delete(f"/api/shares/{photos['id']}").status_code == 204
    assert client.get("/api/shares").json() == []
    assert anon(settings).get(f"/api/s/{share['token']}").status_code == 404
    # Sharing again makes a new link.
    assert client.put(f"/api/shares/{photos['id']}", json={"mode": "read"}).json()["token"] != share["token"]


def test_share_url_uses_base_url(settings):
    settings.base_url = "https://files.example.com/"
    client = make_client(settings)
    user = client.post("/api/auth/register", json={"username": "alice", "password": "12345678"}).json()
    folder = client.post("/api/folders", json={"parent_id": user["root_id"], "name": "Docs"}).json()
    share = client.put(f"/api/shares/{folder['id']}", json={"mode": "read"}).json()
    assert share["url"] == f"https://files.example.com/{share['token']}"


def test_read_share_browse_and_download(client, user, settings):
    photos, private = setup_tree(client, user)
    token = client.put(f"/api/shares/{photos['id']}", json={"mode": "read"}).json()["token"]
    visitor = anon(settings)

    info = visitor.get(f"/api/s/{token}").json()
    assert {k: info[k] for k in ("name", "mode", "owner", "root_id", "is_dir", "app_name")} == {
        "name": "Photos", "mode": "read", "owner": "alice", "root_id": photos["id"], "is_dir": True, "app_name": "MyFiles",
    }

    top = visitor.get(f"/api/s/{token}/folders/{photos['id']}").json()
    names = {n["name"]: n for n in top["items"]}
    assert set(names) == {"a.jpg", "2024"}
    assert all("share" not in n for n in top["items"])
    sub = visitor.get(f"/api/s/{token}/folders/{names['2024']['id']}").json()
    assert [c["name"] for c in sub["breadcrumb"]] == ["Photos", "2024"]  # stops at the shared folder

    b = sub["items"][0]
    assert visitor.get(f"/api/s/{token}/files/{b['id']}/content").content == b"B"
    r = visitor.get(f"/api/s/{token}/zip", params={"ids": photos["id"]})
    assert sorted(zipfile.ZipFile(io.BytesIO(r.content)).namelist()) == [
        "Photos/", "Photos/2024/", "Photos/2024/b.jpg", "Photos/a.jpg",
    ]

    # Read-only: no uploads.
    r = visitor.post(f"/api/s/{token}/upload", params={"parent_id": photos["id"], "name": "x.txt"}, content=b"x")
    assert r.status_code == 403


def test_share_cannot_reach_outside_folder(client, user, settings):
    photos, private = setup_tree(client, user)
    secret = listing(client, private["id"])["secret.txt"]
    token = client.put(f"/api/shares/{photos['id']}", json={"mode": "readwrite"}).json()["token"]
    visitor = anon(settings)
    assert visitor.get(f"/api/s/{token}/folders/{private['id']}").status_code == 404
    assert visitor.get(f"/api/s/{token}/folders/{user['root_id']}").status_code == 404
    assert visitor.get(f"/api/s/{token}/files/{secret['id']}/content").status_code == 404
    assert visitor.get(f"/api/s/{token}/zip", params={"ids": private["id"]}).status_code == 404
    r = visitor.post(f"/api/s/{token}/upload", params={"parent_id": private["id"], "name": "x"}, content=b"x")
    assert r.status_code == 404
    # Visitors can't use the owner's API.
    assert visitor.get(f"/api/folders/{photos['id']}").status_code == 401
    assert visitor.get("/api/s/not-a-real-token-at-all-0000000000/folders/1").status_code == 404


def test_readwrite_share_upload(client, user, settings):
    photos, _ = setup_tree(client, user)
    token = client.put(f"/api/shares/{photos['id']}", json={"mode": "readwrite"}).json()["token"]
    visitor = anon(settings)
    r = visitor.post(f"/api/s/{token}/upload", params={"parent_id": photos["id"], "name": "a.jpg"}, content=b"new")
    assert r.status_code == 201 and r.json()["name"] == "a (1).jpg"  # never overwrites
    r = visitor.post(f"/api/s/{token}/upload",
                     params={"parent_id": photos["id"], "name": "c.jpg", "relative_dir": "Party/Night"}, content=b"C")
    assert r.status_code == 201
    # The owner sees the uploads.
    assert set(listing(client, photos["id"])) == {"a.jpg", "a (1).jpg", "2024", "Party"}
    party = listing(client, photos["id"])["Party"]
    assert set(listing(client, listing(client, party["id"])["Night"]["id"])) == {"c.jpg"}
    # Visitors still can't delete, rename or move.
    assert visitor.post("/api/nodes/delete", json={"ids": [photos["id"]]}).status_code == 401


def test_only_owner_can_share(client, user, settings):
    photos, _ = setup_tree(client, user)
    other = make_client(settings)
    other.post("/api/auth/register", json={"username": "bob", "password": "12345678"})
    assert other.put(f"/api/shares/{photos['id']}", json={"mode": "read"}).status_code == 404
    client.put(f"/api/shares/{photos['id']}", json={"mode": "read"})
    assert other.delete(f"/api/shares/{photos['id']}").status_code == 404
    assert other.get("/api/shares").json() == []
    assert client.put(f"/api/shares/{photos['id']}", json={"mode": "write"}).status_code == 422


def test_deleting_folder_removes_share(client, user, settings):
    photos, _ = setup_tree(client, user)
    sub = listing(client, photos["id"])["2024"]
    token = client.put(f"/api/shares/{sub['id']}", json={"mode": "read"}).json()["token"]
    client.post("/api/nodes/delete", json={"ids": [photos["id"]]})
    assert client.get("/api/shares").json() == []
    assert anon(settings).get(f"/api/s/{token}").status_code == 404


def test_share_page_route(client, user, settings, tmp_path):
    dist = tmp_path / "dist"
    dist.mkdir()
    (dist / "index.html").write_text("<html><title>MyFiles</title>app</html>")
    (dist / "favicon.svg").write_text("<svg/>")
    settings.static_path = dist
    settings.app_name = "Family <Cloud>"
    c = TestClient(create_app(settings))
    expected = "<html><title>Family &lt;Cloud&gt;</title>app</html>"
    assert c.get("/").text == expected
    assert c.get("/index.html").text == expected
    assert c.get("/" + "a" * 32).text == expected
    assert c.get("/api/config").json()["app_name"] == "Family <Cloud>"
    assert c.get("/favicon.svg").text == "<svg/>"
    assert c.get("/short").status_code == 404


def test_root_folder_is_called_home(client, user, settings):
    root = user["root_id"]
    assert client.get(f"/api/folders/{root}").json()["breadcrumb"] == [{"id": root, "name": "Home"}]
    assert {"id": root, "parent_id": None, "name": "Home"} in client.get("/api/folders").json()
    share = client.put(f"/api/shares/{root}", json={"mode": "read"}).json()
    assert share["name"] == "Home"
    assert anon(settings).get(f"/api/s/{share['token']}").json()["name"] == "Home"
    r = client.get("/api/zip", params={"ids": root})
    assert 'filename="Home.zip"' in r.headers["content-disposition"]


def test_share_single_file(client, user, settings):
    photos, private = setup_tree(client, user)
    a = listing(client, photos["id"])["a.jpg"]
    secret = listing(client, private["id"])["secret.txt"]

    assert client.put(f"/api/shares/{a['id']}", json={"mode": "readwrite"}).status_code == 400
    share = client.put(f"/api/shares/{a['id']}", json={"mode": "read"}).json()
    assert (share["is_dir"], share["kind"], share["path"], share["name"]) == (False, "image", "/Photos/a.jpg", "a.jpg")
    assert share["parent_id"] == photos["id"]
    assert listing(client, photos["id"])["a.jpg"]["share"] == "read"
    assert [s["path"] for s in client.get("/api/shares").json()] == ["/Photos/a.jpg"]

    visitor = anon(settings)
    token = share["token"]
    info = visitor.get(f"/api/s/{token}").json()
    assert (info["is_dir"], info["name"], info["node"]["size"], info["node"]["kind"]) == (False, "a.jpg", 1, "image")
    assert visitor.get(f"/api/s/{token}/files/{a['id']}/content").content == b"A"
    r = visitor.get(f"/api/s/{token}/files/{a['id']}/content", params={"download": 1})
    assert r.headers["content-disposition"].startswith("attachment")

    # Nothing else is reachable through a file link.
    assert visitor.get(f"/api/s/{token}/folders/{a['id']}").status_code == 400
    assert visitor.get(f"/api/s/{token}/folders/{photos['id']}").status_code == 404
    assert visitor.get(f"/api/s/{token}/files/{secret['id']}/content").status_code == 404
    r = visitor.post(f"/api/s/{token}/upload", params={"parent_id": photos["id"], "name": "x"}, content=b"x")
    assert r.status_code == 403

    # Renaming or moving the file keeps the link working; deleting it removes the share.
    client.patch(f"/api/nodes/{a['id']}", json={"name": "renamed.jpg"})
    client.post("/api/nodes/move", json={"ids": [a["id"]], "target_id": private["id"]})
    assert visitor.get(f"/api/s/{token}").json()["name"] == "renamed.jpg"
    assert client.get("/api/shares").json()[0]["path"] == "/Private/renamed.jpg"
    client.post("/api/nodes/delete", json={"ids": [a["id"]]})
    assert client.get("/api/shares").json() == []
    assert visitor.get(f"/api/s/{token}").status_code == 404


def test_stop_sharing_file(client, user):
    photos, _ = setup_tree(client, user)
    a = listing(client, photos["id"])["a.jpg"]
    client.put(f"/api/shares/{a['id']}", json={"mode": "read"})
    assert client.delete(f"/api/shares/{a['id']}").status_code == 204
    assert client.get(f"/api/shares/{a['id']}").json() is None
