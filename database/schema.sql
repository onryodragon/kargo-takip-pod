-- ============================================================================
-- PROJE: Çoklu İşletme Destekli (Multi-Tenant) Teslimat, Canlı Kurye Takip
--        ve Teslimat Kanıtı (PoD) Sistemi
-- VERİTABANI: PostgreSQL / Supabase
-- ============================================================================

-- Gerekli Eklentiler
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. ENUM TİPLERİ
-- ============================================================================
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('admin', 'driver');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE order_status AS ENUM (
        'pending',      -- Sipariş oluşturuldu, atama bekliyor
        'assigned',     -- Kuryeye atandı
        'in_transit',   -- Kurye yola çıktı / dağıtımda
        'delivered',    -- Teslim edildi (Fotoğraf + İmza zorunlu)
        'cancelled'     -- İptal edildi
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- ============================================================================
-- 2. TABLO: tenants (İşletmeler - Multi-Tenant & White-Label Yapısı)
-- ============================================================================
CREATE TABLE IF NOT EXISTS tenants (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            VARCHAR(150) NOT NULL,                      -- İşletme Adı (White-Label başlığı)
    slug            VARCHAR(100) UNIQUE NOT NULL,               -- URL dostu işletme kodu (örn: "yildiz-kargo")
    logo_url        TEXT,                                       -- İşletme Logosu URL
    report_email    VARCHAR(255) NOT NULL,                      -- Excel PoD arşivlerinin gideceği e-posta
    primary_color   VARCHAR(7) DEFAULT '#1E40AF',               -- White-Label tema rengi (HEX)
    phone           VARCHAR(30),                                -- İşletme iletişim numarası
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tenants IS 'Sisteme kayıtlı her bir işletmenin (White-Label) temel ve raporlama ayarları.';

-- ============================================================================
-- 3. TABLO: users (Kullanıcılar - Yönetici [admin] ve Kurye [driver])
-- ============================================================================
CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    role            user_role NOT NULL,                         -- 'admin' veya 'driver'
    full_name       VARCHAR(120) NOT NULL,
    email           VARCHAR(255) UNIQUE NOT NULL,
    phone           VARCHAR(30) NOT NULL,
    password_hash   TEXT NOT NULL,                              -- Supabase Auth kullanılırsa opsiyonel tutulabilir
    vehicle_plate   VARCHAR(25),                                -- Sadece kuryeler için araç plakası (örn: 34 ABC 123)
    vehicle_type    VARCHAR(50),                                -- Motosiklet, Panelvan, Kamyonet vb.
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    is_online       BOOLEAN NOT NULL DEFAULT FALSE,             -- Kurye aktif vardiyada mı?
    last_lat        DOUBLE PRECISION,                           -- Kuryenin bilinen son enlemi
    last_lng        DOUBLE PRECISION,                           -- Kuryenin bilinen son boylamı
    last_seen_at    TIMESTAMPTZ,                                -- Son konum sinyali zamanı
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_tenant_role ON users(tenant_id, role);
CREATE INDEX IF NOT EXISTS idx_users_driver_online ON users(tenant_id, is_online) WHERE role = 'driver';

COMMENT ON TABLE users IS 'İşletme yöneticileri (admin) ve saha kuryeleri (driver).';

-- ============================================================================
-- 4. TABLO: orders (Siparişler, Geçici Takip Linki ve Zorunlu PoD)
-- ============================================================================
CREATE TABLE IF NOT EXISTS orders (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    order_number            VARCHAR(50) NOT NULL,               -- İşletme içi sipariş no (örn: SIP-2026-1042)
    created_by              UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    assigned_driver_id      UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Müşteri ve Teslimat Bilgileri (SADECE ADMIN BELİRLER / DEĞİŞTİREBİLİR)
    customer_name           VARCHAR(150) NOT NULL,
    customer_phone          VARCHAR(30) NOT NULL,
    delivery_address        TEXT NOT NULL,
    delivery_notes          TEXT,
    dest_lat                DOUBLE PRECISION NOT NULL,          -- Hedef Enlem (OSM)
    dest_lng                DOUBLE PRECISION NOT NULL,          -- Hedef Boylam (OSM)

    -- Sipariş Durumu
    status                  order_status NOT NULL DEFAULT 'pending',

    -- Müşteri Geçici Canlı İzleme Linki (Tek tıkla üretilen benzersiz token)
    tracking_token          VARCHAR(64) UNIQUE DEFAULT encode(gen_random_bytes(24), 'hex'),
    tracking_link_enabled   BOOLEAN NOT NULL DEFAULT TRUE,

    -- Zorunlu Teslimat Kanıtı (PoD: Fotoğraf + İmza)
    pod_photo_url           TEXT,                               -- Çekilen teslimat fotoğrafı URL / dosya yolu
    pod_signature_url       TEXT,                               -- Alıcı imzası görseli URL / dosya yolu
    recipient_name          VARCHAR(150),                       -- Teslim alan kişinin adı soyadı
    delivered_lat           DOUBLE PRECISION,                   -- Teslimat anındaki gerçek kurye enlemi
    delivered_lng           DOUBLE PRECISION,                   -- Teslimat anındaki gerçek kurye boylamı
    delivered_at            TIMESTAMPTZ,                        -- Teslimatın tamamlandığı tam zaman

    -- Excel E-posta Arşiv Durumu
    is_email_archived       BOOLEAN NOT NULL DEFAULT FALSE,
    email_archived_at       TIMESTAMPTZ,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- İşletme bazında sipariş numarası tekil olmalı
    CONSTRAINT uq_tenant_order_number UNIQUE (tenant_id, order_number),

    -- İŞ KURALI #4: Fotoğraf ve İmza olmadan sipariş KESİNLİKLE 'delivered' olamaz!
    CONSTRAINT chk_mandatory_pod_on_delivery CHECK (
        status <> 'delivered' OR (
            pod_photo_url IS NOT NULL AND length(trim(pod_photo_url)) > 0 AND
            pod_signature_url IS NOT NULL AND length(trim(pod_signature_url)) > 0 AND
            delivered_at IS NOT NULL
        )
    )
);

-- Performans İndeksleri
CREATE INDEX IF NOT EXISTS idx_orders_tenant_status ON orders(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_driver_active ON orders(assigned_driver_id, status)
    WHERE status IN ('assigned', 'in_transit');
CREATE INDEX IF NOT EXISTS idx_orders_tracking_token ON orders(tracking_token)
    WHERE tracking_link_enabled = TRUE AND status NOT IN ('delivered', 'cancelled');
-- İŞ KURALI #5 (24 Saat Konumsal Görünürlük) için özel indeks:
CREATE INDEX IF NOT EXISTS idx_orders_delivered_24h ON orders(tenant_id, delivered_at DESC)
    WHERE status = 'delivered';

COMMENT ON TABLE orders IS 'Siparişler, müşteri canlı takip tokenı ve zorunlu teslimat kanıtı (fotoğraf+imza) verileri.';

-- ============================================================================
-- 5. TABLO: location_logs (Gerçek Zamanlı Kurye Konum Geçmişi)
-- ============================================================================
CREATE TABLE IF NOT EXISTS location_logs (
    id              BIGSERIAL PRIMARY KEY,
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    driver_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    order_id        UUID REFERENCES orders(id) ON DELETE SET NULL, -- O an aktif taşıdığı sipariş (varsa)
    lat             DOUBLE PRECISION NOT NULL,
    lng             DOUBLE PRECISION NOT NULL,
    speed           REAL DEFAULT 0,                             -- Hız (km/s veya m/s)
    heading         REAL DEFAULT 0,                             -- Yön açısı (0-360 derece)
    accuracy        REAL,                                       -- GPS doğruluk payı (metre)
    battery_level   SMALLINT,                                   -- Kurye cihaz şarj yüzdesi (0-100)
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_location_logs_driver_time ON location_logs(driver_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_location_logs_order_time ON location_logs(order_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_location_logs_tenant_time ON location_logs(tenant_id, recorded_at DESC);

COMMENT ON TABLE location_logs IS 'Kuryelerin anlık GPS koordinat akışı (Supabase Realtime / WebSocket kaynağı).';

-- ============================================================================
-- 6. TETİKLEYİCİLER (TRIGGERS) VE İŞ KURALLARI KORUMASI
-- ============================================================================

-- 6.1. Kurye yeni konum gönderdiğinde `users` tablosundaki son konumunu otomatik güncelle
CREATE OR REPLACE FUNCTION fn_sync_driver_last_location()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE users
    SET last_lat = NEW.lat,
        last_lng = NEW.lng,
        last_seen_at = NEW.recorded_at,
        is_online = TRUE,
        updated_at = NOW()
    WHERE id = NEW.driver_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_driver_last_location ON location_logs;
CREATE TRIGGER trg_sync_driver_last_location
AFTER INSERT ON location_logs
FOR EACH ROW
EXECUTE FUNCTION fn_sync_driver_last_location();

-- 6.2. Sipariş teslim edildiğinde (`delivered`) geçici müşteri takip linkini otomatik kapat
CREATE OR REPLACE FUNCTION fn_handle_order_status_change()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();

    -- İŞ KURALI #3: Sipariş teslim edildiğinde veya iptal edildiğinde takip linki otomatik kapanır
    IF NEW.status IN ('delivered', 'cancelled') THEN
        NEW.tracking_link_enabled := FALSE;
    END IF;

    -- Teslimat durumuna geçildiyse ve delivered_at boşsa otomatik şu anki zamanı ata
    IF NEW.status = 'delivered' AND OLD.status <> 'delivered' AND NEW.delivered_at IS NULL THEN
        NEW.delivered_at := NOW();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_handle_order_status_change ON orders;
CREATE TRIGGER trg_handle_order_status_change
BEFORE UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION fn_handle_order_status_change();

-- 6.3. İŞ KURALI #2: Sıkı Yetki Kontrolü (Kurye adres, hedef konum veya atamayı değiştiremez)
-- Uygulama katmanı `SET LOCAL app.current_user_role = 'driver';` gönderdiğinde veya
-- Supabase JWT claim'inde role = 'driver' olduğunda veritabanı seviyesinde de engeller.
CREATE OR REPLACE FUNCTION fn_prevent_driver_restricted_updates()
RETURNS TRIGGER AS $$
DECLARE
    v_role TEXT;
BEGIN
    v_role := COALESCE(
        current_setting('app.current_user_role', TRUE),
        (NULLIF(current_setting('request.jwt.claims', TRUE), '')::jsonb ->> 'user_role'),
        ''
    );

    IF v_role = 'driver' THEN
        IF NEW.delivery_address IS DISTINCT FROM OLD.delivery_address
           OR NEW.dest_lat IS DISTINCT FROM OLD.dest_lat
           OR NEW.dest_lng IS DISTINCT FROM OLD.dest_lng
           OR NEW.assigned_driver_id IS DISTINCT FROM OLD.assigned_driver_id
           OR NEW.customer_name IS DISTINCT FROM OLD.customer_name
        THEN
            RAISE EXCEPTION 'YETKİ HATASI: Kurye teslimat adresini, hedef koordinatları veya kurye atamasını değiştiremez!';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_driver_restricted_updates ON orders;
CREATE TRIGGER trg_prevent_driver_restricted_updates
BEFORE UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION fn_prevent_driver_restricted_updates();

-- ============================================================================
-- 7. GÖRÜNÜMLER (VIEWS) - 24 SAAT HARİTA GÖRÜNÜRLÜĞÜ & MÜŞTERİ TAKİP EKRANI
-- ============================================================================

-- 7.1. İŞ KURALI #5: Yönetici Haritası Görünümü
-- Aktif siparişleri VE son 24 saat içinde teslim edilmiş siparişleri getirir.
-- 24 saati dolduran teslim edilmiş siparişler bu görünümden otomatik düşer.
CREATE OR REPLACE VIEW vw_admin_map_orders AS
SELECT
    o.id,
    o.tenant_id,
    o.order_number,
    o.customer_name,
    o.customer_phone,
    o.delivery_address,
    o.dest_lat,
    o.dest_lng,
    o.status,
    o.assigned_driver_id,
    u.full_name AS driver_name,
    u.phone AS driver_phone,
    u.vehicle_plate,
    u.last_lat AS driver_live_lat,
    u.last_lng AS driver_live_lng,
    o.pod_photo_url,
    o.pod_signature_url,
    o.delivered_at,
    o.delivered_lat,
    o.delivered_lng,
    o.tracking_token,
    o.tracking_link_enabled,
    -- Haritada pinin kalacağı kalan süre (dakika cinsinden)
    CASE
        WHEN o.status = 'delivered' THEN
            GREATEST(0, EXTRACT(EPOCH FROM ((o.delivered_at + INTERVAL '24 hours') - NOW())) / 60)::INT
        ELSE NULL
    END AS remaining_visibility_minutes
FROM orders o
LEFT JOIN users u ON u.id = o.assigned_driver_id
WHERE
    o.status IN ('pending', 'assigned', 'in_transit')
    OR (
        o.status = 'delivered'
        AND o.delivered_at >= (NOW() - INTERVAL '24 hours')
    );

-- 7.2. İŞ KURALI #1 & #3: Müşteri White-Label Geçici Canlı Takip Görünümü
-- Sadece aktif (`tracking_link_enabled = TRUE` ve teslim edilmemiş) siparişleri döndürür.
CREATE OR REPLACE VIEW vw_public_live_tracking AS
SELECT
    o.tracking_token,
    o.order_number,
    o.status,
    o.customer_name,
    o.delivery_address,
    o.dest_lat,
    o.dest_lng,
    -- White-Label İşletme Bilgileri
    t.name AS tenant_name,
    t.logo_url AS tenant_logo_url,
    t.primary_color AS tenant_primary_color,
    -- Kurye Canlı Konumu
    u.full_name AS driver_name,
    u.vehicle_plate,
    u.last_lat AS driver_lat,
    u.last_lng AS driver_lng,
    u.last_seen_at AS driver_last_seen_at
FROM orders o
JOIN tenants t ON t.id = o.tenant_id
LEFT JOIN users u ON u.id = o.assigned_driver_id
WHERE
    o.tracking_link_enabled = TRUE
    AND o.status IN ('assigned', 'in_transit')
    AND t.is_active = TRUE;

-- ============================================================================
-- 8. SUPABASE REALTIME YAYINI
-- ============================================================================
-- Not: Supabase üzerinde çalıştırıldığında canlı konum ve sipariş durumlarını WebSocket ile yayınlar.
DO $$ BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE location_logs;
    ALTER PUBLICATION supabase_realtime ADD TABLE orders;
EXCEPTION
    WHEN undefined_object THEN null;
    WHEN duplicate_object THEN null;
END $$;
