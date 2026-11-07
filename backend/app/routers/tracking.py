"""
tracking.py
-----------
Canlı Kurye Konum Akışı, WebSocket Broadcast Yöneticisi ve
Müşteri Geçici White-Label Canlı Takip Ekranı Uç Noktaları.

İş Kuralları:
- Kurye (`require_driver`) canlı konum gönderdiğinde hem `users` hem `location_logs`
  güncellenir ve o siparişi izleyen tüm WebSocket istemcilerine anında yayınlanır.
- Müşteri takip linki (`GET /api/v1/tracking/public/{tracking_token}`) herhangi bir
  uygulama indirmeden veya giriş yapmadan (Public) çalışır; üstte işletmenin
  White-Label adını/logosunu/rengini gösterir.
- Sipariş `delivered` olduğunda veya `tracking_link_enabled == False` ise konum
  verisi gizlenir ve "Siparişiniz teslim edilmiştir. Geçici takip bağlantısının süresi dolmuştur." döner.
"""

from __future__ import annotations

import logging
from collections import defaultdict
from typing import Any, Dict, List, Optional, Set

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

from app.core.database import db
from app.core.security import CurrentUser, require_driver

logger = logging.getLogger("pod_system.tracking")

router = APIRouter(prefix="/api/v1/tracking", tags=["3. Canlı Konum & Müşteri Geçici Takip"])


