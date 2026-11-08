"""
main.py
-------
Çoklu İşletme Destekli (Multi-Tenant) Teslimat, Canlı Kurye Takip
ve Teslimat Kanıtı (PoD) Sistemi — FastAPI + Flutter Web Tek Çatı Giriş Noktası.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Annotated, List, Optional
from urllib.request import Request as UrlRequest, urlopen

from fastapi import BackgroundTasks, FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, StringConstraints

from app.core.auto_setup import run_auto_setup
from app.core.config import settings
from app.routers import auth, orders, tenants, tracking
from app.services.excel_mailer import ExcelPoDMailerService, OrderPoDRecord

logger = logging.getLogger("pod_system.main")

RENDER_KEEP_ALIVE_URL = "https://kargo-takip-pod.onrender.com/api/v1/health"
RENDER_KEEP_ALIVE_INTERVAL_SECONDS = 600  # 10 dakika

EmailAddress = Annotated[
    str,
    StringConstraints(pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$", strip_whitespace=True),
]

# Uygulama yüklenirken sıfır-manuel kurulum ve veritabanı şemasını hazırla
run_auto_setup()


def _ping_render_health_sync() -> None:
    req = UrlRequest(
        RENDER_KEEP_ALIVE_URL,
        headers={"User-Agent": "Render-KeepAlive-Service/1.0"},
    )
    with urlopen(req, timeout=15.0) as resp:
        resp.read()


async def _render_keep_alive_loop() -> None:
    """
    Render ücretsiz planda sunucunun 15 dakika hareketsizlik sonrası uyku moduna
    geçmesini önlemek için her 10 dakikada bir `https://kargo-takip-pod.onrender.com/api/v1/health`
    adresine otomatik istek atar.
    """
    while True:
        await asyncio.sleep(RENDER_KEEP_ALIVE_INTERVAL_SECONDS)
        try:
            await asyncio.to_thread(_ping_render_health_sync)
            logger.info("Render Keep-Alive ping başarılı: %s", RENDER_KEEP_ALIVE_URL)
        except asyncio.CancelledError:
            break
        except Exception as exc:
            logger.debug("Render Keep-Alive ping uyarısı: %s", exc)


@asynccontextmanager
async def lifespan(app_instance: FastAPI):
    run_auto_setup()
    keep_alive_task = asyncio.create_task(_render_keep_alive_loop())
    try:
        yield
    finally:
        keep_alive_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await keep_alive_task


app = FastAPI(
    title=settings.APP_NAME,
    description=(
        "Huawei AppGallery (GMS Bağımsız) Uyumlu Çoklu İşletme (Multi-Tenant) Kurye Takip, "
        "White-Label Müşteri İzleme, 24 Saat Harita Görünürlüğü ve Fotoğraf+İmza Gömülü Excel Raporlama API"
    ),
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 1. Teslimat Fotoğrafı, İmza görselleri (/uploads/pod-media/...) ve Excel arşivlerini statik sun
app.mount("/uploads", StaticFiles(directory=str(settings.UPLOADS_DIR)), name="uploads")
app.mount("/excel_arsiv", StaticFiles(directory=str(settings.EXCEL_ARCHIVE_DIR)), name="excel_arsiv")

# 2. Modüler API ve WebSocket Router'larını Bağla (/api/v1/...)
app.include_router(auth.router)
app.include_router(tenants.router)
app.include_router(orders.router)
app.include_router(tracking.router)

mailer_service = ExcelPoDMailerService()


class OrderPoDPayload(BaseModel):
    order_number: str = Field(..., examples=["SIP-2026-1042"])
    customer_name: str = Field(..., examples=["Ahmet Yılmaz"])
    customer_phone: str = Field(..., examples=["+90 532 000 11 22"])
    delivery_address: str = Field(..., examples=["Atatürk Mah. Ataşehir / İstanbul"])
    driver_name: str = Field(..., examples=["Mehmet Demir"])
    driver_plate: Optional[str] = Field(None, examples=["34 KRG 2026"])
    recipient_name: Optional[str] = Field(None, examples=["Ahmet Yılmaz"])
    dest_lat: float = Field(..., examples=[40.992310])
    dest_lng: float = Field(..., examples=[29.124420])
    delivered_lat: Optional[float] = Field(None, examples=[40.992345])
    delivered_lng: Optional[float] = Field(None, examples=[29.124401])
    pod_photo_source: str = Field(
        ...,
        description="Teslimat fotoğrafı URL'si veya Base64 (data:image/png;base64,...)",
    )
    pod_signature_source: str = Field(
        ...,
        description="Alıcı imzası URL'si veya Base64 (data:image/png;base64,...)",
    )


class TenantArchiveRequest(BaseModel):
    tenant_name: str = Field(..., examples=["Yıldız Ekspres Kargo"])
    report_email: EmailAddress = Field(..., examples=["rapor@yildizekspres.com"])
    primary_color_hex: str = Field("#1E40AF", examples=["#1E40AF"])
    orders: List[OrderPoDPayload]


@app.get("/health", tags=["Sistem Durumu"])
@app.get("/api/v1/health", tags=["Sistem Durumu"])
async def health_check():
    return {
        "status": "healthy",
        "render_url": "https://kargo-takip-pod.onrender.com",
        "keep_alive_interval_seconds": RENDER_KEEP_ALIVE_INTERVAL_SECONDS,
        "supabase_connected": settings.is_supabase_enabled,
        "storage_mode": "supabase" if settings.is_supabase_enabled else "sqlite (kargo_takip.db)",
        "web_ui_bundled": (settings.STATIC_WEB_DIR / "index.html").exists(),
        "multi_tenant_isolation": "enabled",
    }


@app.post(
    "/api/v1/reports/export-excel",
    tags=["4. Manuel / Toplu Excel Rapor İndirme"],
    summary="Tamamlanan Siparişleri Fotoğraf + İmza Gömülü Excel (.xlsx) Olarak İndir / Gönder",
)
async def export_and_mail_pod_excel(
    payload: TenantArchiveRequest,
    background_tasks: BackgroundTasks,
    send_email: bool = True,
):
    """
    JSON payload (URL veya Base64 görseller) üzerinden gömülü Excel üretir,
    `backend/excel_arsiv/` klasörüne kaydeder, isteğe bağlı olarak e-posta gönderir
    ve .xlsx dosyasını doğrudan indirilebilir döndürür.
    """
    records = []
    for item in payload.orders:
        if not item.pod_photo_source.strip() or not item.pod_signature_source.strip():
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Sipariş {item.order_number} için fotoğraf ve imza zorunludur!",
            )
        records.append(
            OrderPoDRecord(
                order_number=item.order_number,
                customer_name=item.customer_name,
                customer_phone=item.customer_phone,
                delivery_address=item.delivery_address,
                driver_name=item.driver_name,
                driver_plate=item.driver_plate,
                recipient_name=item.recipient_name,
                delivered_at=datetime.now(),
                dest_lat=item.dest_lat,
                dest_lng=item.dest_lng,
                delivered_lat=item.delivered_lat,
                delivered_lng=item.delivered_lng,
                pod_photo=item.pod_photo_source,
                pod_signature=item.pod_signature_source,
            )
        )

    if send_email:
        background_tasks.add_task(
            mailer_service.send_pod_excel_email,
            tenant_name=payload.tenant_name,
            report_email=str(payload.report_email),
            orders=records,
            primary_color_hex=payload.primary_color_hex,
        )

    xlsx_bytes = mailer_service.generate_pod_excel_bytes(
        tenant_name=payload.tenant_name,
        orders=records,
        primary_color_hex=payload.primary_color_hex,
    )

    filename = f"PoD_Arsiv_{datetime.now().strftime('%Y%m%d_%H%M%S')}.xlsx"
    return Response(
        content=xlsx_bytes,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# 3. Müşteri (/track/{tracking_token}) veya Kurye Davet (/driver-invite/{invite_token}) SPA yönlendirmesi
@app.get("/track/{tracking_token}", include_in_schema=False)
@app.get("/driver-invite/{invite_token}", include_in_schema=False)
async def serve_flutter_spa_routes(
    tracking_token: Optional[str] = None,
    invite_token: Optional[str] = None,
):
    index_file = settings.STATIC_WEB_DIR / "index.html"
    if index_file.exists():
        return FileResponse(str(index_file))
    raise HTTPException(status_code=404, detail="Flutter Web derlemesi (static_web/index.html) bulunamadı.")


# 4. Kök dizin (/) ve diğer tüm Flutter Web statik dosyalarını `backend/static_web` üzerinden sun
app.mount(
    "/",
    StaticFiles(directory=str(settings.STATIC_WEB_DIR), html=True),
    name="static_web",
)
