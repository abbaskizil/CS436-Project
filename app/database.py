"""
SQLAlchemy database setup.

Provides writer and reader engines. On ECS, DATABASE_URL (writer) and
DATABASE_URL_READER (reader) are injected from Secrets Manager. Locally,
both fall back to DATABASE_URL so development works without two endpoints.
"""
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.config import get_settings

settings = get_settings()

engine = create_engine(settings.database_url, pool_pre_ping=True)

# Use a dedicated read-only engine when DATABASE_URL_READER is provided.
# Falls back to the writer engine for local dev and unit tests.
_reader_url = settings.database_url_reader or settings.database_url
reader_engine = create_engine(_reader_url, pool_pre_ping=True)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
ReaderSession = sessionmaker(autocommit=False, autoflush=False, bind=reader_engine)


class Base(DeclarativeBase):
    """Declarative base for all ORM models."""
    pass


def get_db():
    """FastAPI dependency — yields a writer DB session."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_reader_db():
    """FastAPI dependency — yields a read-only DB session (reader replica)."""
    db = ReaderSession()
    try:
        yield db
    finally:
        db.close()
