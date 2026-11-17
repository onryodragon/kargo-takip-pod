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
from fastapi.responses import FileResponse, HTMLResponse, Response
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
    ping_url = f"{settings.PUBLIC_BASE_URL.rstrip('/')}/api/v1/health"
    req = UrlRequest(
        ping_url,
        headers={"User-Agent": "Render-KeepAlive-Service/1.0"},
    )
    with urlopen(req, timeout=15.0) as resp:
        resp.read()


async def _render_keep_alive_loop() -> None:
    """
    Render ücretsiz planda sunucunun 15 dakika hareketsizlik sonrası uyku moduna
    geçmesini önlemek için her 10 dakikada bir kendi /api/v1/health
    adresine otomatik istek atar.
    """
    ping_url = f"{settings.PUBLIC_BASE_URL.rstrip('/')}/api/v1/health"
    while True:
        await asyncio.sleep(RENDER_KEEP_ALIVE_INTERVAL_SECONDS)
        try:
            await asyncio.to_thread(_ping_render_health_sync)
            logger.info("Render Keep-Alive ping başarılı: %s", ping_url)
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
    language: Optional[str] = Field("tr", examples=["tr", "en", "de", "es", "fr", "ar", "ru", "id", "pt"])
    orders: List[OrderPoDPayload]


