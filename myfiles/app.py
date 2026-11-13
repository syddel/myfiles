"""Application factory."""

import html

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from starlette.convertors import Convertor, register_url_convertor

from . import admin, api, shares
from .config import Settings, get_settings
from .models import create_schema, make_engine, make_sessionmaker
from .storage import Storage


class ShareTokenConvertor(Convertor):
    regex = shares.TOKEN_REGEX

    def convert(self, value: str) -> str:
        return value

    def to_string(self, value: str) -> str:
        return value


register_url_convertor("sharetoken", ShareTokenConvertor())

def frontend_missing() -> HTMLResponse:
    return HTMLResponse(
        "<h1>MyFiles</h1><p>The frontend hasn't been built yet. "
        "Run <code>npm ci &amp;&amp; npm run build</code> in <code>frontend/</code>.</p>"
    )


class RequireAjaxHeader:
    """CSRF guard: state-changing API calls must carry X-Requested-With.

    Browsers only send custom headers from same-origin scripts, so forms
    on other sites can't trigger uploads, deletes, etc.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if (
            scope["type"] == "http"
            and scope["method"] not in ("GET", "HEAD", "OPTIONS")
            and scope["path"].startswith("/api/")
            and (b"x-requested-with", b"myfiles") not in scope["headers"]
        ):
            await send({"type": "http.response.start", "status": 403,
                        "headers": [(b"content-type", b"application/json")]})
            await send({"type": "http.response.body", "body": b'{"detail":"Missing X-Requested-With header"}'})
            return
        await self.app(scope, receive, send)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    storage = Storage(settings.storage_path)
    storage.init()
    engine = make_engine(settings)
    create_schema(engine)

    app = FastAPI(title=settings.app_name, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings
    app.state.storage = storage
    app.state.SessionLocal = make_sessionmaker(engine)
    app.add_middleware(RequireAjaxHeader)
    app.include_router(api.router, prefix="/api")
    app.include_router(shares.router, prefix="/api")
    app.include_router(admin.router, prefix="/api")

    index = settings.static_path / "index.html"
    title = f"<title>{html.escape(settings.app_name)}</title>"

    def index_page() -> HTMLResponse:
        # Read on every request so a frontend rebuild is picked up without a restart.
        page = index.read_text(encoding="utf-8").replace("<title>MyFiles</title>", title, 1)
        return HTMLResponse(page, headers={"Cache-Control": "no-cache"})

    # The app page, with APP_NAME as its title. Share links (BASE_URL/<token>) load
    # the same page, which then shows the shared folder.
    @app.get("/", include_in_schema=False)
    @app.get("/index.html", include_in_schema=False)
    @app.get("/{token:sharetoken}", include_in_schema=False)
    def app_page(token: str = ""):
        return index_page() if index.is_file() else frontend_missing()

    if index.is_file():
        app.mount("/", StaticFiles(directory=settings.static_path), name="static")

    return app
