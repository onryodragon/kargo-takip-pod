"""
config.py
---------
Uygulama genelindeki ortam değişkenleri, JWT, SQLite / Supabase,
Yerel Medya (`uploads/pod-media/`), Excel Arşiv (`excel_arsiv/`) ve SMTP ayarları.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent.parent
ENV_FILE_PATH = BASE_DIR / ".env"

load_dotenv(ENV_FILE_PATH)


@dataclass
class Settings:
    # Uygulama Bilgileri
    APP_NAME: str = "Multi-Tenant Teslimat & PoD Yönetim API"
    API_V1_PREFIX: str = "/api/v1"

    # JWT Güvenlik Ayarları
    JWT_SECRET_KEY: str = field(
        default_factory=lambda: os.getenv(
            "JWT_SECRET_KEY",
            "pod-multi-tenant-super-secret-jwt-key-2026-change-in-prod",
        )
    )
    JWT_ALGORITHM: str = field(default_factory=lambda: os.getenv("JWT_ALGORITHM", "HS256"))
    ACCESS_TOKEN_EXPIRE_MINUTES: int = field(
        default_factory=lambda: int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", str(60 * 24 * 7)))
    )

    # Supabase Bağlantı Ayarları (Boş bırakılırsa yerel SQLite kargo_takip.db devreye girer)
    SUPABASE_URL: str = field(default_factory=lambda: os.getenv("SUPABASE_URL", "").strip())
    SUPABASE_SERVICE_ROLE_KEY: str = field(
        default_factory=lambda: os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    )
    SUPABASE_DB_URL: str = field(
        default_factory=lambda: os.getenv("SUPABASE_DB_URL", os.getenv("DATABASE_URL", "")).strip()
    )
    SUPABASE_STORAGE_BUCKET: str = field(
        default_factory=lambda: os.getenv("SUPABASE_STORAGE_BUCKET", "pod-media").strip()
    )

    # Yerel SQLite Veritabanı, Medya, Excel Arşiv ve Flutter Web (static_web) Klasörleri
    SQLITE_DB_PATH: Path = field(default_factory=lambda: BASE_DIR / "kargo_takip.db")
    LOCAL_DATA_DIR: Path = field(default_factory=lambda: BASE_DIR / "data")
    UPLOADS_DIR: Path = field(default_factory=lambda: BASE_DIR / "uploads")
    POD_MEDIA_DIR: Path = field(default_factory=lambda: BASE_DIR / "uploads" / "pod-media")
    EXCEL_ARCHIVE_DIR: Path = field(default_factory=lambda: BASE_DIR / "excel_arsiv")
    STATIC_WEB_DIR: Path = field(default_factory=lambda: BASE_DIR / "static_web")

    PUBLIC_BASE_URL: str = field(
        default_factory=lambda: os.getenv(
            "PUBLIC_BASE_URL",
            os.getenv("RENDER_EXTERNAL_URL", "http://localhost:8000"),
        ).rstrip("/")
    )
    PUBLIC_TRACKING_WEB_URL: str = field(
        default_factory=lambda: os.getenv(
            "PUBLIC_TRACKING_WEB_URL",
            f"{os.getenv('PUBLIC_BASE_URL', os.getenv('RENDER_EXTERNAL_URL', 'http://localhost:8000')).rstrip('/')}/#/track",
        ).rstrip("/")
    )

    # 24 Saat Konumsal Görünürlük Süresi (Saat)
    DELIVERED_PIN_VISIBILITY_HOURS: int = 24

    # SMTP E-posta Ayarları
    SMTP_HOST: str = field(default_factory=lambda: os.getenv("SMTP_HOST", "smtp.gmail.com"))
    SMTP_PORT: int = field(default_factory=lambda: int(os.getenv("SMTP_PORT", "587")))
    SMTP_USER: str = field(default_factory=lambda: os.getenv("SMTP_USER", ""))
    SMTP_PASSWORD: str = field(default_factory=lambda: os.getenv("SMTP_PASSWORD", ""))
    SMTP_FROM: str = field(default_factory=lambda: os.getenv("SMTP_FROM", "noreply@teslimattakip.com"))
    SMTP_USE_TLS: bool = field(
        default_factory=lambda: os.getenv("SMTP_USE_TLS", "true").lower() == "true"
    )

    @property
    def is_supabase_enabled(self) -> bool:
        return bool(self.SUPABASE_URL and self.SUPABASE_SERVICE_ROLE_KEY)


settings = Settings()
settings.LOCAL_DATA_DIR.mkdir(parents=True, exist_ok=True)
settings.UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
settings.POD_MEDIA_DIR.mkdir(parents=True, exist_ok=True)
settings.EXCEL_ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
settings.STATIC_WEB_DIR.mkdir(parents=True, exist_ok=True)
