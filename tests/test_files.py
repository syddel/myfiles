from tests.conftest import make_client


def upload(client, parent_id, name, data=b"hello", relative_dir=""):
    r = client.post("/api/upload", params={"parent_id": parent_id, "name": name, "relative_dir": relative_dir},
                    content=data)
    assert r.status_code == 201, r.text
    return r.json()


def listing(client, folder_id):
    return {n["name"]: n for n in client.get(f"/api/folders/{folder_id}").json()["items"]}


def test_upload_list_download(client, user, settings):
    root = user["root_id"]
    node = upload(client, root, "notes.txt", b"hello world")
    assert node["size"] == 11 and node["kind"] == "text"

    assert set(listing(client, root)) == {"notes.txt"}
    r = client.get(f"/api/files/{node['id']}/content", params={"download": 1})
    assert r.content == b"hello world"
    assert r.headers["content-disposition"].startswith("attachment")
    # Nothing left in the temp dir.
    assert not any((settings.storage_path / "tmp").iterdir())


def test_duplicate_names_are_renamed(client, user):
    root = user["root_id"]
    assert upload(client, root, "a.txt")["name"] == "a.txt"
    assert upload(client, root, "a.txt")["name"] == "a (1).txt"
    assert upload(client, root, "a.txt")["name"] == "a (2).txt"
    assert upload(client, root, "README")["name"] == "README"
    assert upload(client, root, "README")["name"] == "README (1)"
    # Names are case-sensitive, like on Linux.
    assert upload(client, root, "A.txt")["name"] == "A.txt"


def test_folder_upload_creates_structure(client, user):
    root = user["root_id"]
    upload(client, root, "1.jpg", relative_dir="Photos/2024")
    upload(client, root, "2.jpg", relative_dir="Photos/2024")
    photos = listing(client, root)["Photos"]
    y2024 = listing(client, photos["id"])["2024"]
    assert set(listing(client, y2024["id"])) == {"1.jpg", "2.jpg"}
    crumbs = client.get(f"/api/folders/{y2024['id']}").json()["breadcrumb"]
    assert [c["name"] for c in crumbs] == ["Home", "Photos", "2024"]


def test_range_requests_for_media(client, user):
    node = upload(client, user["root_id"], "song.mp3", bytes(range(256)) * 4)
    r = client.get(f"/api/files/{node['id']}/content", headers={"Range": "bytes=10-19"})
    assert r.status_code == 206
    assert r.content == bytes(range(10, 20))
    assert r.headers["content-type"] == "audio/mpeg"
    assert r.headers["content-disposition"].startswith("inline")


def test_html_is_never_served_as_html(client, user):
    node = upload(client, user["root_id"], "page.html", b"<script>alert(1)</script>")
    r = client.get(f"/api/files/{node['id']}/content")
    assert r.headers["content-type"].startswith("text/plain")
    assert r.headers["content-security-policy"] == "sandbox"


def test_create_folder_rename_move(client, user):
    root = user["root_id"]
    docs = client.post("/api/folders", json={"parent_id": root, "name": "Docs"}).json()
    assert client.post("/api/folders", json={"parent_id": root, "name": "Docs"}).status_code == 409
    assert client.post("/api/folders", json={"parent_id": root, "name": "a/b"}).status_code == 400
    f = upload(client, root, "report.txt")

    r = client.patch(f"/api/nodes/{f['id']}", json={"name": "report.pdf"})
    assert r.json()["mime_type"] == "application/pdf"

    assert client.post("/api/nodes/move", json={"ids": [f["id"]], "target_id": docs["id"]}).status_code == 200
    assert set(listing(client, docs["id"])) == {"report.pdf"}
    assert "report.pdf" not in listing(client, root)

    # Conflicting name in destination.
    upload(client, root, "report.pdf")
    other = listing(client, root)["report.pdf"]
    assert client.post("/api/nodes/move", json={"ids": [other["id"]], "target_id": docs["id"]}).status_code == 409


def test_cannot_move_folder_into_itself(client, user):
    root = user["root_id"]
    a = client.post("/api/folders", json={"parent_id": root, "name": "a"}).json()
    b = client.post("/api/folders", json={"parent_id": a["id"], "name": "b"}).json()
    assert client.post("/api/nodes/move", json={"ids": [a["id"]], "target_id": b["id"]}).status_code == 400
    assert client.post("/api/nodes/move", json={"ids": [a["id"]], "target_id": a["id"]}).status_code == 400
    assert client.post("/api/nodes/move", json={"ids": [root], "target_id": a["id"]}).status_code == 400


def test_delete_folder_recursively(client, user, settings):
    root = user["root_id"]
    for i in range(3):
        upload(client, root, f"f{i}.txt", relative_dir="a/b/c")
    keep = upload(client, root, "keep.txt")
    a = listing(client, root)["a"]
    r = client.post("/api/nodes/delete", json={"ids": [a["id"]]})
    assert r.json()["deleted"] == 6  # a, b, c + 3 files
    assert set(listing(client, root)) == {"keep.txt"}
    stored = [p for p in (settings.storage_path / "files").rglob("*") if p.is_file()]
    assert len(stored) == 1
    # The root folder can't be deleted.
    client.post("/api/nodes/delete", json={"ids": [root]})
    assert client.get(f"/api/folders/{root}").status_code == 200
    assert client.get(f"/api/files/{keep['id']}/content").status_code == 200


