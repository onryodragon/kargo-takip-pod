"""
orders.py
---------
Sipariş Oluşturma, Kurye Atama, 24 Saatlik Yönetici Haritası ve
Zorunlu Teslimat Kanıtı (Fotoğraf + İmza) ile Teslimat Tamamlama Uç Noktaları.

İş Kuralları:
- `POST /api/v1/orders` (`require_admin`): Sadece yönetici yeni sipariş açabilir, adres/konum
  ve kurye ataması yapabilir. Otomatik `tracking_token` üretilir.
- `PATCH /api/v1/orders/{order_id}/assign` (`require_admin`): Sadece yönetici kuryeyi,
  adresi veya hedef konumu değiştirebilir. Kurye erişemez.
- `GET /api/v1/orders/admin-map` (`require_admin`): Aktif siparişleri VE son 24 saat içinde
  teslim edilenleri fotoğraf, imza ve `remaining_visibility_minutes` ile döner.
- `GET /api/v1/orders/driver/my-orders` (`require_driver`): Kuryeye sadece kendisine atanmış
  aktif siparişleri salt-okunur döner.
- `POST /api/v1/orders/{order_id}/deliver` (`require_driver`): Zorunlu fotoğraf + imza kontrolü yapar,
  dosyaları `storage_service` ile kaydeder, takip linkini kapatır ve `BackgroundTasks` ile
  arka planda fotoğraflı/imzalı Excel'i işletmenin `report_email` adresine gönderip
  `is_email_archived = True` olarak işaretler.
"""

from __future__ import annotations

import logging
from typing import List, Optional, Union

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    HTTPException,
    Request,
    UploadFile,
    status,
)
from pydantic import BaseModel, Field, ValidationError

from app.core.config import settings
from app.core.database import db
from app.core.security import CurrentUser, require_admin, require_driver
from app.routers.tracking import tracking_ws_manager
from app.services.excel_mailer import ExcelPoDMailerService, OrderPoDRecord
from app.services.storage_service import storage_service

logger = logging.getLogger("pod_system.orders")

router = APIRouter(prefix="/api/v1/orders", tags=["2. Sipariş, Atama, 24s Harita & Zorunlu PoD"])

mailer_service = ExcelPoDMailerService()


# ============================================================================
# ŞEMALAR (PYDANTIC MODELLERİ)
# ============================================================================
class OrderCreateRequest(BaseModel):
    order_number: Optional[str] = Field(
        None,
        description="Boş bırakılırsa otomatik üretilir (Örn: SIP-20261106-A1B2)",
        examples=["SIP-2026-1042"],
    )
    customer_name: str = Field(..., min_length=2, max_length=150, examples=["Ahmet Yılmaz"])
    customer_phone: str = Field(..., min_length=5, max_length=30, examples=["+90 532 000 11 22"])
    delivery_address: str = Field(
        ...,
        min_length=5,
        examples=["Atatürk Mah. Ertuğrul Gazi Sok. No: 14 Ataşehir / İstanbul"],
    )
    delivery_notes: Optional[str] = Field(None, examples=["Zile basmayın, telefonla arayın."])
    dest_lat: float = Field(..., ge=-90.0, le=90.0, examples=[40.992310])
    dest_lng: float = Field(..., ge=-180.0, le=180.0, examples=[29.124420])
    assigned_driver_id: Optional[str] = Field(
        None,
        description="Siparişin atanacağı kuryenin kullanıcı ID'si",
    )


class OrderAdminAssignUpdateRequest(BaseModel):
    assigned_driver_id: Optional[str] = Field(None, description="Yeni atanacak kurye ID'si")
    customer_name: Optional[str] = Field(None, min_length=2, max_length=150)
    customer_phone: Optional[str] = Field(None, min_length=5, max_length=30)
    delivery_address: Optional[str] = Field(None, min_length=5)
    delivery_notes: Optional[str] = None
    dest_lat: Optional[float] = Field(None, ge=-90.0, le=90.0)
    dest_lng: Optional[float] = Field(None, ge=-180.0, le=180.0)
    status: Optional[str] = Field(
        None,
        description="'pending', 'assigned', 'in_transit' veya 'cancelled'",
    )