# ============================================================================
# WEBSOCKET BAĞLANTI VE YAYIN YÖNETİCİSİ (CONNECTION MANAGER)
# ============================================================================
class TrackingConnectionManager:
    """
    `tracking_token` bazlı (Müşteri ve Yönetici) WebSocket bağlantılarını yönetir
    ve kuryeden gelen konum sinyallerini milisaniyeler içinde yayınlar.
    """

    def __init__(self) -> None:
        self._rooms: Dict[str, Set[WebSocket]] = defaultdict(set)

    async def connect(self, tracking_token: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self._rooms[tracking_token].add(websocket)
        logger.info("WebSocket bağlandı: token=%s (aktif=%d)", tracking_token[:10], len(self._rooms[tracking_token]))

    def disconnect(self, tracking_token: str, websocket: WebSocket) -> None:
        if tracking_token in self._rooms:
            self._rooms[tracking_token].discard(websocket)
            if not self._rooms[tracking_token]:
                del self._rooms[tracking_token]

    async def broadcast_to_token(self, tracking_token: str, message: Dict[str, Any]) -> None:
        if tracking_token not in self._rooms:
            return
        dead_sockets: List[WebSocket] = []
        for ws in list(self._rooms[tracking_token]):
            try:
                await ws.send_json(message)
            except Exception:
                dead_sockets.append(ws)
        for ws in dead_sockets:
            self.disconnect(tracking_token, ws)

    async def close_tracking_room(self, tracking_token: str, reason_message: str) -> None:
        """Sipariş teslim edildiğinde tüm izleyicilere bildirim gönderip bağlantıyı otomatik kapatır."""
        if tracking_token not in self._rooms:
            return
        sockets = list(self._rooms[tracking_token])
        for ws in sockets:
            try:
                await ws.send_json(
                    {
                        "event": "tracking_expired",
                        "is_active": False,
                        "status": "delivered",
                        "message": reason_message,
                        "driver_location": None,
                    }
                )
                await ws.close(code=1000)
            except Exception:
                pass
            finally:
                self.disconnect(tracking_token, ws)


tracking_ws_manager = TrackingConnectionManager()


# ============================================================================
# ŞEMALAR (PYDANTIC MODELLERİ)
# ============================================================================
class LocationUpdatePayload(BaseModel):
    lat: float = Field(..., ge=-90.0, le=90.0, examples=[40.992345])
    lng: float = Field(..., ge=-180.0, le=180.0, examples=[29.124401])
    speed: float = Field(0.0, ge=0.0, examples=[38.5])
    heading: float = Field(0.0, ge=0.0, le=360.0, examples=[145.0])
    accuracy: Optional[float] = Field(None, examples=[4.2])
    battery_level: Optional[int] = Field(None, ge=0, le=100, examples=[84])
    order_id: Optional[str] = Field(None, description="O an taşınan aktif sipariş ID'si (opsiyonel)")


# ============================================================================
# UÇ NOKTALAR (ENDPOINTS)
# ============================================================================
@router.post(
    "/location",
    summary="Kurye Canlı Konum Gönderimi ve WebSocket Yayını (Driver)",
)
async def update_driver_live_location(
    payload: LocationUpdatePayload,
    current_user: CurrentUser = Depends(require_driver),
):
    """
    Kuryenin anlık `lat`, `lng`, `speed`, `heading`, `battery_level` verisini alır:
    1. `users` tablosundaki son konumu (`last_lat`, `last_lng`, `last_seen_at`) günceller.
    2. `location_logs` tablosuna yeni satır ekler.
    3. Kuryenin aktif taşıdığı siparişlerin `tracking_token` odalarına WebSocket ile anlık yayınlar.
    """
    log_entry, active_orders = db.record_driver_location(
        tenant_id=current_user.tenant_id,
        driver_id=current_user.user_id,
        lat=payload.lat,
        lng=payload.lng,
        speed=payload.speed,
        heading=payload.heading,
        accuracy=payload.accuracy,
        battery_level=payload.battery_level,
        order_id=payload.order_id,
    )

    broadcast_count = 0
    for order in active_orders:
        token = order.get("tracking_token")
        if token and order.get("tracking_link_enabled", True):
            await tracking_ws_manager.broadcast_to_token(
                token,
                {
                    "event": "location_update",
                    "is_active": True,
                    "order_number": order["order_number"],
                    "status": order["status"],
                    "driver_location": {
                        "lat": payload.lat,
                        "lng": payload.lng,
                        "speed": payload.speed,
                        "heading": payload.heading,
                        "battery_level": payload.battery_level,
                        "recorded_at": log_entry["recorded_at"],
                    },
                },
            )
            broadcast_count += 1

    return {
        "status": "ok",
        "recorded_at": log_entry["recorded_at"],
        "active_orders_notified": broadcast_count,
    }


@router.get(
    "/public/{tracking_token}",
    summary="Müşteri Geçici White-Label Canlı Takip Ekranı Verisi (Public - Auth Gerekmez)",
)
async def get_public_tracking_info(tracking_token: str):
    """
    İŞ KURALI #1 & #3:
    - Müşteri kendisine gönderilen linke tıkladığında çalışır (Auth gerektirmez).
    - Üst kısımda göstermek için işletmenin White-Label bilgilerini (`tenant_name`, `logo_url`, `primary_color`) döner.
    - Eğer sipariş `delivered` olmuşsa veya `tracking_link_enabled == False` ise kurye konumunu
      gizleyip `"Siparişiniz teslim edilmiştir. Geçici takip bağlantısının süresi dolmuştur."` döner.
    """
    order, tenant, driver = db.get_order_by_tracking_token(tracking_token)

    white_label_header = {
        "tenant_name": tenant["name"],
        "slug": tenant["slug"],
        "logo_url": tenant.get("logo_url"),
        "primary_color": tenant.get("primary_color", "#1E40AF"),
        "phone": tenant.get("phone"),
    }

    is_expired = (
        order["status"] in ("delivered", "cancelled")
        or not order.get("tracking_link_enabled", True)
    )

    if is_expired:
        return {
            "is_active": False,
            "order_number": order["order_number"],
            "status": order["status"],
            "delivered_at": order.get("delivered_at"),
            "white_label": white_label_header,
            "message": "Siparişiniz teslim edilmiştir. Geçici takip bağlantısının süresi dolmuştur.",
            "destination": None,
            "driver_location": None,
        }

    driver_location = None
    if driver and driver.get("last_lat") is not None and driver.get("last_lng") is not None:
        driver_location = {
            "driver_name": driver["full_name"],
            "vehicle_plate": driver.get("vehicle_plate"),
            "lat": driver["last_lat"],
            "lng": driver["last_lng"],
            "last_seen_at": driver.get("last_seen_at"),
        }

    return {
        "is_active": True,
        "order_number": order["order_number"],
        "status": order["status"],
        "customer_name": order["customer_name"],
        "delivery_address": order["delivery_address"],
        "white_label": white_label_header,
        "message": "Kuryeniz teslimat noktasına doğru hareket halinde.",
        "destination": {
            "lat": order["dest_lat"],
            "lng": order["dest_lng"],
        },
        "driver_location": driver_location,
    }


@router.websocket("/ws/{tracking_token}")
async def websocket_live_tracking(websocket: WebSocket, tracking_token: str):
    """
    Müşteri web sayfası ve yönetici ekranı için gerçek zamanlı konum akışı sağlayan WebSocket uç noktası.
    Sipariş teslim edilmişse veya takip süresi dolmuşsa bilgi mesajı dönüp bağlantıyı kapatır.
    """
    try:
        order, tenant, driver = db.get_order_by_tracking_token(tracking_token)
    except Exception:
        await websocket.accept()
        await websocket.send_json(
            {
                "event": "error",
                "is_active": False,
                "message": "Geçersiz takip bağlantısı.",
            }
        )
        await websocket.close(code=1008)
        return

    is_expired = (
        order["status"] in ("delivered", "cancelled")
        or not order.get("tracking_link_enabled", True)
    )

    if is_expired:
        await websocket.accept()
        await websocket.send_json(
            {
                "event": "tracking_expired",
                "is_active": False,
                "order_number": order["order_number"],
                "status": order["status"],
                "white_label": {
                    "tenant_name": tenant["name"],
                    "logo_url": tenant.get("logo_url"),
                    "primary_color": tenant.get("primary_color", "#1E40AF"),
                },
                "message": "Siparişiniz teslim edilmiştir. Geçici takip bağlantısının süresi dolmuştur.",
                "driver_location": None,
            }
        )
        await websocket.close(code=1000)
        return

    await tracking_ws_manager.connect(tracking_token, websocket)

    # Bağlantı kurulur kurulmaz mevcut başlangıç durumunu gönder
    initial_driver_loc = None
    if driver and driver.get("last_lat") is not None and driver.get("last_lng") is not None:
        initial_driver_loc = {
            "driver_name": driver["full_name"],
            "vehicle_plate": driver.get("vehicle_plate"),
            "lat": driver["last_lat"],
            "lng": driver["last_lng"],
            "last_seen_at": driver.get("last_seen_at"),
        }

    await websocket.send_json(
        {
            "event": "initial_state",
            "is_active": True,
            "order_number": order["order_number"],
            "status": order["status"],
            "white_label": {
                "tenant_name": tenant["name"],
                "logo_url": tenant.get("logo_url"),
                "primary_color": tenant.get("primary_color", "#1E40AF"),
            },
            "destination": {
                "lat": order["dest_lat"],
                "lng": order["dest_lng"],
            },
            "driver_location": initial_driver_loc,
        }
    )

    try:
        while True:
            # İstemciden ping/keepalive mesajlarını dinle
            msg = await websocket.receive_text()
            if msg.strip().lower() == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        tracking_ws_manager.disconnect(tracking_token, websocket)
    except Exception:
        tracking_ws_manager.disconnect(tracking_token, websocket)