def test_search(client, user):
    root = user["root_id"]
    upload(client, root, "Holiday Photo.jpg", relative_dir="Trips/Italy")
    upload(client, root, "shopping list.txt")
    upload(client, root, "100%_real.txt")
    results = client.get("/api/search", params={"q": "photo"}).json()
    assert [(r["name"], r["path"]) for r in results] == [("Holiday Photo.jpg", "/Trips/Italy")]
    assert [r["name"] for r in client.get("/api/search", params={"q": "%_"}).json()] == ["100%_real.txt"]
    assert [r["name"] for r in client.get("/api/search", params={"q": "ital"}).json()] == ["Italy"]


def test_users_are_isolated(client, user, settings):
    secret = upload(client, user["root_id"], "secret.txt")
    other = make_client(settings)
    bob = other.post("/api/auth/register", json={"username": "bob", "password": "12345678"}).json()
    assert other.get(f"/api/files/{secret['id']}/content").status_code == 404
    assert other.get(f"/api/folders/{user['root_id']}").status_code == 404
    assert other.post("/api/nodes/delete", json={"ids": [secret["id"]]}).json()["deleted"] == 0
    assert other.post("/api/nodes/move", json={"ids": [secret["id"]], "target_id": bob["root_id"]}).status_code == 404
    assert other.get("/api/search", params={"q": "secret"}).json() == []


def test_upload_size_limit(settings):
    settings.max_upload_size_mb = 1
    client = make_client(settings)
    root = client.post("/api/auth/register", json={"username": "alice", "password": "12345678"}).json()["root_id"]
    r = client.post("/api/upload", params={"parent_id": root, "name": "big.bin"}, content=b"x" * (1024 * 1024 + 1))
    assert r.status_code == 413
    assert listing(client, root) == {}


def test_stats(client, user):
    upload(client, user["root_id"], "a.bin", b"x" * 1000)
    s = client.get("/api/stats").json()
    assert s["used_bytes"] == 1000 and s["file_count"] == 1 and s["disk_total"] > 0


def read_zip(response):
    import io
    import zipfile

    assert response.status_code == 200, response.text
    assert response.headers["content-type"] == "application/zip"
    archive = zipfile.ZipFile(io.BytesIO(response.content))
    assert archive.testzip() is None
    return {name: archive.read(name) for name in archive.namelist()}


def test_download_folder_as_zip(client, user):
    root = user["root_id"]
    upload(client, root, "a.txt", b"AAA", relative_dir="Trip/Day 1")
    upload(client, root, "b.jpg", b"BBB", relative_dir="Trip")
    upload(client, root, "outside.txt", b"nope")
    trip = listing(client, root)["Trip"]
    client.post("/api/folders", json={"parent_id": trip["id"], "name": "Empty"})

    r = client.get("/api/zip", params={"ids": trip["id"]})
    assert 'filename="Trip.zip"' in r.headers["content-disposition"]
    assert read_zip(r) == {
        "Trip/": b"", "Trip/Day 1/": b"", "Trip/Day 1/a.txt": b"AAA", "Trip/Empty/": b"", "Trip/b.jpg": b"BBB",
    }


def test_zip_extracts_with_normal_permissions(client, user, tmp_path):
    import io
    import stat
    import zipfile

    root = user["root_id"]
    upload(client, root, "a.txt", b"AAA", relative_dir="Trip/Day 1")
    trip = listing(client, root)["Trip"]
    archive = zipfile.ZipFile(io.BytesIO(client.get("/api/zip", params={"ids": trip["id"]}).content))
    modes = {i.filename: stat.S_IMODE(i.external_attr >> 16) for i in archive.infolist()}
    assert modes == {"Trip/": 0o755, "Trip/Day 1/": 0o755, "Trip/Day 1/a.txt": 0o644}
    assert all(i.create_system == 3 for i in archive.infolist())


def test_download_selection_as_zip(client, user):
    root = user["root_id"]
    f1 = upload(client, root, "report.txt", b"one")
    upload(client, root, "report.txt", b"two", relative_dir="Old")
    old = listing(client, root)["Old"]
    f2 = listing(client, old["id"])["report.txt"]
    r = client.get("/api/zip", params={"ids": [f1["id"], f2["id"], old["id"]]})
    assert "MyFiles%20download.zip" in r.headers["content-disposition"]
    # Same name from different folders gets de-duplicated at the top level.
    assert read_zip(r) == {"report.txt": b"one", "report (1).txt": b"two", "Old/": b"", "Old/report.txt": b"two"}


def test_zip_unicode_name_and_isolation(client, user, settings):
    root = user["root_id"]
    upload(client, root, "é.txt", b"x", relative_dir="Café")
    cafe = listing(client, root)["Café"]
    r = client.get("/api/zip", params={"ids": cafe["id"]})
    assert "filename*=UTF-8''Caf%C3%A9.zip" in r.headers["content-disposition"]
    assert read_zip(r) == {"Café/": b"", "Café/é.txt": b"x"}

    other = make_client(settings)
    other.post("/api/auth/register", json={"username": "bob", "password": "12345678"})
    assert other.get("/api/zip", params={"ids": cafe["id"]}).status_code == 404
