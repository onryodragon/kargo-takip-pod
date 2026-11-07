"""
auto_setup.py
-------------
Sıfır Manuel Kurulum (Zero-Touch Setup) ve Otomatik Veritabanı İlklendirme Modülü.

Görevleri:
1. `backend/.env` dosyası yoksa varsayılan değerlerle otomatik oluşturur.
2. Yerel medya (`backend/uploads/pod-media/`) ve Excel arşiv (`backend/excel_arsiv/`)
   klasörlerini hazırlar.
3. Supabase bağlantı bilgileri girilmişse `database/schema.sql` şemasını ve `pod-media`
   public bucket'ını Python üzerinden otomatik oluşturur; girilmemişse yerel SQLite
   (`backend/kargo_takip.db`) veritabanını hazırlar.
4. Veritabanı boşsa test için varsayılan:
   - 1 İşletme (`Yıldız Ekspres Kargo`)
   - 1 Yönetici (`admin@demo.com` / `123456`)
   - 1 Kurye (`kurye@demo.com` / `123456`)
   - 2 Örnek Sipariş (1 Aktif Dağıtımda + 1 Son 24 Saat İçinde Teslim Edilmiş, Fotoğraflı/İmzalı ve Excel Arşivli)
   verilerini (Seed Data) otomatik ekler.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app.core.config import BASE_DIR, ENV_FILE_PATH, settings
from app.core.database import db
from app.services.excel_mailer import (
    ExcelPoDMailerService,
    OrderPoDRecord,
    _create_sample_photo_bytes,
    _create_sample_signature_bytes,
)

logger = logging.getLogger("pod_system.auto_setup")

DEFAULT_ENV_CONTENT = """# Otomatik Oluşturulan Ortam Değişkenleri (.env)
JWT_SECRET_KEY=pod-multi-tenant-super-secret-jwt-key-2026-change-in-prod
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=10080

# Sunucu ve Müşteri Geçici Takip Linki Baz URL'leri
PUBLIC_BASE_URL=http://localhost:8000
PUBLIC_TRACKING_WEB_URL=http://localhost:8000/#/track

# Supabase Bağlantısı (Boş bırakıldığında yerel SQLite kargo_takip.db otomatik çalışır)
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
SUPABASE_DB_URL=
SUPABASE_STORAGE_BUCKET=pod-media

