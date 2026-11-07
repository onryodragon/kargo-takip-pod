"""
test_api_flow.py
----------------
Tüm Faz 2, Faz 3, Otomatik Kurulum (`auto_setup.py`), SQLite (`kargo_takip.db`),
Yerel PoD Medya (`uploads/pod-media/`) ve Excel Arşivi (`excel_arsiv/`) kurallarını
uçtan uca doğrulayan ve sonunda Demo Seed verilerini hazır bırakan test betiği.
"""

from __future__ import annotations

import asyncio
import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fastapi import BackgroundTasks, HTTPException
from starlette.requests import Request

from app.core.auto_setup import run_auto_setup
from app.core.config import settings
from app.core.database import db
from app.core.security import CurrentUser, decode_access_token, require_admin, require_driver
from app.routers.orders import (
    OrderCreateRequest,
    create_new_order,
    deliver_order_with_mandatory_pod,
    get_admin_map_orders,
    get_driver_assigned_orders,
)
from app.routers.tenants import (
    DriverCreateRequest,
    LoginRequest,
    TenantRegisterRequest,
    TenantUpdateRequest,
    create_tenant_driver,
    login,
    register_tenant,
    update_my_tenant,
)
from app.routers.tracking import (
    LocationUpdatePayload,
    get_public_tracking_info,
    update_driver_live_location,
)
from app.services.excel_mailer import _create_sample_photo_bytes, _create_sample_signature_bytes