# ============================================================================
# ARKA PLAN GÖREVİ: EXCEL OLUŞTURMA, E-POSTA GÖNDERİMİ VE DB GÜNCELLEME
# ============================================================================
def _background_send_pod_excel_and_mark_archived(
    *,
    tenant_id: str,
    tenant_name: str,
    report_email: str,
    primary_color_hex: str,
    order_id: str,
    record: OrderPoDRecord,
) -> None:
    """
    FastAPI `BackgroundTasks` içinde çalışır:
    1. Fotoğraf ve imzayı openpyxl ile Excel hücrelerine gömer.
    2. İşletmenin `report_email` adresine SMTP ile gönderir.
    3. Gönderim tamamlandığında siparişi `is_email_archived = True` olarak işaretler.
    """
    try:
        mailer_service.send_pod_excel_email(
            tenant_name=tenant_name,
            report_email=report_email,
            orders=[record],
            primary_color_hex=primary_color_hex,
        )
        db.mark_order_email_archived(tenant_id=tenant_id, order_id=order_id)
        logger.info(
            "Sipariş PoD Excel arşivi tamamlandı ve veritabanında işaretlendi: order_id=%s",
            order_id,
        )
    except Exception as exc:
        logger.error(
            "Arka plan PoD Excel gönderiminde hata oluştu (order_id=%s): %s",
            order_id,
            exc,
        )


# ============================================================================
# UÇ NOKTALAR (ENDPOINTS)
# ============================================================================
@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    summary="Yeni Sipariş Oluştur, Konum Seç ve Kuryeye Ata (Sadece Admin)",
)
async def create_new_order(
    payload: OrderCreateRequest,
    current_user: CurrentUser = Depends(require_admin),
):
    """
    İŞ KURALI #2 & #3:
    - Sadece İşletme Sahibi (`require_admin`) yeni sipariş açabilir, teslimat adresini,
      `dest_lat`, `dest_lng` koordinatlarını ve `assigned_driver_id` bilgisini belirleyebilir.
    - Otomatik olarak benzersiz `tracking_token` üretilir.
    """
    order = db.create_order(
        tenant_id=current_user.tenant_id,
        created_by=current_user.user_id,
        order_number=payload.order_number,
        customer_name=payload.customer_name,
        customer_phone=payload.customer_phone,
        delivery_address=payload.delivery_address,
        delivery_notes=payload.delivery_notes,
        dest_lat=payload.dest_lat,
        dest_lng=payload.dest_lng,
        assigned_driver_id=payload.assigned_driver_id,
    )
    tracking_url = f"{settings.PUBLIC_TRACKING_WEB_URL}/{order['tracking_token']}"
    return {
        **order,
        "tracking_url": tracking_url,
    }


@router.patch(
    "/{order_id}/assign",
    summary="Siparişin Kuryesini, Adresini veya Hedef Konumunu Değiştir (Sadece Admin)",
)
async def update_order_assignment_or_location(
    order_id: str,
    payload: OrderAdminAssignUpdateRequest,
    current_user: CurrentUser = Depends(require_admin),
):
    """
    İŞ KURALI #2:
    Sadece yönetici (`require_admin`) kuryeyi, teslimat adresini veya hedef koordinatları
    değiştirebilir. Kurye bu uç noktaya kesinlikle erişemez (403 Forbidden).
    """
    updates = payload.model_dump(exclude_unset=True)
    if updates.get("status") == "delivered":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Sipariş '/deliver' uç noktasından Fotoğraf + İmza yüklenmeden 'delivered' yapılamaz.",
        )

    updated = db.update_order_admin(
        tenant_id=current_user.tenant_id,
        order_id=order_id,
        updates=updates,
    )
    return {
        **updated,
        "tracking_url": f"{settings.PUBLIC_TRACKING_WEB_URL}/{updated['tracking_token']}",
    }


@router.get(
    "/admin-map",
    summary="Yönetici Haritası: Aktif + Son 24 Saat İçinde Teslim Edilen Siparişler (Sadece Admin)",
)
async def get_admin_map_orders(
    current_user: CurrentUser = Depends(require_admin),
) -> List[dict]:
    """
    İŞ KURALI #5: 24 Saat Konumsal Görünürlük.
    `vw_admin_map_orders` görünümünü kullanarak:
    - Aktif siparişleri (`pending`, `assigned`, `in_transit`) VE
    - Son 24 saat içinde teslim edilmiş (`delivered_at >= NOW() - INTERVAL '24 hours'`) siparişleri
      fotoğraf/imza URL'leri ve kalan görünürlük dakikasıyla (`remaining_visibility_minutes`) döner.
    """
    return db.get_admin_map_orders(current_user.tenant_id)


