"""Keep the test suite away from the application database.

The suite deletes every user and item when it finishes, so it always runs
against a dedicated `<name>_test` database, created and migrated on demand.
"""

import os
import subprocess
import sys
from pathlib import Path

from pydantic import PostgresDsn
from sqlalchemy import URL, create_engine, make_url, text

from app.core.config import settings

TEST_DATABASE_SUFFIX = "_test"
BACKEND_DIR = Path(__file__).resolve().parents[2]


def to_test_database_url(url: str) -> URL:
    """`.../app` -> `.../app_test`; a URL that already names a test DB is kept."""
    parsed = make_url(url)
    name = parsed.database or "app"
    if not name.endswith(TEST_DATABASE_SUFFIX):
        name += TEST_DATABASE_SUFFIX
    return parsed.set(database=name)


def is_test_database(url: URL) -> bool:
    return (url.database or "").endswith(TEST_DATABASE_SUFFIX)


def _create_database_if_missing(url: URL) -> None:
    server = create_engine(url.set(database="postgres"), isolation_level="AUTOCOMMIT")
    with server.connect() as connection:
        exists = connection.execute(
            text("SELECT 1 FROM pg_database WHERE datname = :name"),
            {"name": url.database},
        ).scalar()
        if not exists:
            connection.execute(text(f'CREATE DATABASE "{url.database}"'))
    server.dispose()


def use_test_database() -> None:
    """Point the settings at the test database before any engine is created."""
    url = to_test_database_url(str(settings.DATABASE_URL))
    rendered = url.render_as_string(hide_password=False)
    _create_database_if_missing(url)
    # A separate process, so Alembic's logging setup does not leak into pytest
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=BACKEND_DIR,
        env={**os.environ, "DATABASE_URL": rendered},
        check=True,
        capture_output=True,
    )
    settings.DATABASE_URL = PostgresDsn(rendered)
