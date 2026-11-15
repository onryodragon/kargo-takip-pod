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
   (`backend/kargo_takip.db`) veritabanı tablolarını hazırlar.
4. Geçmişten kalan demo/test verilerini (`admin@demo.com`, `kurye@demo.com`, örnek siparişler)
   otomatik olarak temizler. Hazır test hesabı oluşturmaz; her işletme kendi e-postası ile
   tamamen izole (`tenant_id`) çalışma alanı kurar.
"""

from __future__ import annotations

import logging
import shutil

from app.core.config import BASE_DIR, ENV_FILE_PATH, settings
from app.core.database import db

logger = logging.getLogger("pod_system.auto_setup")

DEFAULT_ENV_CONTENT = """# Otomatik Oluşturulan Ortam Değişkenleri (.env)
JWT_SECRET_KEY=pod-multi-tenant-super-secret-jwt-key-2026-change-in-prod
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=10080

# Sunucu ve Müşteri Geçici Takip Linki Baz URL'leri
PUBLIC_BASE_URL=https://kargo-takip-pod.onrender.com
PUBLIC_TRACKING_WEB_URL=https://kargo-takip-pod.onrender.com/#/track

# Supabase Bağlantısı (Boş bırakıldığında yerel SQLite kargo_takip.db otomatik çalışır)
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
SUPABASE_DB_URL=
SUPABASE_STORAGE_BUCKET=pod-media

# Otomatik Excel PoD Arşiv E-posta (SMTP) Ayarları
# (Boş bırakılsa dahi tüm Excel raporları backend/excel_arsiv/ klasörüne otomatik kaydedilir)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=GONDERICI_GMAIL_ADRESIN@gmail.com
SMTP_PASSWORD=16_HANELI_UYGULAMA_SIFREN
SMTP_FROM=GONDERICI_GMAIL_ADRESIN@gmail.com
SMTP_USE_TLS=true
SMTP_FALLBACK_PORTS=465,587,2525
EMAIL_DELIVERY_ORDER=smtp,http
RESEND_API_KEY=
BREVO_API_KEY=
SENDGRID_API_KEY=
GOOGLE_APPS_SCRIPT_URL=
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


def cleanup_legacy_demo_data() -> None:
    """
    Veritabanı şemasını hazırlar ve geçmişten kalan tüm demo/seed kayıtlarını
    (`admin@demo.com`, `kurye@demo.com`, örnek işletme ve örnek siparişleri) temizler.
    """
    db.init_sqlite_schema()
    purged_tenant_ids = db.purge_demo_data()

    # Demo medya ve demo Excel dosyalarını temizle
    for t_id in purged_tenant_ids:
        demo_media_dir = settings.POD_MEDIA_DIR / t_id
        if demo_media_dir.exists():
            shutil.rmtree(demo_media_dir, ignore_errors=True)

    if settings.EXCEL_ARCHIVE_DIR.exists():
        for xlsx_file in settings.EXCEL_ARCHIVE_DIR.glob("*Yildiz_Ekspres*"):
            try:
                xlsx_file.unlink()
            except Exception:
                pass


def ensure_huawei_reviewer_accounts() -> None:
    """
    Huawei AppGallery Connect inceleme ekibi için otomatik hazır test hesaplarını ve
    örnek siparişleri oluşturur (Sadece mevcut değilse ilklendirilir).
    """
    admin_email = "appgallery_admin@kargotakip.com"
    driver_email = "appgallery_driver@kargotakip.com"

    try:
        if db.supabase_client:
            res = (
                db.supabase_client.table("users")
                .select("id, tenant_id")
                .eq("email", admin_email)
                .execute()
            )
            exists = bool(res.data)
        else:
            with db._lock, db._get_sqlite_conn() as conn:
                row = conn.execute(
                    "SELECT id, tenant_id FROM users WHERE email = ?",
                    (admin_email,),
                ).fetchone()
                exists = bool(row)

        if exists:
            logger.info("Huawei AppGallery test hesapları zaten mevcut.")
            return

        # 1. İşletme ve Yöneticiyi Oluştur
        tenant, admin = db.register_tenant_and_admin(
            name="Huawei AppGallery Test Lojistik",
            slug="huawei-test-lojistik",
            report_email=admin_email,
            logo_url=None,
            primary_color="#1E40AF",
            phone="+905550002026",
            admin_full_name="Huawei Store Reviewer",
            admin_email=admin_email,
            admin_phone="+905550002026",
            admin_password="HuaweiTest2026!",
        )
        tenant_id = tenant["id"]
        admin_id = admin["id"]

        # 2. Saha Kuryesini Oluştur
        driver = db.create_driver(
            tenant_id=tenant_id,
            full_name="Ahmet Huawei",
            email=driver_email,
            phone="+905550002026",
            password="HuaweiTest2026!",
            vehicle_plate="34 HWI 2026",
            vehicle_type="Panelvan",
        )
        driver_id = driver["id"]

        # 3. Kuryeyi Çevrimiçi Yap ve Canlı Konum Kaydet (Kadıköy / Moda)
        try:
            db.record_driver_location(
                tenant_id=tenant_id,
                driver_id=driver_id,
                lat=40.9850,
                lng=29.0300,
                speed=28.5,
                heading=45.0,
                accuracy=10.0,
                battery_level=92,
            )
        except Exception as loc_err:
            logger.debug("Kurye başlangıç konumu ekleme uyarısı: %s", loc_err)

        # 4. İnceleme Ekibi İçin 2 Adet Hazır Test Siparişi Ekle
        # Sipariş 1: Atanmamış, Beklemede
        db.create_order(
            tenant_id=tenant_id,
            created_by=admin_id,
            order_number="HWI-1001",
            customer_name="Canan Özdemir",
            customer_phone="+905321112233",
            delivery_address="Levent Mah. Büyükdere Cad. No:199, Şişli / İstanbul",
            delivery_notes="Güvenliğe teslim edilebilir, zil arızalı.",
            dest_lat=41.0782,
            dest_lng=29.0115,
            assigned_driver_id=None,
            status_override="pending",
        )

        # Sipariş 2: Kuryeye Atanmış, Yolda (Canlı Takip Edilebilir)
        db.create_order(
            tenant_id=tenant_id,
            created_by=admin_id,
            order_number="HWI-1002",
            customer_name="Murat Kaya",
            customer_phone="+905423334455",
            delivery_address="Bağdat Cad. No:340, Kadıköy / İstanbul",
            delivery_notes="Giriş kat, lütfen gelmeden 5 dk önce arayınız.",
            dest_lat=40.9632,
            dest_lng=29.0684,
            assigned_driver_id=driver_id,
            status_override="in_transit",
        )

        logger.info(
            "Huawei AppGallery test hesapları (%s / %s) ve siparişleri (HWI-1001, HWI-1002) oluşturuldu.",
            admin_email,
            driver_email,
        )
    except Exception as exc:
        logger.warning("Huawei inceleme hesapları oluşturulurken hata: %s", exc)


def run_auto_setup() -> None:
    """Uygulama ayağa kalkarken tüm sıfır-manuel kurulum adımlarını sırasıyla çalıştırır."""
    ensure_env_and_directories()
    auto_configure_supabase_if_enabled()
    cleanup_legacy_demo_data()
    ensure_huawei_reviewer_accounts()
