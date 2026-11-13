"""Command line: python -m myfiles <command>."""

import argparse
import getpass
import sys

from sqlalchemy import delete, func, select, update


def _session():
    from .config import get_settings
    from .models import create_schema, make_engine, make_sessionmaker

    engine = make_engine(get_settings())
    create_schema(engine)
    return make_sessionmaker(engine)()


def _ask_password() -> str:
    password = getpass.getpass("Password: ")
    if len(password) < 8:
        sys.exit("Password must be at least 8 characters")
    if getpass.getpass("Repeat password: ") != password:
        sys.exit("Passwords don't match")
    return password


def serve(args) -> None:
    import uvicorn

    from .app import create_app
    from .config import get_settings

    settings = get_settings()
    uvicorn.run(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        proxy_headers=True,
        forwarded_allow_ips=settings.trusted_proxies,
    )


def create_user(args) -> None:
    from .api import USERNAME_RE
    from .auth import create_user as create
    from .models import User

    username = args.username.lower()
    if not USERNAME_RE.match(username):
        sys.exit("Username must be 3-32 characters: letters, digits, '.', '_' or '-'")
    with _session() as db:
        if db.scalar(select(User.id).where(User.username == username)):
            sys.exit(f"User '{username}' already exists")
        user = create(db, username, _ask_password())
        if args.admin:
            user.is_admin = True
            db.commit()
    print(f"Created {'administrator' if args.admin else 'user'} '{username}'")


def set_password(args) -> None:
    from .auth import hash_password
    from .models import User

    with _session() as db:
        user = db.scalar(select(User).where(User.username == args.username.lower()))
        if user is None:
            sys.exit(f"No user named '{args.username}'")
        user.password_hash = hash_password(_ask_password())
        db.commit()
    print(f"Password updated for '{user.username}'")


def _get_user(db, username: str):
    from .models import User

    user = db.scalar(select(User).where(User.username == username.lower()))
    if user is None:
        sys.exit(f"No user named '{username}'")
    return user


def list_users(args) -> None:
    from . import quotas
    from .config import get_settings
    from .models import Node, User

    settings = get_settings()
    with _session() as db:
        rows = db.execute(
            select(User, func.count(Node.id), func.coalesce(func.sum(Node.size), 0))
            .outerjoin(Node, (Node.user_id == User.id) & Node.is_dir.is_(False))
            .group_by(User.id)
            .order_by(User.username)
        ).all()
    print(f"{'USER':<24} {'FILES':>7} {'USED':>10} {'QUOTA':>16}  {'':<5} SINCE")
    for user, files, used in rows:
        quota = quotas.quota_of(user, settings)
        quota_text = quotas.format_size(quota) + (" (default)" if user.quota_bytes is None else "")
        full = "FULL" if quota is not None and used >= quota else ""
        name = user.username + (" [admin]" if user.is_admin else "")
        print(f"{name:<24} {files:>7} {quotas.format_size(int(used)):>10} {quota_text:>16}  {full:<5} {user.created_at:%Y-%m-%d}")
    print(f"\nDefault quota (DEFAULT_QUOTA_GB in .env): {quotas.format_size(quotas.default_quota(settings))}")


def set_quota(args) -> None:
    from . import quotas
    from .config import get_settings

    value = args.quota.strip().lower()
    with _session() as db:
        user = _get_user(db, args.username)
        if value == "default":
            user.quota_bytes = None
        elif value == "unlimited":
            user.quota_bytes = quotas.UNLIMITED
        else:
            try:
                size = quotas.parse_size(value)
            except ValueError as e:
                sys.exit(str(e))
            if size <= 0:
                sys.exit("The quota must be greater than 0 (or 'unlimited')")
            user.quota_bytes = size
        db.commit()
        quota = quotas.quota_of(user, get_settings())
        used = quotas.used_bytes(db, user.id)
        note = " (the default)" if user.quota_bytes is None else ""
        print(f"Quota for '{user.username}' is now {quotas.format_size(quota)}{note}; "
              f"{quotas.format_size(used)} in use")
        if quota is not None and used > quota:
            print("Note: they're already over this quota. Their files are kept, but they can't upload "
                  "until they free up space.")


def set_admin(args) -> None:
    with _session() as db:
        user = _get_user(db, args.username)
        user.is_admin = not args.remove
        db.commit()
    if args.remove:
        print(f"'{user.username}' is no longer an administrator")
    else:
        print(f"'{user.username}' is now an administrator (the Admin page appears after they reload)")


def delete_user(args) -> None:
    from .config import get_settings
    from .models import Node, Share, User
    from .storage import Storage

    with _session() as db:
        user = db.scalar(select(User).where(User.username == args.username.lower()))
        if user is None:
            sys.exit(f"No user named '{args.username}'")
        if input(f"Delete '{user.username}' and ALL their files? Type the username to confirm: ") != user.username:
            sys.exit("Cancelled")
        user_id = user.id
        # Detach the tree first; cascading through deep folder chains can hit InnoDB's cascade depth limit.
        db.execute(delete(Share).where(Share.user_id == user_id))
        db.execute(update(Node).where(Node.user_id == user_id).values(parent_id=None))
        db.execute(delete(Node).where(Node.user_id == user_id))
        db.execute(delete(User).where(User.id == user_id))
        db.commit()
    Storage(get_settings().storage_path).delete_user(user_id)
    print(f"Deleted '{args.username}'")


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m myfiles")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("serve", help="run the web server").set_defaults(func=serve)
    p = commands.add_parser("create-user", help="create a user (works even when registration is closed)")
    p.add_argument("username")
    p.add_argument("--admin", action="store_true", help="make them an administrator")
    p.set_defaults(func=create_user)
    for name, func_, help_ in (
        ("set-password", set_password, "reset a user's password"),
        ("delete-user", delete_user, "delete a user and all their files"),
    ):
        p = commands.add_parser(name, help=help_)
        p.add_argument("username")
        p.set_defaults(func=func_)
    commands.add_parser("list-users", help="list users, their storage use and quotas").set_defaults(func=list_users)

    p = commands.add_parser("set-quota", help="set a user's storage quota")
    p.add_argument("username")
    p.add_argument("quota", help="a size such as 50GB, 500MB or 1.5TB (a bare number means GB), "
                                 "'unlimited', or 'default' to use DEFAULT_QUOTA_GB from .env")
    p.set_defaults(func=set_quota)

    p = commands.add_parser("set-admin", help="make a user an administrator (or --remove to undo)")
    p.add_argument("username")
    p.add_argument("--remove", action="store_true", help="take administrator rights away")
    p.set_defaults(func=set_admin)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
