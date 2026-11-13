# MyFiles

Small self-hosted file storage and sharing web app.

- Register as a user (registration can use "open", "invite code", or "admin-only" - set in `.env`)
- Upload files and whole folders, with drag and drop and per-file progress bars
- Download files, or whole folders and multi-selections as a zip file.
- Preview PDFs, text and code, images, audio (MP3, FLAC, ...) and video in the browser.
- Create folders, rename, move (drag onto a folder or breadcrumb, or use "Move to..."), and delete.
- Search across all files and folders.
- Share folders or single files by link: read-only, or (for folders) read & write, so visitors can upload.
- Use your own name for the app (`APP_NAME` in `.env`).
- Select folder color (`account menu` -> **Folder color**).
- Select light or dark theme (account menu -> **Theme**: Light, Dark, or System).
- Set storage quotas per user (15GB default), managed on the **Admin** page or from the terminal.
- Sortable list view, multi-select (Ctrl/Shift-click), right-click menu, and keyboard shortcuts

**Stack used:** Python (FastAPI + SQLAlchemy), MariaDB, Vue 3 + Vite + Tailwind.

Runs as a single process under systemd, behind Apache.

Files are stored on disk under `STORAGE_PATH` (set in `.env`), using random names. 

File names and the folder tree are kept in MariaDB, so renaming and moving are instant and never touch the disk.

---

## Installation (Ubuntu Server 26.04 / Arch Linux)

These steps install MyFiles to `/opt/myfiles` and run it as a dedicated `myfiles` user. Adjust the paths if you want it somewhere else.

### 1. Install packages

Ubuntu:

```sh
sudo apt install git python3 python3-venv nodejs npm mariadb-server
```

Arch:

```sh
sudo pacman -S git python nodejs npm mariadb
sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
sudo systemctl enable --now mariadb
```

You need Python 3.11+, MariaDB 10.6+, and Node.js 20.19+. Node is only needed to build the frontend.

### 2. Create the database

```sh
sudo mariadb
```

```sql
CREATE DATABASE myfiles CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'myfiles'@'localhost' IDENTIFIED BY 'a-strong-password';
GRANT ALL PRIVILEGES ON myfiles.* TO 'myfiles'@'localhost';
```

The tables are created automatically the first time MyFiles starts.

### 3. Get the code and install it

```sh
# The service user's home (pip/npm caches, SSH keys) is kept separate from the code.
sudo useradd --system --create-home --home-dir /var/lib/myfiles --shell /usr/sbin/nologin myfiles
sudo git clone https://github.com/mdec101/myfiles.git /opt/myfiles
sudo chown -R myfiles:myfiles /opt/myfiles
cd /opt/myfiles

# Backend
sudo -u myfiles python3 -m venv .venv
sudo -u myfiles .venv/bin/pip install -r requirements.txt

# Frontend (builds into frontend/dist, which the backend serves)
cd frontend
sudo -u myfiles npm ci
sudo -u myfiles npm run build
cd ..
```

### 4. Configure

```sh
sudo -u myfiles cp .env.example .env
sudo chmod 600 .env
sudo -u myfiles nano .env
```

At minimum, set `STORAGE_PATH` and `DB_PASSWORD`, and choose a `REGISTRATION_MODE`. Every option is explained in [`.env.example`](.env.example). Then create the storage directory:

```sh
sudo mkdir -p /srv/myfiles            # whatever STORAGE_PATH is
sudo chown myfiles:myfiles /srv/myfiles
```

`STORAGE_PATH` can be any directory, such as a second disk or a mounted NAS share, as long as the `myfiles` user can write to it.

### 5. Run it as a service

```sh
sudo cp deploy/myfiles.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now myfiles
systemctl status myfiles          # logs: journalctl -u myfiles -f
```

MyFiles now listens on `127.0.0.1:8000`, which you can change with `HOST` and `PORT`.

### 6. Put it behind Apache

[`deploy/apache-myfiles.conf`](deploy/apache-myfiles.conf) has two options:

- **A: its own (sub)domain**, e.g. `https://files.example.com/`
- **B: a sub-path of an existing site**, e.g. `https://example.com/files/`

Enable the modules, then copy in the option you want:

```sh
# Ubuntu
sudo a2enmod proxy proxy_http headers ssl
sudo cp deploy/apache-myfiles.conf /etc/apache2/sites-available/myfiles.conf   # edit it first
sudo a2ensite myfiles && sudo systemctl reload apache2

# Arch: enable mod_proxy, mod_proxy_http, mod_headers and mod_ssl in
# /etc/httpd/conf/httpd.conf, add the config under /etc/httpd/conf/extra/,
# Include it, then: sudo systemctl reload httpd
```

Two settings in that config matter for large files:

- `LimitRequestBody 0`: Apache 2.4.53+ otherwise rejects uploads over 1 GiB.
- `ProxyTimeout 3600`: gives slow uploads and downloads time to finish.

### 7. Create the first account

Open the site and register. If `REGISTRATION_MODE=invite`, you'll need the `INVITE_CODE`. With `REGISTRATION_MODE=closed`, create accounts from the command line instead:

```sh
cd /opt/myfiles
sudo -u myfiles .venv/bin/python -m myfiles create-user alice
```

---

## Sharing folders and files

Anyone who has a "share link" can open it without an account. To share a folder or a file, right-click it (or use the ... menu or toolbar) and choose **Share...**.

**A shared file** is always read-only. Visitors see a page with the file's preview (images, video, audio, PDFs and text show right in the browser) and a **Download** button.

**A shared folder** can be shared in one of two modes:

