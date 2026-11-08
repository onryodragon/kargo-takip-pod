"""
tracking.py
-----------
Saniyelik (1 Saniye) Canlı Kurye Konum Akışı (`WS /api/v1/tracking/ws/driver-stream`),
WebSocket Broadcast Yöneticisi (Yönetici Haritası + Kurye + Müşteri Takip Ekranı)
ve Müşteri Geçici White-Label Canlı Takip Uç Noktaları.
"""

from __future__ import annotations

import json
import logging
from collections import defaultdict
from typing import Any, Dict, List, Optional, Set

from fastapi import APIRouter, Depends, Query, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

from app.core.database import db
from app.core.security import CurrentUser, decode_access_token, require_driver

logger = logging.getLogger("pod_system.tracking")

router = APIRouter(prefix="/api/v1/tracking", tags=["3. Canlı Konum & Müşteri Geçici Takip"])


# ============================================================================
# WEBSOCKET BAĞLANTI VE YAYIN YÖNETİCİSİ (CONNECTION MANAGER)
# ============================================================================
class TrackingConnectionManager:
    """
    1. `tracking_token` bazlı (Müşteri Geçici İzleme) WebSocket odalarını yönetir.
    2. `tenant_id` bazlı (Yönetici Haritası ve Kurye Ekranları) WebSocket odalarını yönetir.
    Kuryeden her 1 saniyede bir gelen konum sinyallerini ve sipariş silme/atama olaylarını
    aynı saniye içinde tüm ilgili ekranlara yayınlar (Broadcast).
    """

    def __init__(self) -> None:
        self._rooms: Dict[str, Set[WebSocket]] = defaultdict(set)
        self._tenant_rooms: Dict[str, Set[WebSocket]] = defaultdict(set)

    async def connect(self, tracking_token: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self._rooms[tracking_token].add(websocket)

    def disconnect(self, tracking_token: str, websocket: WebSocket) -> None:
        if tracking_token in self._rooms:
            self._rooms[tracking_token].discard(websocket)
            if not self._rooms[tracking_token]:
                del self._rooms[tracking_token]

    async def connect_tenant(self, tenant_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self._tenant_rooms[tenant_id].add(websocket)

    def disconnect_tenant(self, tenant_id: str, websocket: WebSocket) -> None:
        if tenant_id in self._tenant_rooms:
            self._tenant_rooms[tenant_id].discard(websocket)
            if not self._tenant_rooms[tenant_id]:
                del self._tenant_rooms[tenant_id]

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

    async def broadcast_to_tenant(self, tenant_id: str, message: Dict[str, Any]) -> None:
        if tenant_id not in self._tenant_rooms:
            return
        dead_sockets: List[WebSocket] = []
        for ws in list(self._tenant_rooms[tenant_id]):
            try:
                await ws.send_json(message)
            except Exception:
                dead_sockets.append(ws)
        for ws in dead_sockets:
            self.disconnect_tenant(tenant_id, ws)

    async def close_tracking_room(self, tracking_token: str, reason_message: str) -> None:
        """Sipariş teslim edildiğinde veya silindiğinde tüm izleyicilere bildirim gönderip bağlantıyı kapatır."""
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


async def _process_and_broadcast_driver_location(
    *,
    tenant_id: str,
    driver_id: str,
    driver_name: Optional[str],
    lat: float,
    lng: float,
    speed: float = 0.0,
    heading: float = 0.0,
    accuracy: Optional[float] = None,
    battery_level: Optional[int] = None,
    order_id: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Kuryenin konumunu veritabanına yazar ve aynı milisaniye içinde:
    1. Müşteri takip ekranlarına (`tracking_token`)
    2. Yönetici canlı harita ekranına (`tenant_id`)
    WebSocket üzerinden yayınlar.
    """
    log_entry, active_orders = db.record_driver_location(
        tenant_id=tenant_id,
        driver_id=driver_id,
        lat=lat,
        lng=lng,
        speed=speed,
        heading=heading,
        accuracy=accuracy,
        battery_level=battery_level,
        order_id=order_id,
    )

    driver_payload = {
        "driver_id": driver_id,
        "driver_name": driver_name,
        "lat": lat,
        "lng": lng,
        "speed": speed,
        "heading": heading,
        "accuracy": accuracy,
        "battery_level": battery_level,
        "recorded_at": log_entry["recorded_at"],
    }

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
                    "driver_location": driver_payload,
                },
            )
            broadcast_count += 1

    # Yönetici Haritasına (Tenant Room) Saniyelik Canlı Yayın
    await tracking_ws_manager.broadcast_to_tenant(
        tenant_id,
        {
            "event": "driver_location_update",
            "tenant_id": tenant_id,
            "driver_location": driver_payload,
        },
    )

    return {
        "status": "ok",
        "recorded_at": log_entry["recorded_at"],
        "active_orders_notified": broadcast_count,
    }


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
    return await _process_and_broadcast_driver_location(
        tenant_id=current_user.tenant_id,
        driver_id=current_user.user_id,
        driver_name=current_user.full_name,
        lat=payload.lat,
        lng=payload.lng,
        speed=payload.speed,
        heading=payload.heading,
        accuracy=payload.accuracy,
        battery_level=payload.battery_level,
        order_id=payload.order_id,
    )


@router.websocket("/ws/driver-stream")
async def websocket_driver_location_stream(
    websocket: WebSocket,
    token: Optional[str] = Query(None, description="Kurye JWT Access Token"),
):
    """
    GÖREV #5: Kuryenin cihazından her 1 saniyede bir kesintisiz GPS konum akışı alan
    ve aynı saniye içinde Yönetici Haritası ile Müşteri Takip Ekranına yayınlayan WebSocket.
    """
    await websocket.accept()

    user_ctx: Optional[CurrentUser] = None
    if token:
        try:
            user_ctx = decode_access_token(token)
        except Exception:
            await websocket.send_json({"event": "error", "message": "Geçersiz JWT token."})
            await websocket.close(code=1008)
            return

    try:
        while True:
            raw_text = await websocket.receive_text()
            if raw_text.strip().lower() == "ping":
                await websocket.send_json({"event": "pong"})
                continue

            data = json.loads(raw_text)
            if user_ctx is None and data.get("token"):
                user_ctx = decode_access_token(str(data["token"]))

            if user_ctx is None:
                await websocket.send_json({"event": "error", "message": "Yetkilendirme gerekli."})
                continue

            lat = float(data["lat"])
            lng = float(data["lng"])
            speed = float(data.get("speed") or 0.0)
            heading = float(data.get("heading") or 0.0)
            accuracy = float(data["accuracy"]) if data.get("accuracy") is not None else None
            battery_level = (
                int(data["battery_level"]) if data.get("battery_level") is not None else None
            )
            order_id = data.get("order_id")

            res = await _process_and_broadcast_driver_location(
                tenant_id=user_ctx.tenant_id,
                driver_id=user_ctx.user_id,
                driver_name=user_ctx.full_name,
                lat=lat,
                lng=lng,
                speed=speed,
                heading=heading,
                accuracy=accuracy,
                battery_level=battery_level,
                order_id=order_id,
            )
            await websocket.send_json({"event": "ack", **res})
    except WebSocketDisconnect:
        pass
    except Exception as exc:
        logger.debug("Driver stream WebSocket kapandı: %s", exc)


@router.websocket("/ws/tenant/{tenant_id}")
async def websocket_tenant_realtime(
    websocket: WebSocket,
    tenant_id: str,
    token: Optional[str] = Query(None),
):
    """
    Yönetici Haritası ve Kurye ekranları için gerçek zamanlı olay ve 1 saniyelik konum akışı.
    (`driver_location_update`, `order_deleted`, `order_created`, `driver_registered`)
    """
    if token:
        try:
            user_ctx = decode_access_token(token)
            if user_ctx.tenant_id != tenant_id:
                await websocket.accept()
                await websocket.close(code=1008)
                return
        except Exception:
            await websocket.accept()
            await websocket.close(code=1008)
            return

    await tracking_ws_manager.connect_tenant(tenant_id, websocket)
    try:
        while True:
            msg = await websocket.receive_text()
            if msg.strip().lower() == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        tracking_ws_manager.disconnect_tenant(tenant_id, websocket)
    except Exception:
        tracking_ws_manager.disconnect_tenant(tenant_id, websocket)


@router.get(
    "/public/{tracking_token}",
    summary="Müşteri Geçici White-Label Canlı Takip Ekranı Verisi (Public - Auth Gerekmez)",
)
async def get_public_tracking_info(tracking_token: str):
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
            msg = await websocket.receive_text()
            if msg.strip().lower() == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        tracking_ws_manager.disconnect(tracking_token, websocket)
    except Exception:
        tracking_ws_manager.disconnect(tracking_token, websocket)