@router.get(
    "/driver/my-orders",
    summary="Kuryenin Kendisine Atanmış Aktif Siparişlerini Listele (Salt-Okunur)",
)
async def get_driver_assigned_orders(
    current_user: CurrentUser = Depends(require_driver),
) -> List[dict]:
    """
    İŞ KURALI #2:
    Kuryeye sadece kendisine atanmış aktif siparişleri salt-okunur adres ve
    hedef koordinat (`dest_lat`, `dest_lng`) bilgisiyle listeler.
    """
    return db.get_driver_active_orders(
        tenant_id=current_user.tenant_id,
        driver_id=current_user.user_id,
    )


class OrderDeliverRequest(BaseModel):
    """Zorunlu PoD (Fotoğraf + İmza) teslimat tamamlama şeması."""
    recipient_name: str = Field(..., min_length=2, examples=["Ahmet Yılmaz"])
    delivered_lat: float = Field(..., ge=-90.0, le=90.0, examples=[40.992345])
    delivered_lng: float = Field(..., ge=-180.0, le=180.0, examples=[29.124401])
    pod_photo: Optional[str] = Field(
        None,
        description="Base64 (data:image/png;base64,...) formatında teslimat fotoğrafı",
    )
    pod_signature: Optional[str] = Field(
        None,
        description="Base64 (data:image/png;base64,...) formatında alıcı imzası",
    )