async def run_all_checks() -> None:
    # 0. Sıfır-Manuel Kurulum ve Seed Testi
    db.reset_local_database()
    run_auto_setup()

    # Demo Yönetici (admin@demo.com / 123456) ve Kurye (kurye@demo.com / 123456) giriş kontrolü
    demo_admin_login = await login(LoginRequest(email="admin@demo.com", password="123456"))
    assert demo_admin_login["user"]["role"] == "admin"
    demo_driver_login = await login(LoginRequest(email="kurye@demo.com", password="123456"))
    assert demo_driver_login["user"]["role"] == "driver"

    # 1. Yeni İşletme & Admin Kaydı
    reg_res = await register_tenant(
        TenantRegisterRequest(
            name="Anadolu Lojistik",
            slug="anadolu-lojistik",
            report_email="rapor@anadolulojistik.com",
            primary_color="#0F766E",
            admin_full_name="Olkan Admin",
            admin_email="admin@anadolu.com",
            admin_phone="+905320000000",
            admin_password="password123",
        )
    )
    admin_claims = decode_access_token(reg_res["access_token"])
    admin_user = await require_admin(CurrentUser(**admin_claims))
    assert admin_user.role == "admin"

    # 2. Admin İşletme Rapor E-postasını Günceller
    updated_tenant = await update_my_tenant(
        TenantUpdateRequest(report_email="arsiv@anadolulojistik.com"),
        admin_user,
    )
    assert updated_tenant["report_email"] == "arsiv@anadolulojistik.com"

    # 3. Admin Kurye Ekler
    driver_dict = await create_tenant_driver(
        DriverCreateRequest(
            full_name="Mehmet Kurye",
            email="kurye@anadolu.com",
            phone="+905330000000",
            password="driverpass123",
            vehicle_plate="34 KRG 2026",
            vehicle_type="Motosiklet",
        ),
        admin_user,
    )
    driver_id = driver_dict["id"]

    # 4. Kurye Girişi & Sıkı Rol Kontrolü (Kurye require_admin'den geçemez!)
    login_res = await login(LoginRequest(email="kurye@anadolu.com", password="driverpass123"))
    driver_claims = decode_access_token(login_res["access_token"])
    driver_user = await require_driver(CurrentUser(**driver_claims))
    try:
        await require_admin(driver_user)
        raise AssertionError("Kurye require_admin kontrolünden geçmemeliydi!")
    except HTTPException as exc:
        assert exc.status_code == 403

    # 5. Admin Sipariş Açar ve Kuryeye Atar
    order = await create_new_order(
        OrderCreateRequest(
            order_number="SIP-2026-1042",
            customer_name="Ahmet Yılmaz",
            customer_phone="+905321112233",
            delivery_address="Atatürk Mah. Ataşehir / İstanbul",
            dest_lat=40.9923,
            dest_lng=29.1244,
            assigned_driver_id=driver_id,
        ),
        admin_user,
    )
    order_id = order["id"]
    tracking_token = order["tracking_token"]

    # 6. Kurye Kendi Siparişini Salt-Okunur Görür (tracking_token dahil)
    my_orders = await get_driver_assigned_orders(driver_user)
    assert len(my_orders) == 1 and my_orders[0]["id"] == order_id
    assert my_orders[0]["tracking_token"] == tracking_token

    # 7. Kurye Canlı Konum Gönderir
    loc_res = await update_driver_live_location(
        LocationUpdatePayload(
            lat=40.9910,
            lng=29.1210,
            speed=42.0,
            heading=120.0,
            battery_level=91,
        ),
        driver_user,
    )
    assert loc_res["status"] == "ok"

    # 8. Müşteri Public Geçici Takip Linki (Teslimat Öncesi -> Aktif & White-Label)
    pub_before = await get_public_tracking_info(tracking_token)
    assert pub_before["is_active"] is True
    assert pub_before["white_label"]["tenant_name"] == "Anadolu Lojistik"
    assert pub_before["driver_location"]["lat"] == 40.9910

    # 9. Fotoğraf + İmza ile Teslimatı Tamamla ve Arka Planda Excel Oluştur/Arşivle
    photo_b64 = "data:image/png;base64," + base64.b64encode(_create_sample_photo_bytes()).decode()
    sig_b64 = "data:image/png;base64," + base64.b64encode(_create_sample_signature_bytes()).decode()
    body_bytes = json.dumps(
        {
            "recipient_name": "Ahmet Yılmaz",
            "delivered_lat": 40.99234,
            "delivered_lng": 29.12441,
            "pod_photo": photo_b64,
            "pod_signature": sig_b64,
        }
    ).encode("utf-8")

    async def receive():
        return {"type": "http.request", "body": body_bytes, "more_body": False}

    req = Request(
        {
            "type": "http",
            "method": "POST",
            "headers": [(b"content-type", b"application/json")],
        },
        receive,
    )
    bg = BackgroundTasks()
    deliv_res = await deliver_order_with_mandatory_pod(order_id, req, bg, driver_user)
    assert deliv_res["order"]["status"] == "delivered"

    for task in bg.tasks:
        task.func(*task.args, **task.kwargs)

    archived_order = db.get_order_by_id(admin_user.tenant_id, order_id)
    assert archived_order["is_email_archived"] is True

    # Excel arşiv klasöründe .xlsx dosyalarının oluştuğunu doğrula
    xlsx_files = list(settings.EXCEL_ARCHIVE_DIR.glob("*.xlsx"))
    assert len(xlsx_files) >= 1, "excel_arsiv klasöründe en az 1 .xlsx dosyası oluşmalıydı!"

    # 10. Müşteri Public Takip Linki (Teslimat Sonrası -> Otomatik Kapanmış Olmalı!)
    pub_after = await get_public_tracking_info(tracking_token)
    assert pub_after["is_active"] is False
    assert pub_after["driver_location"] is None
    assert "süresi dolmuştur" in pub_after["message"]

    # 11. 24 Saatlik Yönetici Haritası Kontrolü
    map_orders = await get_admin_map_orders(admin_user)
    assert len(map_orders) == 1
    assert map_orders[0]["status"] == "delivered"
    assert map_orders[0]["remaining_visibility_minutes"] > 1400
    assert "/uploads/pod-media/" in map_orders[0]["pod_photo_url"]
    assert "/uploads/pod-media/" in map_orders[0]["pod_signature_url"]

    # Test sonrası veritabanını temiz bir şekilde sadece Demo Seed verileriyle bırak
    db.reset_local_database()
    run_auto_setup()

    print("BAŞARILI: Tüm Sıfır-Manuel Kurulum, SQLite, Excel Arşiv ve 11 İş Kuralı Testi Geçti!")


if __name__ == "__main__":
    asyncio.run(run_all_checks())
