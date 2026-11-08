"""
database.py
-----------
Çoklu İşletme (Multi-Tenant) Veri Erişim Katmanı (Supabase + Yerel SQLite `kargo_takip.db`).

Özellikler:
- `.env` içinde `SUPABASE_URL` ve `SUPABASE_SERVICE_ROLE_KEY` tanımlıysa doğrudan
  Supabase (PostgreSQL) tabloları ve `vw_admin_map_orders` görünümüyle çalışır.
- Supabase bilgileri girilmemişse hiçbir hata vermeden `backend/kargo_takip.db` (SQLite)
  üzerinde birebir aynı tablo şemasını (`tenants`, `users`, `orders`, `location_logs`),
  zorunlu PoD `CHECK` kısıtını ve 24 saatlik harita görünürlük kurallarını çalıştırır.
- Tüm sorgularda `tenant_id` izolasyonu zorunludur.
"""

from __future__ import annotations

import logging
import re
import secrets
import sqlite3
import threading
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

from fastapi import HTTPException, status

from app.core.config import settings
from app.core.security import hash_password, verify_password
from app.services.routing_service import optimize_orders_nearest_neighbor

logger = logging.getLogger("pod_system.database")

try:
    from supabase import Client, create_client
except ImportError:
    Client = Any  # type: ignore
    create_client = None  # type: ignore


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _utc_now_iso() -> str:
    return _utc_now().isoformat()


def _parse_iso(dt_str: Optional[str]) -> Optional[datetime]:
    if not dt_str:
        return None
    try:
        dt = datetime.fromisoformat(str(dt_str).replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None


SQLITE_SCHEMA_DDL = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tenants (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    slug            TEXT UNIQUE NOT NULL,
    logo_url        TEXT,
    report_email    TEXT NOT NULL,
    primary_color   TEXT DEFAULT '#1E40AF',
    phone           TEXT,
    is_active       INTEGER NOT NULL DEFAULT 1,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id              TEXT PRIMARY KEY,
    tenant_id       TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    role            TEXT NOT NULL CHECK (role IN ('admin', 'driver')),
    full_name       TEXT NOT NULL,
    email           TEXT UNIQUE NOT NULL,
    phone           TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    vehicle_plate   TEXT,
    vehicle_type    TEXT,
    is_active       INTEGER NOT NULL DEFAULT 1,
    is_online       INTEGER NOT NULL DEFAULT 0,
    last_lat        REAL,
    last_lng        REAL,
    last_seen_at    TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_users_tenant_role ON users(tenant_id, role);

CREATE TABLE IF NOT EXISTS orders (
    id                      TEXT PRIMARY KEY,
    tenant_id               TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    order_number            TEXT NOT NULL,
    created_by              TEXT NOT NULL REFERENCES users(id),
    assigned_driver_id      TEXT REFERENCES users(id) ON DELETE SET NULL,
    customer_name           TEXT NOT NULL,
    customer_phone          TEXT NOT NULL,
    delivery_address        TEXT NOT NULL,
    delivery_notes          TEXT,
    dest_lat                REAL NOT NULL,
    dest_lng                REAL NOT NULL,
    status                  TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'assigned', 'in_transit', 'delivered', 'cancelled')),
    tracking_token          TEXT UNIQUE NOT NULL,
    tracking_link_enabled   INTEGER NOT NULL DEFAULT 1,
    pod_photo_url           TEXT,
    pod_signature_url       TEXT,
    recipient_name          TEXT,
    delivered_lat           REAL,
    delivered_lng           REAL,
    delivered_at            TEXT,
    is_email_archived       INTEGER NOT NULL DEFAULT 0,
    email_archived_at       TEXT,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    UNIQUE(tenant_id, order_number),
    CONSTRAINT chk_mandatory_pod_on_delivery CHECK (
        status <> 'delivered' OR (
            pod_photo_url IS NOT NULL AND length(trim(pod_photo_url)) > 0 AND
            pod_signature_url IS NOT NULL AND length(trim(pod_signature_url)) > 0 AND
            delivered_at IS NOT NULL
        )
    )
);