| Mode | Visitors can |
|---|---|
| **Read only** | Browse the folder and its sub-folders, preview files, and download files or zips |
| **Read & write** | All of the above, plus upload files and folders |

Even with read & write, visitors can only *add* files. They can't delete, rename, move or overwrite anything, and uploads with an existing name are saved as `name (1).ext`. Uploaded files count as the folder owner's.

- Links look like `BASE_URL/Xy3...` (32 random characters). Set `BASE_URL` in `.env` to the address people use to reach MyFiles, then restart. If it isn't set, links are built from the address in your browser.
- Shared folders and files show a link icon in the file list. Click it to copy the link, change the mode, or stop sharing.
- **Shared** in the header lists everything you've shared. From there you can share another folder, copy links, change modes, or stop sharing.
- **Password (optional):** tick **Require a password** in the share dialog. Visitors then need the link *and* the password, and until they enter it they see nothing about the shared item, not even its name. Share the password separately from the link. Changing or removing the password makes everyone who used the old one enter the new one. After 10 wrong guesses, a visitor has to wait 10 minutes before trying again.
- Changing the mode keeps the same link, and so does renaming or moving a shared item. **Stop sharing** makes the link stop working immediately. Sharing the item again creates a new link.
- Deleting a shared folder or file also removes its share.

## Managing users

Run these from `/opt/myfiles` as the `myfiles` user (`sudo -u myfiles .venv/bin/python -m myfiles ...`):

| Command | What it does |
|---|---|
| `create-user NAME` | Create an account (prompts for a password). Add `--admin` to make it an administrator |
| `set-password NAME` | Reset someone's password |
| `list-users` | List users with their files, storage used and quota |
| `set-quota NAME SIZE` | Set someone's quota: e.g. `50GB`, `500MB`, `1.5TB`, `unlimited`, or `default` |
| `set-admin NAME` | Make someone an administrator (`--remove` to undo) |
| `delete-user NAME` | Delete a user and **all** their files |

## Storage quotas

Every user has a storage quota: **15GB by default**, set with `DEFAULT_QUOTA_GB` in `.env` (`0` means unlimited). Users see how much they've used in the status bar at the bottom of the page.

- An upload that would go over the quota is refused before it's sent, with a message saying how much space is left. Files uploaded by visitors through a read & write share link count against the folder owner's quota.
- Lowering someone's quota below what they already use never deletes anything: they keep their files but can't upload until they've freed up space.
- Changing `DEFAULT_QUOTA_GB` (then restarting) changes the quota of everyone who's on the default.

**Changing a quota** for one person, either:

- **In the web app**, as an administrator: **Admin** in the header lists every user with their storage use. Click **Change quota** and pick Default, a custom size in GB, or Unlimited.
- **From the terminal**: `set-quota NAME 50GB` (or `unlimited`, or `default` to go back to the default).

**Administrators:** only administrators see the Admin page. Make your own account one from the terminal (the web app has no way to do it, so nobody can promote themselves):

```sh
cd /opt/myfiles
sudo -u myfiles .venv/bin/python -m myfiles set-admin yourname
```

Reload the page and **Admin** appears in the header.

Users can change their own password from the account menu.

## Updating

```sh
cd /opt/myfiles
sudo -u myfiles git pull
sudo -u myfiles .venv/bin/pip install -r requirements.txt
(cd frontend && sudo -u myfiles npm ci && sudo -u myfiles npm run build)
sudo systemctl restart myfiles
```

## Backups

Back up both of these together:

1. The database: `sudo mariadb-dump myfiles > myfiles.sql`
2. The files: everything in `STORAGE_PATH/files/`

## Keyboard shortcuts

| Key | Action |
|---|---|
| Double-click / Enter | Open folder or preview file |
| Ctrl/Shift + click | Multi-select |
| Ctrl + A | Select all |
| Delete | Delete selection |
| F2 | Rename |
| Backspace | Go to parent folder |
| / | Focus search |
| ← / → (in preview) | Previous / next file |
| Esc | Close preview / clear selection |

---

## Development

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
cp .env.example .env                 # point it at a dev database and storage dir
.venv/bin/python -m myfiles serve    # API on :8000

cd frontend && npm install && npm run dev  # UI on :5173, proxies /api to :8000
```

Tests use SQLite by default. Set `TEST_DATABASE_URL` to run them against MariaDB:

```sh
.venv/bin/pytest
TEST_DATABASE_URL='mariadb+pymysql://myfiles:pass@localhost/myfiles_test?charset=utf8mb4' .venv/bin/pytest
```

**The MariaDB test run drops and recreates every table in that database, so use a separate test database.**

### Layout

```
myfiles/            Python backend
  app.py            app factory, static file serving, CSRF guard
  api.py            JSON API (/api/...)
  auth.py           passwords (argon2), sessions
  models.py         database tables
  storage.py        on-disk storage, MIME types
  zipstream.py      streaming zip downloads
  config.py         settings (.env)
  __main__.py       command line: serve, create-user, ...
frontend/src/       Vue app
deploy/             systemd unit, Apache config
tests/              pytest suite
```

### Security notes

- Passwords are hashed with argon2. Sessions are random tokens stored hashed in the database, sent in an HttpOnly, SameSite=Lax cookie that is marked Secure over HTTPS.
- Requests that change anything must carry an `X-Requested-With` header, which other sites can't add, as extra CSRF protection.
- Uploaded HTML, SVG and scripts are never served as web pages. Text files are sent as `text/plain`, and inline previews get a `Content-Security-Policy: sandbox` header.
- Every file and folder lookup is checked against the signed-in user, so users can't see each other's files.