@app.get("/health", tags=["Sistem Durumu"])
@app.get("/api/v1/health", tags=["Sistem Durumu"])
async def health_check():
    return {
        "status": "healthy",
        "render_url": settings.PUBLIC_BASE_URL,
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
            language=payload.language or "tr",
        )

    xlsx_bytes = mailer_service.generate_pod_excel_bytes(
        tenant_name=payload.tenant_name,
        orders=records,
        primary_color_hex=payload.primary_color_hex,
        language=payload.language or "tr",
    )

    filename = f"PoD_Arsiv_{datetime.now().strftime('%Y%m%d_%H%M%S')}.xlsx"
    return Response(
        content=xlsx_bytes,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


PRIVACY_POLICY_HTML = """<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Gizlilik Politikası & KVKK / Privacy Policy - Kargo Takip PoD</title>
    <style>
        :root {
            --primary: #0077FF;
            --primary-dark: #0056B3;
            --text-main: #1E293B;
            --text-muted: #64748B;
            --bg-body: #F8FAFC;
            --bg-card: #FFFFFF;
            --border-color: #E2E8F0;
            --accent: #10B981;
            --tag-bg: #EFF6FF;
            --tag-text: #1D4ED8;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-body);
            color: var(--text-main);
            line-height: 1.65;
            padding: 24px 16px;
        }
        .container {
            max-width: 900px;
            margin: 0 auto;
            background: var(--bg-card);
            border-radius: 16px;
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.05), 0 8px 10px -6px rgba(0, 0, 0, 0.03);
            border: 1px solid var(--border-color);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #0A192F 0%, #0077FF 100%);
            color: #ffffff;
            padding: 40px 32px;
            position: relative;
        }
        .header h1 {
            font-size: 26px;
            font-weight: 700;
            margin-bottom: 8px;
            letter-spacing: -0.5px;
        }
        .header p {
            font-size: 14px;
            opacity: 0.9;
        }
        .lang-switch {
            display: flex;
            gap: 10px;
            margin-top: 20px;
        }
        .lang-btn {
            background: rgba(255, 255, 255, 0.18);
            border: 1px solid rgba(255, 255, 255, 0.35);
            color: #fff;
            padding: 7px 18px;
            border-radius: 20px;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s ease;
        }
        .lang-btn.active, .lang-btn:hover {
            background: #ffffff;
            color: #0A192F;
        }
        .content {
            padding: 36px 32px;
        }
        h2 {
            font-size: 20px;
            color: #0F172A;
            margin-top: 28px;
            margin-bottom: 12px;
            padding-bottom: 8px;
            border-bottom: 2px solid #F1F5F9;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        p, li {
            font-size: 15px;
            color: #334155;
            margin-bottom: 12px;
        }
        ul {
            padding-left: 20px;
            margin-bottom: 16px;
        }
        li { margin-bottom: 8px; }
        .perm-card {
            background: #F8FAFC;
            border-left: 4px solid var(--primary);
            border-radius: 8px;
            padding: 16px 20px;
            margin: 14px 0;
            border: 1px solid var(--border-color);
            border-left-width: 4px;
        }
        .perm-title {
            font-weight: 700;
            color: #0F172A;
            font-size: 15px;
            margin-bottom: 6px;
            display: flex;
            align-items: center;
            gap: 6px;
        }
        .perm-code {
            font-family: monospace;
            background: var(--tag-bg);
            color: var(--tag-text);
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 12px;
        }
        .highlight-box {
            background: #ECFDF5;
            border: 1px solid #A7F3D0;
            color: #065F46;
            padding: 16px 20px;
            border-radius: 10px;
            margin: 20px 0;
            font-size: 14px;
        }
        .contact-box {
            background: #F1F5F9;
            border-radius: 10px;
            padding: 20px;
            margin-top: 30px;
            text-align: center;
        }
        .contact-box a {
            color: var(--primary);
            font-weight: 600;
            text-decoration: none;
        }
        .contact-box a:hover {
            text-decoration: underline;
        }
        .footer {
            text-align: center;
            padding: 24px;
            font-size: 13px;
            color: var(--text-muted);
            border-top: 1px solid var(--border-color);
        }
        .hidden { display: none; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1 id="header-title">Gizlilik Politikası & KVKK Aydınlatma Metni</h1>
            <p id="header-subtitle">Kargo Takip & Canlı Kurye POD Sistemi • Son Güncelleme: 15 Kasım 2026</p>
            <div class="lang-switch">
                <button class="lang-btn active" onclick="switchLang('tr')">🇹🇷 Türkçe</button>
                <button class="lang-btn" onclick="switchLang('en')">🇬🇧 English</button>
                <button class="lang-btn" onclick="switchLang('zh')">🇨🇳 中文 (简体)</button>
            </div>
        </div>

        <div class="content">
            <!-- TÜRKÇE BÖLÜM -->
            <div id="section-tr">
                <div class="highlight-box">
                    <strong>Bilgilendirme:</strong> İşbu Gizlilik Politikası ve KVKK Aydınlatma Metni, Kargo Takip & Teslimat Kanıtı (PoD) platformunun Huawei AppGallery mağaza kullanıcıları, kuryeleri, kurumsal işletmeleri ve teslimat alıcıları için 6698 sayılı Kişisel Verilerin Korunması Kanunu (KVKK) ve Genel Veri Koruma Yönetmeliği (GDPR) kapsamında hazırlanmıştır.
                </div>

                <h2>1. Veri Sorumlusu ve Hizmet Tanımı</h2>
                <p><strong>Uygulama Adı:</strong> Kargo Takip PoD<br>
                <strong>Geliştirici ve Veri Sorumlusu:</strong> Olkan Bayat<br>
                <strong>İletişim ve Veri Silme Talebi E-Postası:</strong> <a href="mailto:destek@kargotakip.com">destek@kargotakip.com</a> / <a href="mailto:onryodragon@users.noreply.github.com">onryodragon@users.noreply.github.com</a></p>
                <p>Kargo Takip PoD platformu, işletmelerin sipariş ve teslimat süreçlerini yönetmelerini, kuryelerin paket teslimatlarını fotoğraflı ve imzalı olarak kanıtlamalarını (Proof of Delivery), müşterilerin ise kendilerine iletilen şifreli geçici link üzerinden kuryenin varışını haritada canlı izlemelerini sağlayan çok kiracılı (multi-tenant) bir kurumsal yazılım çözümüdür.</p>

                <h2>2. Toplanan Veriler ve Kullanım Amaçları</h2>
                <p>Uygulamamız yalnızca temel lojistik işlevlerini yerine getirmek amacıyla aşağıdaki verileri ve hassas sistem izinlerini talep eder. Verileriniz hiçbir reklam, pazarlama veya üçüncü şahıs veri tüccarı ile paylaşılmaz:</p>

                <div class="perm-card">
                    <div class="perm-title">📍 Hassas ve Arka Plan Konum İzni <span class="perm-code">android.permission.ACCESS_BACKGROUND_LOCATION & ACCESS_FINE_LOCATION</span></div>
                    <p><strong>Amaç:</strong> Saha kuryesi bir siparişi teslimata çıkardığında (Durum: "Yolda / in_transit"), müşterinin SMS/WhatsApp ile kendisine iletilen geçici takip linki üzerinden kuryenin yaklaşmakta olduğunu haritada canlı olarak görebilmesi ve işletme yöneticisinin kurye rotasını optimize edebilmesi için gereklidir. Kurye uygulamayı alta aldığında veya ekran kapalıyken GPS sinyalinin kesilmemesi için arka plan konum erişimi kullanılır. Teslimat tamamlandığında veya kurye vardiyasını sonlandırdığında konum iletimi anında durdurulur.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">📷 Kamera İzni <span class="perm-code">android.permission.CAMERA</span></div>
                    <p><strong>Amaç:</strong> Yalnızca kurye paketi alıcıya teslim ettiği anda koli/paket teslim durumunun fotoğraflanması ve dijital tutanağa/Excel raporuna Teslimat Kanıtı (PoD) olarak eklenmesi amacıyla kullanılır. Kurye kamerayı teslimat onay ekranında bizzat açar; uygulama arka planda veya habersizce asla kamera kaydı almaz ya da kullanıcının cihazındaki fotoğraf galerisini taramaz.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">✍️ Ekrana İmza Alma</div>
                    <p><strong>Amaç:</strong> Teslimat anında alıcının dokunmatik ekran üzerinden ıslak imzasını alarak teslimatı onayladığını belgelemek ve teslim tutanağına eklemek için kullanılır.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">📱 Telefon Numarası</div>
                    <p><strong>Amaç:</strong> Alıcı müşteriye sipariş takip linkinin WhatsApp/SMS ile iletilmesi ve sahada görev yapacak kuryelerin WhatsApp üzerinden davet edilerek işletmeye bağlanması amacıyla kullanılır.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">⚡ Pil Optimizasyonu İstisnası <span class="perm-code">android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS</span></div>
                    <p><strong>Amaç:</strong> Android işletim sisteminin kurye aktif sürüş ve teslimat halindeyken arka plan GPS servisini zorla uyutmasını (Doze modu) önlemek, teslimat esnasında müşteri haritasında kopukluk yaşanmasını engellemek için talep edilir.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">🌐 Ağ ve İnternet Erişimi <span class="perm-code">android.permission.INTERNET</span></div>
                    <p><strong>Amaç:</strong> Sipariş durumlarının, teslimat koordinatlarının ve kanıt belgelerinin bulut sunucuya şifreli (TLS/HTTPS) aktarımı için zorunludur.</p>
                </div>

                <h2>3. Veri Güvenliği ve 24 Saatlik Harita Arşiv Kuralı</h2>
                <p>Platformumuzda toplanan tüm veriler sektör standardı TLS/HTTPS protokolü ile şifrelenir. Kullanıcı şifreleri tek yönlü güçlü kriptografik özetleme algoritmaları ile saklanır. Gizlilik ilkesi gereği, tamamlanan siparişler ve kurye rota geçmişi harita üzerinden 24 saat sonra otomatik olarak arşivlenir ve genel harita görünümünden kaldırılır.</p>

                <h2>4. 6698 Sayılı KVKK Kapsamındaki Haklarınız</h2>
                <p>KVKK'nın 11. maddesi uyarınca veri sahipleri; kişisel verilerinin işlenip işlenmediğini öğrenme, işlenmişse buna ilişkin bilgi talep etme, işlenme amacını ve amacına uygun kullanılıp kullanılmadığını öğrenme, eksik veya yanlış işlenmişse düzeltilmesini isteme ve şartlar oluştuğunda verilerin silinmesini veya yok edilmesini talep etme hakkına sahiptir.</p>

                <h2>5. Hesap ve Veri Silme Talepleri</h2>
                <p>Kullanıcılar veya işletmeler, sisteme kayıtlı tüm verilerinin ve hesaplarının silinmesi talebini aşağıdaki destek e-posta adresimize iletebilirler. Talepler en geç 30 iş günü içerisinde yerine getirilir.</p>

                <div class="contact-box">
                    <h3>Resmi Destek ve İletişim</h3>
                    <p>Her türlü gizlilik, veri güvenliği ve izin talepleriniz için:</p>
                    <p><a href="mailto:destek@kargotakip.com">destek@kargotakip.com</a> / <a href="mailto:onryodragon@users.noreply.github.com">onryodragon@users.noreply.github.com</a></p>
                </div>
            </div>

            <!-- ENGLISH SECTION -->
            <div id="section-en" class="hidden">
                <div class="highlight-box">
                    <strong>Notice:</strong> This Privacy Policy and Data Protection Statement has been prepared in full compliance with GDPR and relevant international regulations for users, drivers, enterprise tenants, and delivery recipients using our app via Huawei AppGallery.
                </div>

                <h2>1. Data Controller & Service Overview</h2>
                <p><strong>App Name:</strong> Kargo Takip PoD<br>
                <strong>Developer & Data Controller:</strong> Olkan Bayat<br>
                <strong>Contact & Account/Data Deletion Email:</strong> <a href="mailto:destek@kargotakip.com">destek@kargotakip.com</a> / <a href="mailto:onryodragon@users.noreply.github.com">onryodragon@users.noreply.github.com</a></p>
                <p>Kargo Takip PoD is a multi-tenant cloud delivery management solution providing real-time driver tracking, electronic Proof of Delivery (PoD with photos and recipient signatures), and temporary live map tracking for customers receiving goods.</p>

                <h2>2. Sensitive Permissions & Legitimate Use Cases</h2>
                <p>Our application requests only the minimal necessary permissions strictly required to execute core logistics operations. We do not monetize, sell, or share user data with third-party advertising networks:</p>

                <div class="perm-card">
                    <div class="perm-title">📍 Live & Background Location <span class="perm-code">android.permission.ACCESS_BACKGROUND_LOCATION & ACCESS_FINE_LOCATION</span></div>
                    <p><strong>Purpose:</strong> Required exclusively for field couriers while an order is actively out for delivery ("in_transit"). It streams real-time GPS coordinates so waiting customers can track the driver's approach via a temporary secure web link, and fleet dispatchers can optimize delivery routes. Tracking stops immediately upon delivery completion or driver sign-off.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">📷 Camera Permission <span class="perm-code">android.permission.CAMERA</span></div>
                    <p><strong>Purpose:</strong> Strictly utilized when a courier physically delivers a parcel to capture a delivery photo as Proof of Delivery (PoD). The camera is explicitly opened by the driver on the delivery confirmation screen. The application never scans your device gallery or captures photos silently in the background.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">✍️ On-Screen Signature Capture</div>
                    <p><strong>Purpose:</strong> Used exclusively to record the recipient's digital touchscreen signature confirming proof of receipt.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">📱 Phone Number</div>
                    <p><strong>Purpose:</strong> Used to dispatch real-time web tracking links to customers via WhatsApp/SMS and onboard fleet drivers via one-tap WhatsApp invitations.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">⚡ Battery Optimization Exemption <span class="perm-code">android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS</span></div>
                    <p><strong>Purpose:</strong> Prevents the mobile operating system from suspending active GPS location updates while a driver navigates between delivery stops with the screen turned off.</p>
                </div>

                <div class="perm-card">
                    <div class="perm-title">🌐 Network & Internet <span class="perm-code">android.permission.INTERNET</span></div>
                    <p><strong>Purpose:</strong> Encrypted communication (TLS/HTTPS) with the secure backend server.</p>
                </div>

                <h2>3. Data Retention & 24-Hour Map Archive Policy</h2>
                <p>All transmitted data is encrypted in transit using industry-standard TLS. Driver location traces for completed deliveries automatically expire and are removed from public/active live maps after 24 hours.</p>

                <h2>4. Your GDPR & Privacy Rights</h2>
                <p>You retain the right to access, rectify, restrict processing, or request total deletion of your personal data stored within our systems at any time.</p>

                <h2>5. Account & Data Deletion Requests</h2>
                <p>To request permanent deletion of your profile, enterprise tenant workspace, or associated delivery history, contact our support team:</p>

                <div class="contact-box">
                    <h3>Official Privacy Contact</h3>
                    <p>Email our designated data protection team:</p>
                    <p><a href="mailto:destek@kargotakip.com">destek@kargotakip.com</a> / <a href="mailto:onryodragon@users.noreply.github.com">onryodragon@users.noreply.github.com</a></p>
                </div>
            </div>

            <!-- 中文（简体）BÖLÜM - PIPL & HUAWEI APPGALLERY COMPLIANT -->
            <div id="section-zh" class="hidden">
                <div class="highlight-box">
                    <strong>重要声明：</strong> 本隐私政策及个人信息保护声明严格依据《中华人民共和国个人信息保护法》(PIPL) 以及相关国际数据保护法规制定，适用于通过华为应用市场 (Huawei AppGallery) 及网页端使用“Kargo Takip PoD”的所有企业客户、配送员/骑手以及收件人。
                </div>

                <h2>1. 个人信息处理者与服务概述</h2>
                <p><strong>应用名称：</strong> Kargo Takip PoD（货物追踪与电子签收凭证系统）<br>
                <strong>个人信息处理者 / 开发者：</strong> Olkan Bayat<br>
                <strong>个人信息保护与账户注销联系邮箱：</strong> <a href="mailto:destek@kargotakip.com">destek@kargotakip.com</a> / <a href="mailto:onryodragon@users.noreply.github.com">onryodragon@users.noreply.github.com</a></p>
                <p>Kargo Takip PoD 是一套基于华为云与现代架构的多租户物流交付管理系统，向注册企业提供实时的配送骑手位置监控、现场拍照+触摸屏签名的电子交付凭证 (Proof of Delivery, PoD)，并为包裹收件人生成最长24小时有效的临时实时查看地图。</p>

                <h2>2. 敏感权限申请与正当合法使用场景</h2>
                <p>我们严格遵循最小必要原则申请设备权限，所有权限仅用于履行核心物流配送功能。我们绝不向任何第三方广告网络出售、共享或出租您的个人信息，亦不进行定向广告推送：</p>

                <div class="perm-card">
                    <span class="perm-tag">位置信息权限 (Location)</span>
                    <h3>高精度 GPS 与后台位置权限 (ACCESS_FINE_LOCATION, ACCESS_BACKGROUND_LOCATION)</h3>
                    <p><strong>使用场景：</strong> 仅在配送员登录并进入“开始值班并派送”状态期间在后台或前台采集经纬度坐标与行进方向。</p>
                    <p><strong>业务目的：</strong> 用于计算最优配送路线，并在包裹处于“运输中 (in_transit)”时向收件人及企业管理员展示骑手距离和预计送达时间。一旦配送订单完成或骑手下班，系统立即停止位置采集。</p>
                </div>

                <div class="perm-card">
                    <span class="perm-tag">相机与多媒体权限 (Camera)</span>
                    <h3>现场拍照权限 (android.permission.CAMERA)</h3>
                    <p><strong>使用场景：</strong> 仅在骑手到达收件地址点击“完成交付”时，用于拍摄包裹送达现场照片（如门前、前台或收件人签收处）。</p>
                    <p><strong>业务目的：</strong> 作为不可篡改的电子交付证据（PoD 凭证），并自动附入企业每日交付归档报告中，保障交易双方权益。我们绝不读取您的个人相册私有照片。</p>
                </div>

                <div class="perm-card">
                    <span class="perm-tag">手写签名数据 (Digital Signature)</span>
                    <h3>触摸屏手写签名采集</h3>
                    <p><strong>使用场景：</strong> 收件人在骑手手机屏幕上签署的电子姓名轨迹。</p>
                    <p><strong>业务目的：</strong> 仅用于生成受保护的交付凭证图像，绝不会用于任何第三方生物特征比对或商业推广。</p>
                </div>

                <div class="perm-card">
                    <span class="perm-tag">联系电话与通讯 (Phone & WhatsApp)</span>
                    <h3>收件人与骑手电话号码</h3>
                    <p><strong>使用场景：</strong> 仅用于向收件人发送包裹派送通知及临时追踪链接，以及向骑手发送加入企业的邀请码。</p>
                </div>

                <h2>3. 数据安全与24小时生命周期</h2>
                <p>所有数据传输均采用行业标准 TLS 1.3 / HTTPS 及 WSS 加密传输。收件人专属的临时地图追踪链接在包裹交付完成后24小时自动失效，历史轨迹数据从公开追踪端永久下线，确保收件人与骑手的行踪隐私不受长久泄露风险。</p>

                <h2>4. 用户权利与个人信息主体权益</h2>
                <p>根据《中华人民共和国个人信息保护法》(PIPL) 及相关法律，您对您的个人信息享有查阅、复制、更正、补充、删除以及撤回授权同意的权利。企业管理员有权彻底导出或删除其名下的所有历史交付记录与骑手档案。</p>

                <h2>5. 账户注销与个人数据彻底清除</h2>
                <p>如需注销账户、删除企业工作空间或彻底清除所有关联的配送历史记录，请直接通过以下官方渠道联系我们的个人信息保护团队：</p>

                <div class="contact-box">
                    <h3>官方个人信息保护与技术支持邮箱</h3>
                    <p>邮箱：<a href="mailto:destek@kargotakip.com">destek@kargotakip.com</a> / <a href="mailto:onryodragon@users.noreply.github.com">onryodragon@users.noreply.github.com</a></p>
                    <p>我们承诺在收到您的注销或删除请求后 48 小时内核实并彻底完成系统及备份中的数据物理清除。</p>
                </div>
            </div>
        </div>

        <div class="footer">
            &copy; 2026 Kargo Takip PoD Systems. All rights reserved. • GMS-Independent • Huawei AppGallery Ready
        </div>
    </div>

    <script>
        function switchLang(lang) {
            const trSec = document.getElementById('section-tr');
            const enSec = document.getElementById('section-en');
            const zhSec = document.getElementById('section-zh');
            const btns = document.querySelectorAll('.lang-btn');
            const title = document.getElementById('header-title');
            const subtitle = document.getElementById('header-subtitle');

            trSec.classList.add('hidden');
            enSec.classList.add('hidden');
            zhSec.classList.add('hidden');
            btns.forEach(b => b.classList.remove('active'));

            if (lang === 'zh') {
                zhSec.classList.remove('hidden');
                if (btns[2]) btns[2].classList.add('active');
                title.textContent = '隐私政策与个人信息保护声明';
                subtitle.textContent = 'Kargo Takip 实时快递与电子交付凭证 (PoD) 系统 • 更新日期：2026年11月17日';
            } else if (lang === 'en') {
                enSec.classList.remove('hidden');
                if (btns[1]) btns[1].classList.add('active');
                title.textContent = 'Privacy Policy & Data Protection Statement';
                subtitle.textContent = 'Cargo Tracking & Live Courier PoD System • Last Updated: November 17, 2026';
            } else {
                trSec.classList.remove('hidden');
                if (btns[0]) btns[0].classList.add('active');
                title.textContent = 'Gizlilik Politikası & KVKK Aydınlatma Metni';
                subtitle.textContent = 'Kargo Takip & Canlı Kurye POD Sistemi • Son Güncelleme: 17 Kasım 2026';
            }
        }

        // URL parametresi veya tarayıcı diline göre otomatik Çince algılama
        const urlParams = new URLSearchParams(window.location.search);
        const reqLang = urlParams.get('lang');
        if (reqLang === 'zh' || (!reqLang && navigator.language && navigator.language.startsWith('zh'))) {
            switchLang('zh');
        } else if (reqLang === 'en' || (!reqLang && navigator.language && navigator.language.startsWith('en'))) {
            switchLang('en');
        }
    </script>
</body>
</html>
"""


@app.get("/privacy", response_class=HTMLResponse, tags=["Yasal Bilgilendirme"])
@app.get("/kvkk", response_class=HTMLResponse, tags=["Yasal Bilgilendirme"])
async def serve_privacy_and_kvkk():
    """Huawei AppGallery ve KVKK/GDPR uyumlu canlı Gizlilik Politikası ve Aydınlatma Metni."""
    return HTMLResponse(content=PRIVACY_POLICY_HTML, status_code=200)


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