CREATE INDEX IF NOT EXISTS idx_orders_tenant_status ON orders(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_tracking_token ON orders(tracking_token);

CREATE TABLE IF NOT EXISTS location_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    tenant_id       TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    driver_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    order_id        TEXT REFERENCES orders(id) ON DELETE SET NULL,
    lat             REAL NOT NULL,
    lng             REAL NOT NULL,
    speed           REAL DEFAULT 0.0,
    heading         REAL DEFAULT 0.0,
    accuracy        REAL,
    battery_level   INTEGER,
    recorded_at     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_location_logs_driver_time ON location_logs(driver_id, recorded_at DESC);
"""


def _normalize_row(row: Dict[str, Any]) -> Dict[str, Any]:
    """SQLite 0/1 integer boolean alanlarını Python bool değerine dönüştürür."""
    bool_fields = (
        "is_active",
        "is_online",
        "tracking_link_enabled",
        "is_email_archived",
    )
    out = dict(row)
    for bf in bool_fields:
        if bf in out and out[bf] is not None:
            out[bf] = bool(out[bf])
    return out


class MultiTenantRepository:
    """
    Supabase ve Yerel SQLite (`kargo_takip.db`) arasında şeffaf çalışan,
    Multi-Tenant (`tenant_id`) güvenlik izolasyonlu veri katmanı.
    """

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._sqlite_path = settings.SQLITE_DB_PATH
        self._supabase: Optional[Client] = None

        if settings.is_supabase_enabled and create_client is not None:
            try:
                self._supabase = create_client(
                    settings.SUPABASE_URL,
                    settings.SUPABASE_SERVICE_ROLE_KEY,
                )
                logger.info("Supabase bağlantısı aktif edildi: %s", settings.SUPABASE_URL)
            except Exception as exc:
                logger.warning("Supabase başlatılamadı, yerel SQLite kullanılacak: %s", exc)
                self._supabase = None

        self.init_sqlite_schema()

    @property
    def supabase_client(self) -> Optional[Client]:
        return self._supabase

    def _get_sqlite_conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self._sqlite_path), check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON;")
        return conn

    def init_sqlite_schema(self) -> None:
        """Yerel `kargo_takip.db` SQLite tablolarını ve kısıtlarını oluşturur."""
        with self._lock:
            self._sqlite_path.parent.mkdir(parents=True, exist_ok=True)
            with self._get_sqlite_conn() as conn:
                conn.executescript(SQLITE_SCHEMA_DDL)
                conn.commit()

    def reset_local_database(self) -> None:
        """Test senaryoları için yerel SQLite veritabanını sıfırlar."""
        with self._lock:
            if self._sqlite_path.exists():
                with self._get_sqlite_conn() as conn:
                    conn.executescript(
                        """
                        DELETE FROM location_logs;
                        DELETE FROM orders;
                        DELETE FROM users;
                        DELETE FROM tenants;
                        """
                    )
                    conn.commit()
            else:
                self.init_sqlite_schema()

    def count_tenants(self) -> int:
        if self._supabase:
            res = self._supabase.table("tenants").select("id").limit(1).execute()
            return len(res.data)
        with self._lock, self._get_sqlite_conn() as conn:
            row = conn.execute("SELECT COUNT(*) AS cnt FROM tenants").fetchone()
            return int(row["cnt"]) if row else 0

    def purge_demo_data(self) -> List[str]:
        """
        Geçmişten kalan tüm demo/seed kayıtlarını (`admin@demo.com`, `kurye@demo.com`,
        `arsiv@demo.com`, `yildiz-ekspres`, `demo-canli-takip-token-2026`) veritabanından siler.
        Silinen `tenant_id` listesini döner.
        """
        purged_tenant_ids: List[str] = []
        demo_emails = ("admin@demo.com", "kurye@demo.com", "arsiv@demo.com")

        if self._supabase:
            try:
                t_res = (
                    self._supabase.table("tenants")
                    .select("id")
                    .or_("slug.eq.yildiz-ekspres,report_email.eq.arsiv@demo.com")
                    .execute()
                )
                for row in t_res.data or []:
                    tid = row["id"]
                    purged_tenant_ids.append(tid)
                    self._supabase.table("tenants").delete().eq("id", tid).execute()
                for em in demo_emails:
                    self._supabase.table("users").delete().eq("email", em).execute()
            except Exception as exc:
                logger.debug("Supabase demo temizleme uyarısı: %s", exc)

        with self._lock, self._get_sqlite_conn() as conn:
            rows = conn.execute(
                """
                SELECT DISTINCT id FROM tenants
                WHERE slug = 'yildiz-ekspres'
                   OR report_email = 'arsiv@demo.com'
                   OR id IN (
                       SELECT tenant_id FROM users
                       WHERE email IN ('admin@demo.com', 'kurye@demo.com')
                          OR email LIKE '%@demo.com'
                   )
                """
            ).fetchall()
            for r in rows:
                purged_tenant_ids.append(str(r["id"]))

            if purged_tenant_ids:
                placeholders = ",".join("?" for _ in purged_tenant_ids)
                conn.execute(
                    f"DELETE FROM location_logs WHERE tenant_id IN ({placeholders})",
                    purged_tenant_ids,
                )
                conn.execute(
                    f"DELETE FROM orders WHERE tenant_id IN ({placeholders})",
                    purged_tenant_ids,
                )
                conn.execute(
                    f"DELETE FROM users WHERE tenant_id IN ({placeholders})",
                    purged_tenant_ids,
                )
                conn.execute(
                    f"DELETE FROM tenants WHERE id IN ({placeholders})",
                    purged_tenant_ids,
                )
            conn.execute(
                "DELETE FROM orders WHERE tracking_token = 'demo-canli-takip-token-2026'"
            )
            conn.execute(
                "DELETE FROM users WHERE email IN ('admin@demo.com', 'kurye@demo.com') OR email LIKE '%@demo.com'"
            )
            conn.commit()

        if purged_tenant_ids:
            logger.info("Demo/test verileri temizlendi (silinen tenant sayısı: %d)", len(purged_tenant_ids))
        return purged_tenant_ids

    @staticmethod
    def _build_slug(raw_slug: Optional[str], company_name: str) -> str:
        source = (raw_slug or "").strip() or company_name.strip()
        tr_map = str.maketrans("çğıöşüÇĞİÖŞÜ", "cgiosuCGIOSU")
        normalized = source.translate(tr_map).lower()
        slug_val = re.sub(r"[^a-z0-9]+", "-", normalized).strip("-")
        return slug_val or f"isletme-{secrets.token_hex(3)}"

    # -------------------------------------------------------------------------
    # 1. İŞLETME (TENANT) VE KULLANICI YÖNETİMİ
    # -------------------------------------------------------------------------
    def register_tenant_and_admin(
        self,
        *,
        name: str,
        slug: Optional[str],
        report_email: Optional[str],
        logo_url: Optional[str],
        primary_color: str,
        phone: Optional[str],
        admin_full_name: str,
        admin_email: str,
        admin_phone: str,
        admin_password: str,
    ) -> Tuple[Dict[str, Any], Dict[str, Any]]:
        """
        Yeni işletmeyi (`tenants`) ve ilk yöneticiyi (`users` role='admin') tek işlemde oluşturur.
        E-posta merkezli %100 veri izolasyonu:
        - Kayıt olan e-posta kendi benzersiz `tenant_id` çalışma alanını oluşturur.
        - `report_email` girilmemişse otomatik olarak yönetici e-postası (`admin_email`) atanır.
        """
        clean_email = admin_email.strip().lower()
        effective_report_email = (
            report_email.strip().lower()
            if report_email and report_email.strip()
            else clean_email
        )
        clean_slug = self._build_slug(slug, name)
        pw_hash = hash_password(admin_password)
        now_iso = _utc_now_iso()

        if self._supabase:
            existing_user = (
                self._supabase.table("users").select("id").eq("email", clean_email).execute()
            )
            if existing_user.data:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"'{clean_email}' e-posta adresi zaten kayıtlı.",
                )
            existing_slug = (
                self._supabase.table("tenants").select("id").eq("slug", clean_slug).execute()
            )
            if existing_slug.data:
                clean_slug = f"{clean_slug}-{secrets.token_hex(2)}"

            tenant_res = (
                self._supabase.table("tenants")
                .insert(
                    {
                        "name": name.strip(),
                        "slug": clean_slug,
                        "logo_url": logo_url,
                        "report_email": effective_report_email,
                        "primary_color": primary_color or "#1E40AF",
                        "phone": phone,
                        "is_active": True,
                    }
                )
                .execute()
            )
            tenant = tenant_res.data[0]
            try:
                user_res = (
                    self._supabase.table("users")
                    .insert(
                        {
                            "tenant_id": tenant["id"],
                            "role": "admin",
                            "full_name": admin_full_name.strip(),
                            "email": clean_email,
                            "phone": admin_phone.strip(),
                            "password_hash": pw_hash,
                            "is_active": True,
                        }
                    )
                    .execute()
                )
                return tenant, user_res.data[0]
            except Exception as exc:
                self._supabase.table("tenants").delete().eq("id", tenant["id"]).execute()
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail=f"Yönetici hesabı oluşturulurken hata oluştu, işlem geri alındı: {exc}",
                ) from exc

        with self._lock, self._get_sqlite_conn() as conn:
            if conn.execute("SELECT 1 FROM users WHERE email = ?", (clean_email,)).fetchone():
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"'{clean_email}' e-posta adresi zaten kayıtlı.",
                )
            if conn.execute("SELECT 1 FROM tenants WHERE slug = ?", (clean_slug,)).fetchone():
                clean_slug = f"{clean_slug}-{secrets.token_hex(2)}"

            tenant_id = str(uuid.uuid4())
            admin_id = str(uuid.uuid4())

            conn.execute(
                """
                INSERT INTO tenants (id, name, slug, logo_url, report_email, primary_color, phone, is_active, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                (
                    tenant_id,
                    name.strip(),
                    clean_slug,
                    logo_url,
                    effective_report_email,
                    primary_color or "#1E40AF",
                    phone,
                    now_iso,
                    now_iso,
                ),
            )
            conn.execute(
                """
                INSERT INTO users (id, tenant_id, role, full_name, email, phone, password_hash, is_active, is_online, created_at, updated_at)
                VALUES (?, ?, 'admin', ?, ?, ?, ?, 1, 0, ?, ?)
                """,
                (
                    admin_id,
                    tenant_id,
                    admin_full_name.strip(),
                    clean_email,
                    admin_phone.strip(),
                    pw_hash,
                    now_iso,
                    now_iso,
                ),
            )
            conn.commit()

            tenant_row = conn.execute("SELECT * FROM tenants WHERE id = ?", (tenant_id,)).fetchone()
            user_row = conn.execute("SELECT * FROM users WHERE id = ?", (admin_id,)).fetchone()
            return _normalize_row(dict(tenant_row)), _normalize_row(dict(user_row))

    def authenticate_user(self, email: str, password: str) -> Tuple[Dict[str, Any], Dict[str, Any]]:
        """E-posta ve şifre ile kullanıcıyı doğrular, (user, tenant) döner."""
        clean_email = email.strip().lower()

        if self._supabase:
            user_res = (
                self._supabase.table("users")
                .select("*")
                .eq("email", clean_email)
                .eq("is_active", True)
                .execute()
            )
            if not user_res.data:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="E-posta adresi veya şifre hatalı.",
                )
            user = user_res.data[0]
            if not verify_password(password, user["password_hash"]):
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="E-posta adresi veya şifre hatalı.",
                )
            tenant = self.get_tenant_by_id(user["tenant_id"])
            return user, tenant

        with self._lock, self._get_sqlite_conn() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE email = ? AND is_active = 1",
                (clean_email,),
            ).fetchone()
            if not row:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="E-posta adresi veya şifre hatalı.",
                )
            user = _normalize_row(dict(row))
            if not verify_password(password, user["password_hash"]):
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="E-posta adresi veya şifre hatalı.",
                )
            tenant = self.get_tenant_by_id(user["tenant_id"])
            return user, tenant

    def get_tenant_by_id(self, tenant_id: str) -> Dict[str, Any]:
        if self._supabase:
            res = self._supabase.table("tenants").select("*").eq("id", tenant_id).execute()
            if not res.data:
                raise HTTPException(status_code=404, detail="İşletme (Tenant) bulunamadı.")
            return res.data[0]

        with self._lock, self._get_sqlite_conn() as conn:
            row = conn.execute("SELECT * FROM tenants WHERE id = ?", (tenant_id,)).fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="İşletme (Tenant) bulunamadı.")
            return _normalize_row(dict(row))

    def update_tenant(self, tenant_id: str, updates: Dict[str, Any]) -> Dict[str, Any]:
        """Sadece ilgili `tenant_id` kaydının White-Label ve `report_email` ayarlarını günceller."""
        allowed = {"name", "logo_url", "report_email", "primary_color", "phone"}
        clean_updates = {k: v for k, v in updates.items() if k in allowed and v is not None}
        clean_updates["updated_at"] = _utc_now_iso()

        if self._supabase:
            res = (
                self._supabase.table("tenants")
                .update(clean_updates)
                .eq("id", tenant_id)
                .execute()
            )
            if not res.data:
                raise HTTPException(status_code=404, detail="İşletme bulunamadı.")
            return res.data[0]

        with self._lock, self._get_sqlite_conn() as conn:
            set_clause = ", ".join(f"{k} = ?" for k in clean_updates.keys())
            values = list(clean_updates.values()) + [tenant_id]
            conn.execute(f"UPDATE tenants SET {set_clause} WHERE id = ?", values)
            conn.commit()
            return self.get_tenant_by_id(tenant_id)

    def create_driver(
        self,
        *,
        tenant_id: str,
        full_name: str,
        email: str,
        phone: str,
        password: str,
        vehicle_plate: Optional[str],
        vehicle_type: Optional[str],
    ) -> Dict[str, Any]:
        """İşletmeye (`tenant_id`) yeni bir saha kuryesi (`role='driver'`) ekler."""
        clean_email = email.strip().lower()
        pw_hash = hash_password(password)
        now_iso = _utc_now_iso()

        if self._supabase:
            existing = self._supabase.table("users").select("id").eq("email", clean_email).execute()
            if existing.data:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"'{clean_email}' e-posta adresi zaten kullanımda.",
                )
            res = (
                self._supabase.table("users")
                .insert(
                    {
                        "tenant_id": tenant_id,
                        "role": "driver",
                        "full_name": full_name.strip(),
                        "email": clean_email,
                        "phone": phone.strip(),
                        "password_hash": pw_hash,
                        "vehicle_plate": vehicle_plate,
                        "vehicle_type": vehicle_type,
                        "is_active": True,
                        "is_online": False,
                    }
                )
                .execute()
            )
            return res.data[0]

        with self._lock, self._get_sqlite_conn() as conn:
            if conn.execute("SELECT 1 FROM users WHERE email = ?", (clean_email,)).fetchone():
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"'{clean_email}' e-posta adresi zaten kullanımda.",
                )
            driver_id = str(uuid.uuid4())
            conn.execute(
                """
                INSERT INTO users (
                    id, tenant_id, role, full_name, email, phone, password_hash,
                    vehicle_plate, vehicle_type, is_active, is_online, created_at, updated_at
                )
                VALUES (?, ?, 'driver', ?, ?, ?, ?, ?, ?, 1, 0, ?, ?)
                """,
                (
                    driver_id,
                    tenant_id,
                    full_name.strip(),
                    clean_email,
                    phone.strip(),
                    pw_hash,
                    vehicle_plate,
                    vehicle_type,
                    now_iso,
                    now_iso,
                ),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM users WHERE id = ?", (driver_id,)).fetchone()
            return _normalize_row(dict(row))

    def list_drivers(self, tenant_id: str) -> List[Dict[str, Any]]:
        """Sadece ilgili `tenant_id` işletmesine ait kuryeleri listeler."""
        if self._supabase:
            res = (
                self._supabase.table("users")
                .select(
                    "id, tenant_id, role, full_name, email, phone, vehicle_plate, "
                    "vehicle_type, is_active, is_online, last_lat, last_lng, last_seen_at, created_at"
                )
                .eq("tenant_id", tenant_id)
                .eq("role", "driver")
                .order("created_at", desc=True)
                .execute()
            )
            return res.data

        with self._lock, self._get_sqlite_conn() as conn:
            rows = conn.execute(
                """
                SELECT id, tenant_id, role, full_name, email, phone, vehicle_plate,
                       vehicle_type, is_active, is_online, last_lat, last_lng, last_seen_at, created_at
                FROM users
                WHERE tenant_id = ? AND role = 'driver'
                ORDER BY created_at DESC
                """,
                (tenant_id,),
            ).fetchall()
            return [_normalize_row(dict(r)) for r in rows]

    def get_user_by_id(self, tenant_id: str, user_id: str) -> Optional[Dict[str, Any]]:
        if self._supabase:
            res = (
                self._supabase.table("users")
                .select("*")
                .eq("tenant_id", tenant_id)
                .eq("id", user_id)
                .execute()
            )
            return res.data[0] if res.data else None

        with self._lock, self._get_sqlite_conn() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE tenant_id = ? AND id = ?",
                (tenant_id, user_id),
            ).fetchone()
            return _normalize_row(dict(row)) if row else None

    # -------------------------------------------------------------------------
    # 2. SİPARİŞLER, ATAMA, 24 SAATLİK HARİTA VE ZORUNLU PoD
    # -------------------------------------------------------------------------
    def create_order(
        self,
        *,
        tenant_id: str,
        created_by: str,
        order_number: Optional[str],
        customer_name: str,
        customer_phone: str,
        delivery_address: str,
        delivery_notes: Optional[str],
        dest_lat: float,
        dest_lng: float,
        assigned_driver_id: Optional[str],
        tracking_token_override: Optional[str] = None,
        status_override: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        İŞ KURALI #2 & #3:
        Sadece Admin yeni sipariş açabilir, teslimat koordinatlarını ve kuryeyi belirleyebilir.
        Otomatik olarak benzersiz `tracking_token` üretilir.
        """
        if assigned_driver_id:
            driver = self.get_user_by_id(tenant_id, assigned_driver_id)
            if not driver or driver.get("role") != "driver":
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Atanmak istenen kurye bu işletmede bulunamadı veya kurye rolünde değil.",
                )

        generated_number = (
            order_number.strip()
            if order_number and order_number.strip()
            else f"SIP-{_utc_now().strftime('%Y%m%d')}-{secrets.token_hex(2).upper()}"
        )
        tracking_token = tracking_token_override or secrets.token_hex(24)
        initial_status = status_override or ("assigned" if assigned_driver_id else "pending")
        now_iso = _utc_now_iso()

        if self._supabase:
            res = (
                self._supabase.table("orders")
                .insert(
                    {
                        "tenant_id": tenant_id,
                        "order_number": generated_number,
                        "created_by": created_by,
                        "assigned_driver_id": assigned_driver_id,
                        "customer_name": customer_name.strip(),
                        "customer_phone": customer_phone.strip(),
                        "delivery_address": delivery_address.strip(),
                        "delivery_notes": delivery_notes,
                        "dest_lat": dest_lat,
                        "dest_lng": dest_lng,
                        "status": initial_status,
                        "tracking_token": tracking_token,
                        "tracking_link_enabled": True,
                    }
                )
                .execute()
            )
            return res.data[0]

        with self._lock, self._get_sqlite_conn() as conn:
            if conn.execute(
                "SELECT 1 FROM orders WHERE tenant_id = ? AND order_number = ?",
                (tenant_id, generated_number),
            ).fetchone():
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"Bu işletmede '{generated_number}' numaralı sipariş zaten mevcut.",
                )

            order_id = str(uuid.uuid4())
            conn.execute(
                """
                INSERT INTO orders (
                    id, tenant_id, order_number, created_by, assigned_driver_id,
                    customer_name, customer_phone, delivery_address, delivery_notes,
                    dest_lat, dest_lng, status, tracking_token, tracking_link_enabled,
                    is_email_archived, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?)
                """,
                (
                    order_id,
                    tenant_id,
                    generated_number,
                    created_by,
                    assigned_driver_id,
                    customer_name.strip(),
                    customer_phone.strip(),
                    delivery_address.strip(),
                    delivery_notes,
                    float(dest_lat),
                    float(dest_lng),
                    initial_status,
                    tracking_token,
                    now_iso,
                    now_iso,
                ),
            )
            conn.commit()
            return self.get_order_by_id(tenant_id, order_id)

    def get_order_by_id(self, tenant_id: str, order_id: str) -> Dict[str, Any]:
        if self._supabase:
            res = (
                self._supabase.table("orders")
                .select("*")
                .eq("tenant_id", tenant_id)
                .eq("id", order_id)
                .execute()
            )
            if not res.data:
                raise HTTPException(status_code=404, detail="Sipariş bulunamadı.")
            return res.data[0]

        with self._lock, self._get_sqlite_conn() as conn:
            row = conn.execute(
                "SELECT * FROM orders WHERE tenant_id = ? AND id = ?",
                (tenant_id, order_id),
            ).fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Sipariş bulunamadı.")
            return _normalize_row(dict(row))

    def update_order_admin(
        self,
        tenant_id: str,
        order_id: str,
        updates: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        İŞ KURALI #2: Sadece Admin tarafından çağrılabilir.
        Kurye atamasını, teslimat adresini, hedef koordinatları ve durumu günceller.
        """
        order = self.get_order_by_id(tenant_id, order_id)
        if order["status"] == "delivered":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Teslim edilmiş bir siparişin adresi veya kuryesi değiştirilemez.",
            )

        if "assigned_driver_id" in updates and updates["assigned_driver_id"]:
            driver = self.get_user_by_id(tenant_id, updates["assigned_driver_id"])
            if not driver or driver.get("role") != "driver":
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Atanmak istenen kurye bu işletmede bulunamadı.",
                )
            if order["status"] == "pending" and "status" not in updates:
                updates["status"] = "assigned"

        allowed = {
            "assigned_driver_id",
            "customer_name",
            "customer_phone",
            "delivery_address",
            "delivery_notes",
            "dest_lat",
            "dest_lng",
            "status",
        }
        clean_updates = {k: v for k, v in updates.items() if k in allowed and v is not None}
        clean_updates["updated_at"] = _utc_now_iso()

        if self._supabase:
            res = (
                self._supabase.table("orders")
                .update(clean_updates)
                .eq("tenant_id", tenant_id)
                .eq("id", order_id)
                .execute()
            )
            return res.data[0]

        with self._lock, self._get_sqlite_conn() as conn:
            set_clause = ", ".join(f"{k} = ?" for k in clean_updates.keys())
            values = list(clean_updates.values()) + [tenant_id, order_id]
            conn.execute(
                f"UPDATE orders SET {set_clause} WHERE tenant_id = ? AND id = ?",
                values,
            )
            conn.commit()
            return self.get_order_by_id(tenant_id, order_id)

    def get_admin_map_orders(self, tenant_id: str) -> List[Dict[str, Any]]:
        """
        İŞ KURALI #5: 24 Saat Konumsal Görünürlük + Akıllı Durak Numaralandırma.
        `vw_admin_map_orders` mantığıyla:
        - Sadece ilgili `tenant_id` işletmesine ait aktif siparişleri (`pending`, `assigned`, `in_transit`) VE
        - Son 24 saat içinde teslim edilmiş (`delivered_at >= NOW() - 24 saat`) siparişleri
          fotoğraf, imza ve `remaining_visibility_minutes` ile birlikte döner.
        - Kuryelere atanmış aktif siparişleri En Yakın Komşu (Nearest-Neighbor / TSP)
          algoritmasıyla sıralayıp `stop_sequence` ve `stop_label` ("1. Durak (En Yakın)", "2. Durak"...) ekler.
        """
        raw_orders: List[Dict[str, Any]] = []

        if self._supabase:
            res = (
                self._supabase.table("vw_admin_map_orders")
                .select("*")
                .eq("tenant_id", tenant_id)
                .execute()
            )
            raw_orders = [dict(r) for r in (res.data or [])]
        else:
            now = _utc_now()
            cutoff = now - timedelta(hours=settings.DELIVERED_PIN_VISIBILITY_HOURS)

            with self._lock, self._get_sqlite_conn() as conn:
                rows = conn.execute(
                    """
                    SELECT o.*,
                           u.full_name AS driver_name,
                           u.phone AS driver_phone,
                           u.vehicle_plate AS vehicle_plate,
                           u.last_lat AS driver_live_lat,
                           u.last_lng AS driver_live_lng
                    FROM orders o
                    LEFT JOIN users u ON u.id = o.assigned_driver_id
                    WHERE o.tenant_id = ?
                    ORDER BY o.created_at DESC
                    """,
                    (tenant_id,),
                ).fetchall()

                for raw in rows:
                    o = _normalize_row(dict(raw))
                    st = o["status"]
                    remaining_minutes: Optional[int] = None

                    if st in ("pending", "assigned", "in_transit"):
                        pass
                    elif st == "delivered":
                        delivered_dt = _parse_iso(o.get("delivered_at"))
                        if not delivered_dt or delivered_dt < cutoff:
                            continue
                        expires_at = delivered_dt + timedelta(
                            hours=settings.DELIVERED_PIN_VISIBILITY_HOURS
                        )
                        remaining_minutes = max(0, int((expires_at - now).total_seconds() // 60))
                    else:
                        continue

                    o["remaining_visibility_minutes"] = remaining_minutes
                    raw_orders.append(o)

        # Kuryelere atanmış aktif siparişleri kurye bazında Nearest-Neighbor ile numaralandır
        by_driver: Dict[str, List[Dict[str, Any]]] = {}
        unassigned_active: List[Dict[str, Any]] = []
        delivered_list: List[Dict[str, Any]] = []

        for item in raw_orders:
            if item.get("status") == "delivered":
                delivered_list.append(item)
            elif item.get("assigned_driver_id"):
                drv_id = str(item["assigned_driver_id"])
                by_driver.setdefault(drv_id, []).append(item)
            else:
                unassigned_active.append(item)

        optimized_active: List[Dict[str, Any]] = []
        for drv_id, drv_orders in by_driver.items():
            start_lat = drv_orders[0].get("driver_live_lat")
            start_lng = drv_orders[0].get("driver_live_lng")
            sorted_drv = optimize_orders_nearest_neighbor(
                drv_orders,
                start_lat=float(start_lat) if start_lat is not None else None,
                start_lng=float(start_lng) if start_lng is not None else None,
            )
            optimized_active.extend(sorted_drv)

        return optimized_active + unassigned_active + delivered_list

    def get_driver_active_orders(
        self,
        tenant_id: str,
        driver_id: str,
        current_lat: Optional[float] = None,
        current_lng: Optional[float] = None,
    ) -> List[Dict[str, Any]]:
        """
        Kuryeye SADECE kendi işletmesinde (`tenant_id`) ve SADECE kendisine atanmış
        (`assigned_driver_id == driver_id`) aktif siparişleri En Yakın Komşu (Nearest-Neighbor)
        sırasına dizilmiş olarak salt-okunur döner.
        """
        orders: List[Dict[str, Any]] = []
        if self._supabase:
            res = (
                self._supabase.table("orders")
                .select(
                    "id, order_number, customer_name, customer_phone, delivery_address, "
                    "delivery_notes, dest_lat, dest_lng, status, tracking_token, "
                    "tracking_link_enabled, created_at, updated_at"
                )
                .eq("tenant_id", tenant_id)
                .eq("assigned_driver_id", driver_id)
                .in_("status", ["assigned", "in_transit"])
                .order("created_at", desc=False)
                .execute()
            )
            orders = [dict(r) for r in (res.data or [])]
        else:
            with self._lock, self._get_sqlite_conn() as conn:
                rows = conn.execute(
                    """
                    SELECT id, order_number, customer_name, customer_phone, delivery_address,
                           delivery_notes, dest_lat, dest_lng, status, tracking_token,
                           tracking_link_enabled, created_at, updated_at
                    FROM orders
                    WHERE tenant_id = ?
                      AND assigned_driver_id = ?
                      AND status IN ('assigned', 'in_transit')
                    ORDER BY created_at ASC
                    """,
                    (tenant_id, driver_id),
                ).fetchall()
                orders = [_normalize_row(dict(r)) for r in rows]

        if not orders:
            return []

        s_lat = current_lat
        s_lng = current_lng
        if s_lat is None or s_lng is None:
            drv = self.get_user_by_id(tenant_id, driver_id)
            if drv and drv.get("last_lat") is not None and drv.get("last_lng") is not None:
                s_lat = float(drv["last_lat"])
                s_lng = float(drv["last_lng"])

        return optimize_orders_nearest_neighbor(
            orders,
            start_lat=s_lat,
            start_lng=s_lng,
        )

    def complete_order_delivery(
        self,
        *,
        tenant_id: str,
        order_id: str,
        actor_user_id: str,
        actor_role: str,
        pod_photo_url: str,
        pod_signature_url: str,
        recipient_name: str,
        delivered_lat: float,
        delivered_lng: float,
        delivered_at_override: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        İŞ KURALI #3 & #4:
        - Fotoğraf ve imza URL'leri zorunludur.
        - Kurye yalnızca kendisine atanmış siparişi tamamlayabilir.
        - Sipariş `delivered` yapılır ve `tracking_link_enabled = False` ile takip linki kapatılır.
        """
        if not pod_photo_url or not pod_signature_url:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Teslimat fotoğrafı ve alıcı imzası olmadan sipariş tamamlanamaz!",
            )

        order = self.get_order_by_id(tenant_id, order_id)
        if order["status"] == "delivered":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Bu sipariş zaten teslim edilmiş.",
            )

        if actor_role == "driver" and order.get("assigned_driver_id") != actor_user_id:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="YETKİ HATASI: Sadece size atanmış olan siparişi teslim edebilirsiniz.",
            )

        now_iso = delivered_at_override or _utc_now_iso()

        if self._supabase:
            updates = {
                "status": "delivered",
                "pod_photo_url": pod_photo_url,
                "pod_signature_url": pod_signature_url,
                "recipient_name": recipient_name.strip(),
                "delivered_lat": float(delivered_lat),
                "delivered_lng": float(delivered_lng),
                "delivered_at": now_iso,
                "tracking_link_enabled": False,
                "updated_at": now_iso,
            }
            res = (
                self._supabase.table("orders")
                .update(updates)
                .eq("tenant_id", tenant_id)
                .eq("id", order_id)
                .execute()
            )
            return res.data[0]

        with self._lock, self._get_sqlite_conn() as conn:
            conn.execute(
                """
                UPDATE orders
                SET status = 'delivered',
                    pod_photo_url = ?,
                    pod_signature_url = ?,
                    recipient_name = ?,
                    delivered_lat = ?,
                    delivered_lng = ?,
                    delivered_at = ?,
                    tracking_link_enabled = 0,
                    updated_at = ?
                WHERE tenant_id = ? AND id = ?
                """,
                (
                    pod_photo_url,
                    pod_signature_url,
                    recipient_name.strip(),
                    float(delivered_lat),
                    float(delivered_lng),
                    now_iso,
                    now_iso,
                    tenant_id,
                    order_id,
                ),
            )
            conn.commit()
            return self.get_order_by_id(tenant_id, order_id)

    def mark_order_email_archived(self, tenant_id: str, order_id: str) -> None:
        """Arka planda Excel arşivi oluşturulduktan/gönderildikten sonra `is_email_archived = True` yapar."""
        now_iso = _utc_now_iso()
        if self._supabase:
            self._supabase.table("orders").update(
                {"is_email_archived": True, "email_archived_at": now_iso, "updated_at": now_iso}
            ).eq("tenant_id", tenant_id).eq("id", order_id).execute()
            return

        with self._lock, self._get_sqlite_conn() as conn:
            conn.execute(
                """
                UPDATE orders
                SET is_email_archived = 1,
                    email_archived_at = ?,
                    updated_at = ?
                WHERE tenant_id = ? AND id = ?
                """,
                (now_iso, now_iso, tenant_id, order_id),
            )
            conn.commit()

    # -------------------------------------------------------------------------
    # 3. CANLI KONUM VE GEÇİCİ MÜŞTERİ TAKİP LİNKİ
    # -------------------------------------------------------------------------
    def record_driver_location(
        self,
        *,
        tenant_id: str,
        driver_id: str,
        lat: float,
        lng: float,
        speed: float = 0.0,
        heading: float = 0.0,
        accuracy: Optional[float] = None,
        battery_level: Optional[int] = None,
        order_id: Optional[str] = None,
    ) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
        """
        Kuryenin anlık konumunu hem `users` tablosuna hem `location_logs` tablosuna yazar.
        Ayrıca kuryenin üzerindeki aktif siparişleri döndürür ki WebSocket üzerinden yayınlansın.
        """
        now_iso = _utc_now_iso()

        if self._supabase:
            log_res = (
                self._supabase.table("location_logs")
                .insert(
                    {
                        "tenant_id": tenant_id,
                        "driver_id": driver_id,
                        "order_id": order_id,
                        "lat": lat,
                        "lng": lng,
                        "speed": speed,
                        "heading": heading,
                        "accuracy": accuracy,
                        "battery_level": battery_level,
                        "recorded_at": now_iso,
                    }
                )
                .execute()
            )
            self._supabase.table("users").update(
                {
                    "last_lat": lat,
                    "last_lng": lng,
                    "last_seen_at": now_iso,
                    "is_online": True,
                    "updated_at": now_iso,
                }
            ).eq("tenant_id", tenant_id).eq("id", driver_id).execute()

            active_orders = (
                self._supabase.table("orders")
                .select("id, order_number, tracking_token, status, tracking_link_enabled")
                .eq("tenant_id", tenant_id)
                .eq("assigned_driver_id", driver_id)
                .in_("status", ["assigned", "in_transit"])
                .execute()
            ).data
            return log_res.data[0], active_orders

        with self._lock, self._get_sqlite_conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET last_lat = ?,
                    last_lng = ?,
                    last_seen_at = ?,
                    is_online = 1,
                    updated_at = ?
                WHERE tenant_id = ? AND id = ?
                """,
                (float(lat), float(lng), now_iso, now_iso, tenant_id, driver_id),
            )
            cursor = conn.execute(
                """
                INSERT INTO location_logs (
                    tenant_id, driver_id, order_id, lat, lng, speed, heading, accuracy, battery_level, recorded_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    tenant_id,
                    driver_id,
                    order_id,
                    float(lat),
                    float(lng),
                    float(speed),
                    float(heading),
                    accuracy,
                    battery_level,
                    now_iso,
                ),
            )
            log_id = cursor.lastrowid
            active_rows = conn.execute(
                """
                SELECT id, order_number, tracking_token, status, tracking_link_enabled
                FROM orders
                WHERE tenant_id = ?
                  AND assigned_driver_id = ?
                  AND status IN ('assigned', 'in_transit')
                """,
                (tenant_id, driver_id),
            ).fetchall()
            conn.commit()

            log_entry = {
                "id": log_id,
                "tenant_id": tenant_id,
                "driver_id": driver_id,
                "order_id": order_id,
                "lat": float(lat),
                "lng": float(lng),
                "speed": float(speed),
                "heading": float(heading),
                "accuracy": accuracy,
                "battery_level": battery_level,
                "recorded_at": now_iso,
            }
            return log_entry, [_normalize_row(dict(r)) for r in active_rows]

    def get_order_by_tracking_token(
        self, tracking_token: str
    ) -> Tuple[Dict[str, Any], Dict[str, Any], Optional[Dict[str, Any]]]:
        """
        Public müşteri takip ekranı için `tracking_token` üzerinden
        (order, tenant, driver) üçlüsünü döner.
        """
        clean_token = tracking_token.strip()

        if self._supabase:
            res = (
                self._supabase.table("orders")
                .select("*")
                .eq("tracking_token", clean_token)
                .execute()
            )
            if not res.data:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="Geçersiz veya bulunamayan takip bağlantısı.",
                )
            order = res.data[0]
            tenant = self.get_tenant_by_id(order["tenant_id"])
            driver = (
                self.get_user_by_id(order["tenant_id"], order["assigned_driver_id"])
                if order.get("assigned_driver_id")
                else None
            )
            return order, tenant, driver

        with self._lock, self._get_sqlite_conn() as conn:
            row = conn.execute(
                "SELECT * FROM orders WHERE tracking_token = ?",
                (clean_token,),
            ).fetchone()
            if not row:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="Geçersiz veya bulunamayan takip bağlantısı.",
                )
            order = _normalize_row(dict(row))
            tenant = self.get_tenant_by_id(order["tenant_id"])
            driver = (
                self.get_user_by_id(order["tenant_id"], order["assigned_driver_id"])
                if order.get("assigned_driver_id")
                else None
            )
            return order, tenant, driver


db = MultiTenantRepository()