@router.post(
    "/{order_id}/deliver",
    summary="Zorunlu Fotoğraf + İmza ile Siparişi Teslim Et ve Arka Planda Excel Gönder (Driver)",
    openapi_extra={
        "requestBody": {
            "required": True,
            "content": {
                "multipart/form-data": {
                    "schema": {
                        "type": "object",
                        "required": [
                            "recipient_name",
                            "delivered_lat",
                            "delivered_lng",
                            "pod_photo",
                            "pod_signature",
                        ],
                        "properties": {
                            "recipient_name": {"type": "string", "example": "Ahmet Yılmaz"},
                            "delivered_lat": {"type": "number", "example": 40.992345},
                            "delivered_lng": {"type": "number", "example": 29.124401},
                            "pod_photo": {
                                "type": "string",
                                "format": "binary",
                                "description": "Zorunlu Teslimat Fotoğrafı (Dosya veya Base64)",
                            },
                            "pod_signature": {
                                "type": "string",
                                "format": "binary",
                                "description": "Zorunlu Alıcı İmzası Görseli (Dosya veya Base64)",
                            },
                        },
                    }
                },
                "application/json": {
                    "schema": OrderDeliverRequest.model_json_schema(),
                },
            },
        }
    },
)
async def deliver_order_with_mandatory_pod(
    order_id: str,
    request: Request,
    background_tasks: BackgroundTasks,
    current_user: CurrentUser = Depends(require_driver),
):
    """
    İŞ KURALI #3, #4, #5 & #6:
    1. Hem `multipart/form-data` (`UploadFile`) hem de `application/json` (`Base64`) destekler.
       `pod_photo` ve `pod_signature` zorunludur; biri dahi eksikse 422 / 400 hatası döner.
    2. Görselleri `storage_service.py` ile kaydeder.
    3. Siparişi `delivered` durumuna çeker, `tracking_link_enabled = False` yapar ve
       açık olan müşteri WebSocket takip ekranını anında kapatır.
    4. Kurye ekranının SMTP e-posta gönderimini beklerken takılmaması için
       `ExcelPoDMailerService` çağrısını FastAPI `BackgroundTasks` ile arka planda çalıştırır,
       işletmenin `report_email` adresine fotoğraflı/imzalı Excel'i gönderir ve
       gönderim bitince `is_email_archived = True` olarak günceller.
    """
    order = db.get_order_by_id(current_user.tenant_id, order_id)
    if order["status"] == "delivered":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Bu sipariş zaten teslim edilmiş.",
        )
    if current_user.role == "driver" and order.get("assigned_driver_id") != current_user.user_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="YETKİ HATASI: Sadece size atanmış olan siparişi tamamlayabilirsiniz.",
        )

    content_type = request.headers.get("content-type", "").lower()
    photo_file: Optional[UploadFile] = None
    sig_file: Optional[UploadFile] = None
    photo_b64: Optional[str] = None
    sig_b64: Optional[str] = None

    if "multipart/form-data" in content_type or "application/x-www-form-urlencoded" in content_type:
        form = await request.form()
        recipient_raw = form.get("recipient_name")
        lat_raw = form.get("delivered_lat")
        lng_raw = form.get("delivered_lng")

        try:
            validated_meta = OrderDeliverRequest(
                recipient_name=str(recipient_raw or "").strip(),
                delivered_lat=float(lat_raw),  # type: ignore[arg-type]
                delivered_lng=float(lng_raw),  # type: ignore[arg-type]
            )
        except (ValidationError, TypeError, ValueError) as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Teslim alan adı ve teslimat koordinatları (delivered_lat, delivered_lng) zorunludur: {exc}",
            ) from exc

        recipient_name = validated_meta.recipient_name
        delivered_lat = validated_meta.delivered_lat
        delivered_lng = validated_meta.delivered_lng

        raw_photo = form.get("pod_photo") or form.get("pod_photo_base64")
        raw_sig = form.get("pod_signature") or form.get("pod_signature_base64")

        if hasattr(raw_photo, "read"):
            photo_file = raw_photo  # type: ignore[assignment]
        elif isinstance(raw_photo, str):
            photo_b64 = raw_photo

        if hasattr(raw_sig, "read"):
            sig_file = raw_sig  # type: ignore[assignment]
        elif isinstance(raw_sig, str):
            sig_b64 = raw_sig
    else:
        try:
            body_json = await request.json()
            validated = OrderDeliverRequest(**body_json)
        except Exception as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Geçersiz teslimat verisi: {exc}",
            ) from exc

        recipient_name = validated.recipient_name
        delivered_lat = validated.delivered_lat
        delivered_lng = validated.delivered_lng
        photo_b64 = validated.pod_photo
        sig_b64 = validated.pod_signature

    # 1. Fotoğraf ve imzayı doğrula ve kaydet (Eksikse 422 / 400 fırlatır)
    photo_url, sig_url, photo_bytes, sig_bytes = await storage_service.save_pod_media(
        tenant_id=current_user.tenant_id,
        order_number=order["order_number"],
        pod_photo_file=photo_file,
        pod_photo_base64=photo_b64,
        pod_signature_file=sig_file,
        pod_signature_base64=sig_b64,
    )

    # 2. Siparişi veritabanında 'delivered' yap ve takip linkini kapat
    updated_order = db.complete_order_delivery(
        tenant_id=current_user.tenant_id,
        order_id=order_id,
        actor_user_id=current_user.user_id,
        actor_role=current_user.role,
        pod_photo_url=photo_url,
        pod_signature_url=sig_url,
        recipient_name=recipient_name,
        delivered_lat=delivered_lat,
        delivered_lng=delivered_lng,
    )

    # 3. Müşteri canlı takip WebSocket odasını anında kapat
    tracking_token = updated_order.get("tracking_token")
    if tracking_token:
        await tracking_ws_manager.close_tracking_room(
            tracking_token,
            "Siparişiniz teslim edilmiştir. Geçici takip bağlantısının süresi dolmuştur.",
        )

    # 4. Arka planda (BackgroundTasks) fotoğraflı + imzalı Excel oluştur ve e-posta gönder
    tenant = db.get_tenant_by_id(current_user.tenant_id)
    driver_user = (
        db.get_user_by_id(current_user.tenant_id, updated_order["assigned_driver_id"])
        if updated_order.get("assigned_driver_id")
        else None
    )

    pod_record = OrderPoDRecord(
        order_number=updated_order["order_number"],
        customer_name=updated_order["customer_name"],
        customer_phone=updated_order["customer_phone"],
        delivery_address=updated_order["delivery_address"],
        driver_name=(
            driver_user["full_name"]
            if driver_user
            else (current_user.full_name or "Saha Kuryesi")
        ),
        driver_plate=driver_user.get("vehicle_plate") if driver_user else None,
        recipient_name=recipient_name,
        delivered_at=updated_order["delivered_at"],
        dest_lat=updated_order["dest_lat"],
        dest_lng=updated_order["dest_lng"],
        delivered_lat=delivered_lat,
        delivered_lng=delivered_lng,
        pod_photo=photo_bytes,
        pod_signature=sig_bytes,
    )

    background_tasks.add_task(
        _background_send_pod_excel_and_mark_archived,
        tenant_id=current_user.tenant_id,
        tenant_name=tenant["name"],
        report_email=tenant["report_email"],
        primary_color_hex=tenant.get("primary_color", "#1E40AF"),
        order_id=order_id,
        record=pod_record,
    )

    return {
        "message": (
            "Teslimat kanıtı (Fotoğraf + İmza) kaydedildi, müşteri takip linki kapatıldı "
            f"ve Excel arşivi {tenant['report_email']} adresine gönderilmek üzere arka plana alındı."
        ),
        "order": updated_order,
        "map_visibility_hours": settings.DELIVERED_PIN_VISIBILITY_HOURS,
    }
