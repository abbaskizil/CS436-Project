"""
Application configuration.

Environment variables are loaded from the .env file (see .env.example).
"""
import os
from getpass import getuser
from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # ── Application ──────────────────────────────────────────────────────────
    app_name: str = "Ders Forumu API"
    debug: bool = False

    # ── Database (PostgreSQL) ────────────────────────────────────────────────
    # Local example: postgresql+psycopg2://user:pass@localhost:5432/ders_forumu
    # On ECS: DATABASE_URL (writer) and DATABASE_URL_READER are injected from Secrets Manager.
    _default_pg_user = os.getenv("PGUSER") or getuser()
    database_url: str = os.getenv(
        "DATABASE_URL",
        f"postgresql+psycopg2://{_default_pg_user}@localhost:5432/ders_forumu",
    )
    database_url_reader: str = os.getenv("DATABASE_URL_READER", "")

    # ── Local Auth (JWT) ─────────────────────────────────────────────────────
    # Üretim için MUTLAKA güçlü bir secret gir (.env içinde JWT_SECRET).
    jwt_secret: str = os.getenv("JWT_SECRET", "dev-secret-change-me")
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = int(os.getenv("JWT_EXPIRE_MINUTES", "10080"))  # 7 gün

    # ── Email / OTP ──────────────────────────────────────────────────────────
    # SMTP_HOST boşsa OTP konsola yazdırılır (dev fallback).
    smtp_host: str = os.getenv("SMTP_HOST", "")
    smtp_port: int = int(os.getenv("SMTP_PORT", "587"))
    smtp_user: str = os.getenv("SMTP_USER", "")
    smtp_password: str = os.getenv("SMTP_PASSWORD", "")
    smtp_from: str = os.getenv("SMTP_FROM", "noreply@dersforumu.local")
    smtp_use_tls: bool = os.getenv("SMTP_USE_TLS", "true").lower() == "true"

    # Sadece bu domain'le biten emaillere izin ver (büyük/küçük harf duyarsız)
    allowed_email_domain: str = os.getenv("ALLOWED_EMAIL_DOMAIN", "sabanciuniv.edu")

    # OTP geçerlilik süresi (dakika) ve başına izin verilen deneme sayısı
    otp_ttl_minutes: int = int(os.getenv("OTP_TTL_MINUTES", "10"))
    otp_max_attempts: int = int(os.getenv("OTP_MAX_ATTEMPTS", "5"))

    # ── Redis ────────────────────────────────────────────────────────────────
    # On ECS: REDIS_URL injected from Secrets Manager (redis/authtoken).
    redis_url: str = os.getenv("REDIS_URL", "")

    # ── AWS Cognito ──────────────────────────────────────────────────────────
    cognito_region: str = os.getenv("COGNITO_REGION", "eu-central-1")
    cognito_user_pool_id: str = os.getenv("COGNITO_USER_POOL_ID", "")
    cognito_app_client_id: str = os.getenv("COGNITO_APP_CLIENT_ID", "")

    class Config:
        env_file = ".env"
        case_sensitive = False


@lru_cache
def get_settings() -> Settings:
    """Return a cached Settings instance."""
    return Settings()