# Otomatik Excel PoD Arşiv E-posta (SMTP) Ayarları
# (Boş bırakılsa dahi tüm Excel raporları backend/excel_arsiv/ klasörüne otomatik kaydedilir)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=noreply@teslimattakip.com
SMTP_USE_TLS=true
"""


def ensure_env_and_directories() -> None:
    """`.env` dosyasını ve gerekli tüm yerel dizinleri otomatik oluşturur."""
    if not ENV_FILE_PATH.exists():
        ENV_FILE_PATH.write_text(DEFAULT_ENV_CONTENT, encoding="utf-8")
        logger.info("backend/.env dosyası otomatik oluşturuldu: %s", ENV_FILE_PATH)

    settings.LOCAL_DATA_DIR.mkdir(parents=True, exist_ok=True)
    settings.UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    settings.POD_MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    settings.EXCEL_ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)


def auto_configure_supabase_if_enabled() -> None:
    """
    Supabase bilgileri `.env` içine girilmişse:
    1. `database/schema.sql` dosyasını (SUPABASE_DB_URL varsa) otomatik çalıştırır.
    2. `pod-media` public storage bucket'ını otomatik oluşturur.
    """
    if not settings.is_supabase_enabled or db.supabase_client is None:
        return

    # 1. Public Storage Bucket ('pod-media') Otomatik Oluşturma
    bucket_name = settings.SUPABASE_STORAGE_BUCKET
    try:
        existing_buckets = db.supabase_client.storage.list_buckets()
        bucket_names = [
            (b.name if hasattr(b, "name") else b.get("name"))
            for b in (existing_buckets or [])
        ]
        if bucket_name not in bucket_names:
            db.supabase_client.storage.create_bucket(
                bucket_name,
                options={"public": True},
            )
            logger.info("Supabase public bucket otomatik oluşturuldu: %s", bucket_name)
    except Exception as exc:
        logger.warning("Supabase bucket kontrolü/oluşturulması sırasında uyarı: %s", exc)

    # 2. SUPABASE_DB_URL tanımlıysa database/schema.sql dosyasını otomatik uygula
    schema_path = BASE_DIR.parent / "database" / "schema.sql"
    if settings.SUPABASE_DB_URL and schema_path.exists():
        sql_script = schema_path.read_text(encoding="utf-8")
        try:
            import psycopg  # type: ignore

            with psycopg.connect(settings.SUPABASE_DB_URL, autocommit=True) as conn:
                conn.execute(sql_script)
            logger.info("database/schema.sql Supabase PostgreSQL üzerine otomatik uygulandı.")
        except ImportError:
            try:
                import psycopg2  # type: ignore

                conn = psycopg2.connect(settings.SUPABASE_DB_URL)
                conn.autocommit = True
                with conn.cursor() as cur:
                    cur.execute(sql_script)
                conn.close()
                logger.info("database/schema.sql Supabase PostgreSQL üzerine otomatik uygulandı.")
            except Exception as exc:
                logger.warning("PostgreSQL sürücüsü ile schema.sql uygulanamadı: %s", exc)
        except Exception as exc:
            logger.warning("Supabase schema.sql otomatik uygulama uyarısı: %s", exc)


def seed_initial_demo_data() -> None:
    """
    Veritabanı boşsa varsayılan 1 İşletme, 1 Yönetici (admin@demo.com / 123456),
    1 Kurye (kurye@demo.com / 123456) ve 2 Örnek Siparişi otomatik ekler.
    """
    db.init_sqlite_schema()
    if db.count_tenants() > 0:
        return

    logger.info("Veritabanı boş — Varsayılan Demo İşletme, Yönetici, Kurye ve 2 Sipariş ekleniyor...")

    # 1. Varsayılan İşletme (Tenant) + Yönetici (admin@demo.com / 123456)
    tenant, admin_user = db.register_tenant_and_admin(
        name="Yıldız Ekspres Kargo",
        slug="yildiz-ekspres",
        report_email="arsiv@demo.com",
        logo_url=None,
        primary_color="#1E40AF",
        phone="+90 216 555 00 00",
        admin_full_name="Olkan Yönetici (Demo Admin)",
        admin_email="admin@demo.com",
        admin_phone="+90 532 100 20 30",
        admin_password="123456",
    )

    # 2. Varsayılan Kurye (kurye@demo.com / 123456)
    driver_user = db.create_driver(
        tenant_id=tenant["id"],
        full_name="Mehmet Demir (Saha Kuryesi)",
        email="kurye@demo.com",
        phone="+90 533 200 30 40",
        password="123456",
        vehicle_plate="34 KRG 2026",
        vehicle_type="Motosiklet",
    )

    # Kuryenin başlangıç canlı konumunu kaydet (Ataşehir / İstanbul)
    db.record_driver_location(
        tenant_id=tenant["id"],
        driver_id=driver_user["id"],
        lat=40.990500,
        lng=29.121500,
        speed=34.0,
        heading=115.0,
        accuracy=4.5,
        battery_level=92,
    )

    # 3. Örnek Sipariş #1: Aktif Dağıtımda (Kuryeye Atanmış + Canlı Takip Linki Aktif)
    active_order = db.create_order(
        tenant_id=tenant["id"],
        created_by=admin_user["id"],
        order_number="SIP-2026-1001",
        customer_name="Ayşe Kaya",
        customer_phone="0532 111 22 33",
        delivery_address="Atatürk Mah. Ertuğrul Gazi Sok. No: 14 Kat: 3 Ataşehir / İstanbul",
        delivery_notes="Güvenliğe bırakmayın, zili çalın.",
        dest_lat=40.992310,
        dest_lng=29.124420,
        assigned_driver_id=driver_user["id"],
        tracking_token_override="demo-canli-takip-token-2026",
        status_override="in_transit",
    )

    # 4. Örnek Sipariş #2: Son 24 Saat İçinde Teslim Edilmiş (Yeşil Pin + Fotoğraf + İmza + Excel Arşivi)
    delivered_order = db.create_order(
        tenant_id=tenant["id"],
        created_by=admin_user["id"],
        order_number="SIP-2026-1002",
        customer_name="Burak Özdemir",
        customer_phone="0533 444 55 66",
        delivery_address="Barbaros Mah. Mor Sümbül Sok. No: 7 Batı Ataşehir / İstanbul",
        delivery_notes="Resepsiyona teslim edilebilir.",
        dest_lat=40.986500,
        dest_lng=29.112800,
        assigned_driver_id=driver_user["id"],
    )

    # Örnek teslimat fotoğrafı ve müşteri imzasını `uploads/pod-media/` içine oluştur
    photo_bytes = _create_sample_photo_bytes()
    sig_bytes = _create_sample_signature_bytes()

    order_media_dir = settings.POD_MEDIA_DIR / tenant["id"] / "SIP-2026-1002"
    order_media_dir.mkdir(parents=True, exist_ok=True)
    photo_file = order_media_dir / "photo_seed.png"
    sig_file = order_media_dir / "signature_seed.png"
    photo_file.write_bytes(photo_bytes)
    sig_file.write_bytes(sig_bytes)

    photo_url = f"{settings.PUBLIC_BASE_URL}/uploads/pod-media/{tenant['id']}/SIP-2026-1002/photo_seed.png"
    sig_url = f"{settings.PUBLIC_BASE_URL}/uploads/pod-media/{tenant['id']}/SIP-2026-1002/signature_seed.png"

    delivered_time_dt = datetime.now(timezone.utc) - timedelta(minutes=45)
    completed = db.complete_order_delivery(
        tenant_id=tenant["id"],
        order_id=delivered_order["id"],
        actor_user_id=driver_user["id"],
        actor_role="driver",
        pod_photo_url=photo_url,
        pod_signature_url=sig_url,
        recipient_name="Burak Özdemir (Kendisi)",
        delivered_lat=40.986520,
        delivered_lng=29.112815,
        delivered_at_override=delivered_time_dt.isoformat(),
    )

    # Örnek Sipariş #2 için fotoğraflı ve imzalı Excel dosyasını `backend/excel_arsiv/` klasörüne kaydet
    mailer = ExcelPoDMailerService()
    mailer.send_pod_excel_email(
        tenant_name=tenant["name"],
        report_email=tenant["report_email"],
        orders=[
            OrderPoDRecord(
                order_number=completed["order_number"],
                customer_name=completed["customer_name"],
                customer_phone=completed["customer_phone"],
                delivery_address=completed["delivery_address"],
                driver_name=driver_user["full_name"],
                driver_plate=driver_user["vehicle_plate"],
                recipient_name="Burak Özdemir (Kendisi)",
                delivered_at=delivered_time_dt,
                dest_lat=completed["dest_lat"],
                dest_lng=completed["dest_lng"],
                delivered_lat=40.986520,
                delivered_lng=29.112815,
                pod_photo=photo_bytes,
                pod_signature=sig_bytes,
            )
        ],
        primary_color_hex=tenant["primary_color"],
    )
    db.mark_order_email_archived(tenant_id=tenant["id"], order_id=delivered_order["id"])

    logger.info(
        "Otomatik Seed tamamlandı! Admin: admin@demo.com / 123456 | Kurye: kurye@demo.com / 123456 | "
        "Aktif Takip Token: %s",
        active_order["tracking_token"],
    )


def run_auto_setup() -> None:
    """Uygulama ayağa kalkarken tüm sıfır-manuel kurulum adımlarını sırasıyla çalıştırır."""
    ensure_env_and_directories()
    auto_configure_supabase_if_enabled()
    seed_initial_demo_data()
