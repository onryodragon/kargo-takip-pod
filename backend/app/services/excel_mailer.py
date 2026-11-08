"""
excel_mailer.py
---------------
Çoklu İşletme Destekli (Multi-Tenant) Teslimat ve PoD Sistemi
Fotoğraf + İmza Gömülü Otomatik Excel (.xlsx) Raporlama ve E-posta Servisi.

Özellikler:
- Tamamlanan siparişlerin bilgilerini (Sipariş No, Müşteri, Adres, Kurye,
  Teslim Saati, Koordinat) tablo halinde işler.
- Çekilen 'Teslimat Fotoğrafı' ve 'Alıcı İmzası' görsellerini (URL, Base64,
  yerel dosya yolu veya raw bytes) Pillow ile boyutlandırıp openpyxl kullanarak
  doğrudan ilgili Excel hücrelerinin (G ve H sütunları) içine gömer.
- Şeffaf arka planlı (RGBA) imza görsellerini beyaz zemin üzerine oturtarak
  Excel'de her zaman net görünmesini sağlar.
- Oluşturulan .xlsx dosyasını işletmenin (Tenant) 'report_email' adresine
  SMTP üzerinden otomatik olarak gönderir.
"""

from __future__ import annotations

import base64
import io
import logging
import os
import smtplib
from dataclasses import dataclass, field
from datetime import datetime
from email.message import EmailMessage
from pathlib import Path
from typing import List, Optional, Union
from urllib.request import Request, urlopen

try:
    import httpx
except ImportError:
    httpx = None  # type: ignore

from openpyxl import Workbook
from openpyxl.drawing.image import Image as XLImage
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from PIL import Image as PILImage, ImageDraw, ImageOps

logger = logging.getLogger("pod_system.excel_mailer")
logging.basicConfig(level=logging.INFO)

# Hücre içi görsel boyut sabitleri (Piksel & Excel Satır/Sütun Ölçüleri)
CELL_IMAGE_WIDTH_PX = 140
CELL_IMAGE_HEIGHT_PX = 105
EXCEL_ROW_HEIGHT_PT = 88.0       # ~117px (105px görsel + hücre içi üst/alt boşluk)
EXCEL_IMAGE_COL_WIDTH = 21.5     # ~150px (140px görsel + hücre içi sağ/sol boşluk)

ImageSource = Union[bytes, str, Path, None]


@dataclass
class OrderPoDRecord:
    """Excel arşivine eklenecek tamamlanmış sipariş ve PoD veri modeli."""
    order_number: str
    customer_name: str
    customer_phone: str
    delivery_address: str
    driver_name: str
    delivered_at: Union[datetime, str]
    dest_lat: float
    dest_lng: float
    pod_photo: ImageSource               # URL, Base64, dosya yolu veya bytes
    pod_signature: ImageSource           # URL, Base64, dosya yolu veya bytes
    driver_plate: Optional[str] = None
    recipient_name: Optional[str] = None
    delivered_lat: Optional[float] = None
    delivered_lng: Optional[float] = None


@dataclass
class SMTPConfig:
    """E-posta gönderim yapılandırması (Ortam değişkenlerinden varsayılanları alır)."""
    host: str = field(default_factory=lambda: os.getenv("SMTP_HOST", "smtp.gmail.com"))
    port: int = field(default_factory=lambda: int(os.getenv("SMTP_PORT", "587")))
    username: str = field(default_factory=lambda: os.getenv("SMTP_USER", ""))
    password: str = field(default_factory=lambda: os.getenv("SMTP_PASSWORD", ""))
    sender_email: str = field(default_factory=lambda: os.getenv("SMTP_FROM", "noreply@teslimattakip.com"))
    use_tls: bool = field(default_factory=lambda: os.getenv("SMTP_USE_TLS", "true").lower() == "true")


class ExcelPoDMailerService:
    """
    Teslimat Kanıtı (Fotoğraf + İmza) içeren Excel dosyasını oluşturan
    ve işletme yöneticisinin e-posta adresine gönderen servis.
    """

    def __init__(self, smtp_config: Optional[SMTPConfig] = None) -> None:
        self.smtp_config = smtp_config or SMTPConfig()

    # -------------------------------------------------------------------------
    # 1. GÖRSEL YÜKLEME VE HÜCRE İÇİ BOYUTLANDIRMA (PILLOW)
    # -------------------------------------------------------------------------
    @staticmethod
    def _fetch_raw_image_bytes(source: ImageSource) -> Optional[bytes]:
        """URL, Base64, yerel dosya yolu veya bytes kaynağından ham görsel verisini çözer."""
        if source is None:
            return None

        if isinstance(source, bytes):
            return source

        if isinstance(source, Path):
            return source.read_bytes() if source.exists() else None

        if isinstance(source, str):
            src = source.strip()
            if not src:
                return None

            # 1) Data URI veya Base64 kontrolü
            if src.startswith("data:image"):
                _, b64_data = src.split(",", 1)
                return base64.b64decode(b64_data)

            # 2) HTTP / HTTPS URL (Örn: Supabase Storage URL)
            if src.startswith(("http://", "https://")):
                if httpx is not None:
                    with httpx.Client(timeout=15.0, follow_redirects=True) as client:
                        response = client.get(src)
                        response.raise_for_status()
                        return response.content
                req = Request(src, headers={"User-Agent": "PoDMailer/1.0"})
                with urlopen(req, timeout=15.0) as resp:
                    return resp.read()

            # 3) Yerel dosya yolu kontrolü
            path_obj = Path(src)
            if path_obj.exists() and path_obj.is_file():
                return path_obj.read_bytes()

            # 4) Düz Base64 string ihtimali
            try:
                return base64.b64decode(src, validate=True)
            except Exception:
                logger.warning("Görsel kaynağı çözümlenemedi: %s", src[:60])
                return None

        return None

    @classmethod
    def _prepare_cell_image_stream(
        cls,
        source: ImageSource,
        is_signature: bool = False,
        target_w: int = CELL_IMAGE_WIDTH_PX,
        target_h: int = CELL_IMAGE_HEIGHT_PX,
    ) -> Optional[io.BytesIO]:
        """
        Görseli yükler, şeffaf imza ise beyaz tuvale oturtur, hücre boyutuna
        orantılı olarak ölçekler ve openpyxl'in okuyabileceği PNG BytesIO döndürür.
        """
        raw_bytes = cls._fetch_raw_image_bytes(source)
        if not raw_bytes:
            return None

        try:
            with PILImage.open(io.BytesIO(raw_bytes)) as img:
                # EXIF yönlendirmesini düzelt (Mobil kameradan dikey çekilen fotoğraflar için kritik)
                img = ImageOps.exif_transpose(img)

                # Şeffaf arka planlı imzaları veya RGBA görselleri beyaz arka plana oturt
                if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
                    alphaConverted = img.convert("RGBA")
                    white_bg = PILImage.new("RGBA", alphaConverted.size, (255, 255, 255, 255))
                    white_bg.paste(alphaConverted, mask=alphaConverted.split()[3])
                    img = white_bg.convert("RGB")
                else:
                    img = img.convert("RGB")

                # Görseli hedef hücre boyutuna orantıyı bozmadan küçült
                img.thumbnail((target_w - 8, target_h - 8), PILImage.Resampling.LANCZOS)

                # Hücre içinde tam ortalı ve temiz çerçeveli durması için sabit tuval oluştur
                bg_color = (255, 255, 255) if is_signature else (248, 250, 252)
                canvas = PILImage.new("RGB", (target_w, target_h), bg_color)
                offset_x = (target_w - img.width) // 2
                offset_y = (target_h - img.height) // 2
                canvas.paste(img, (offset_x, offset_y))

                # İnce gri çerçeve çiz
                draw = ImageDraw.Draw(canvas)
                draw.rectangle(
                    [0, 0, target_w - 1, target_h - 1],
                    outline=(203, 213, 225),
                    width=1,
                )

                out_buffer = io.BytesIO()
                canvas.save(out_buffer, format="PNG", optimize=True)
                out_buffer.seek(0)
                return out_buffer
        except Exception as exc:
            logger.error("Görsel işlenirken hata oluştu: %s", exc)
            return None

    # -------------------------------------------------------------------------
    # 2. EXCEL (.XLSX) OLUŞTURMA VE GÖRSELLERİ HÜCREYE GÖMME
    # -------------------------------------------------------------------------
    @classmethod
    def generate_pod_excel_bytes(
        cls,
        tenant_name: str,
        orders: List[OrderPoDRecord],
        primary_color_hex: str = "1E40AF",
    ) -> bytes:
        """
        Verilen sipariş listesini ve PoD görsellerini (Fotoğraf + İmza)
        hücrelerin içine gömerek Excel (.xlsx) dosyası byte dizisi üretir.
        """
        wb = Workbook()
        ws = wb.active
        ws.title = "Teslimat Kanıtı Arşivi"

        # Renk ve Stil Tanımları
        clean_hex = primary_color_hex.lstrip("#").upper()
        if len(clean_hex) != 6:
            clean_hex = "1E40AF"

        title_fill = PatternFill(start_color=clean_hex, end_color=clean_hex, fill_type="solid")
        header_fill = PatternFill(start_color="0F172A", end_color="0F172A", fill_type="solid")
        zebra_fill = PatternFill(start_color="F8FAFC", end_color="F8FAFC", fill_type="solid")
        white_fill = PatternFill(start_color="FFFFFF", end_color="FFFFFF", fill_type="solid")

        title_font = Font(name="Calibri", size=15, bold=True, color="FFFFFF")
        subtitle_font = Font(name="Calibri", size=10, italic=True, color="334155")
        header_font = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
        cell_font = Font(name="Calibri", size=10, color="0F172A")
        bold_cell_font = Font(name="Calibri", size=10, bold=True, color="0F172A")
        link_font = Font(name="Calibri", size=10, color="2563EB", underline="single")

        thin_side = Side(border_style="thin", color="CBD5E1")
        cell_border = Border(left=thin_side, right=thin_side, top=thin_side, bottom=thin_side)

        center_align = Alignment(horizontal="center", vertical="center", wrap_text=True)
        left_align = Alignment(horizontal="left", vertical="center", wrap_text=True)

        # 1. Satır: White-Label İşletme Başlığı
        ws.merge_cells("A1:H1")
        ws["A1"] = f"{tenant_name.upper()} — TESLİMAT KANITI (PoD) VE SİPARİŞ ARŞİV RAPORU"
        ws["A1"].fill = title_fill
        ws["A1"].font = title_font
        ws["A1"].alignment = center_align
        ws.row_dimensions[1].height = 34

        # 2. Satır: Rapor Meta Bilgisi
        ws.merge_cells("A2:H2")
        now_str = datetime.now().strftime("%d.%m.%Y %H:%M")
        ws["A2"] = (
            f"Rapor Oluşturulma Tarihi: {now_str}   |   "
            f"Toplam Tamamlanan Sipariş: {len(orders)} Adet   |   "
            f"Harita Altyapısı: OpenStreetMap (GMS Bağımsız)"
        )
        ws["A2"].font = subtitle_font
        ws["A2"].alignment = center_align
        ws.row_dimensions[2].height = 22

        # 3. Satır: Sütun Başlıkları
        headers = [
            "Sipariş No",
            "Müşteri Bilgisi",
            "Teslimat Adresi",
            "Kurye / Araç",
            "Teslim Saati",
            "Koordinat (OSM)",
            "Teslimat Fotoğrafı",
            "Alıcı İmzası",
        ]
        header_row_idx = 3
        ws.row_dimensions[header_row_idx].height = 28

        for col_idx, text in enumerate(headers, start=1):
            cell = ws.cell(row=header_row_idx, column=col_idx, value=text)
            cell.fill = header_fill
            cell.font = header_font
            cell.alignment = center_align
            cell.border = cell_border

        # Sütun Genişlikleri
        column_widths = {
            1: 18.0,                     # A: Sipariş No
            2: 24.0,                     # B: Müşteri Bilgisi
            3: 36.0,                     # C: Teslimat Adresi
            4: 22.0,                     # D: Kurye / Araç
            5: 20.0,                     # E: Teslim Saati
            6: 25.0,                     # F: Koordinat (OSM)
            7: EXCEL_IMAGE_COL_WIDTH,    # G: Teslimat Fotoğrafı
            8: EXCEL_IMAGE_COL_WIDTH,    # H: Alıcı İmzası
        }
        for col_idx, width in column_widths.items():
            col_letter = get_column_letter(col_idx)
            ws.column_dimensions[col_letter].width = width

        # openpyxl wb.save() çağrılana kadar görüntü buffer'larını bellekte canlı tutmalıyız
        active_image_streams: List[io.BytesIO] = []

        # 4. Satırdan itibaren siparişleri ve gömülü görselleri ekle
        start_row = 4
        for idx, order in enumerate(orders):
            row_num = start_row + idx
            ws.row_dimensions[row_num].height = EXCEL_ROW_HEIGHT_PT
            row_fill = zebra_fill if idx % 2 == 1 else white_fill

            # Teslimat saati biçimlendirme
            if isinstance(order.delivered_at, datetime):
                delivered_str = order.delivered_at.strftime("%d.%m.%Y\n%H:%M:%S")
            else:
                delivered_str = str(order.delivered_at)

            # Koordinat (Varsa teslim anındaki gerçek koordinat, yoksa hedef koordinat)
            lat = order.delivered_lat if order.delivered_lat is not None else order.dest_lat
            lng = order.delivered_lng if order.delivered_lng is not None else order.dest_lng
            coord_text = f"{lat:.6f}, {lng:.6f}\n(Haritada Aç)"
            osm_url = f"https://www.openstreetmap.org/?mlat={lat:.6f}&mlon={lng:.6f}#map=18/{lat:.6f}/{lng:.6f}"

            # Müşteri ve Kurye metinleri
            customer_text = f"{order.customer_name}\nTel: {order.customer_phone}"
            if order.recipient_name:
                customer_text += f"\nTeslim Alan: {order.recipient_name}"

            driver_text = order.driver_name
            if order.driver_plate:
                driver_text += f"\nPlaka: {order.driver_plate}"

            row_values = [
                order.order_number,
                customer_text,
                order.delivery_address,
                driver_text,
                delivered_str,
                coord_text,
                "",  # G sütunu: Fotoğraf gömülecek
                "",  # H sütunu: İmza gömülecek
            ]

            for col_idx, val in enumerate(row_values, start=1):
                cell = ws.cell(row=row_num, column=col_idx, value=val)
                cell.fill = row_fill
                cell.border = cell_border
                if col_idx == 1:
                    cell.font = bold_cell_font
                    cell.alignment = center_align
                elif col_idx in (2, 3):
                    cell.font = cell_font
                    cell.alignment = left_align
                elif col_idx == 6:
                    cell.hyperlink = osm_url
                    cell.font = link_font
                    cell.alignment = center_align
                else:
                    cell.font = cell_font
                    cell.alignment = center_align

            # --- G Sütunu: Teslimat Fotoğrafını Hücreye Göm ---
            photo_stream = cls._prepare_cell_image_stream(order.pod_photo, is_signature=False)
            if photo_stream:
                active_image_streams.append(photo_stream)
                xl_photo = XLImage(photo_stream)
                xl_photo.width = CELL_IMAGE_WIDTH_PX
                xl_photo.height = CELL_IMAGE_HEIGHT_PX
                ws.add_image(xl_photo, f"G{row_num}")
            else:
                ws.cell(row=row_num, column=7, value="Fotoğraf Yok").alignment = center_align

            # --- H Sütunu: Alıcı İmzasını Hücreye Göm ---
            sig_stream = cls._prepare_cell_image_stream(order.pod_signature, is_signature=True)
            if sig_stream:
                active_image_streams.append(sig_stream)
                xl_sig = XLImage(sig_stream)
                xl_sig.width = CELL_IMAGE_WIDTH_PX
                xl_sig.height = CELL_IMAGE_HEIGHT_PX
                ws.add_image(xl_sig, f"H{row_num}")
            else:
                ws.cell(row=row_num, column=8, value="İmza Yok").alignment = center_align

        # Üst başlıkları dondur (Kaydırırken başlık sabit kalsın)
        ws.freeze_panes = "A4"

        # Workbook'u bellekte .xlsx olarak kaydet
        excel_output = io.BytesIO()
        wb.save(excel_output)
        excel_output.seek(0)
        return excel_output.getvalue()

    # -------------------------------------------------------------------------
    # 3. E-POSTA GÖNDERİMİ (SMTP)
    # -------------------------------------------------------------------------
    def send_pod_excel_email(
        self,
        tenant_name: str,
        report_email: str,
        orders: List[OrderPoDRecord],
        primary_color_hex: str = "1E40AF",
        smtp_override: Optional[dict] = None,
    ) -> bytes:
        """
        Excel raporunu oluşturur ve işletmenin `report_email` adresine e-posta eki olarak gönderir.
        Oluşturulan Excel dosyasının byte verisini de geri döndürür.
        """
        if not orders:
            raise ValueError("Arşivlenecek tamamlanmış sipariş bulunamadı.")

        excel_bytes = self.generate_pod_excel_bytes(
            tenant_name=tenant_name,
            orders=orders,
            primary_color_hex=primary_color_hex,
        )

        timestamp_slug = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_tenant = "".join(c if c.isalnum() else "_" for c in tenant_name).strip("_")
        order_suffix = (
            f"_{''.join(c if c.isalnum() else '_' for c in orders[0].order_number)}"
            if len(orders) == 1
            else ""
        )
        filename = f"PoD_Arsiv_{safe_tenant}{order_suffix}_{timestamp_slug}.xlsx"

        # KURAL 1.3: SMTP ayarlı olmasa bile fotoğraflı/imzalı Excel'i mutlaka backend/excel_arsiv/ klasörüne kaydet!
        archive_dir = Path(__file__).resolve().parent.parent.parent / "excel_arsiv"
        archive_dir.mkdir(parents=True, exist_ok=True)
        local_archive_path = archive_dir / filename
        local_archive_path.write_bytes(excel_bytes)
        logger.info("Fotoğraflı & İmzalı PoD Excel arşive kaydedildi: %s", local_archive_path)

        # E-posta Mesajını Hazırla
        msg = EmailMessage()
        if len(orders) == 1:
            msg["Subject"] = f"[{tenant_name}] Sipariş Teslim Kanıtı (PoD) — #{orders[0].order_number}"
        else:
            msg["Subject"] = f"[{tenant_name}] Toplu Teslimat Kanıtı Arşivi ({len(orders)} Sipariş)"

        msg["From"] = f"{tenant_name} Teslimat Sistemi <{self.smtp_config.sender_email}>"
        msg["To"] = report_email

        # Düz Metin ve HTML Gövdesi
        msg.set_content(
            f"Merhaba {tenant_name} Yönetimi,\n\n"
            f"Tamamlanan {len(orders)} adet teslimata ait Fotoğraf ve Alıcı İmzası gömülü "
            f"Excel arşiv dosyanız ({filename}) ekte yer almaktadır.\n\n"
            f"İyi çalışmalar dileriz."
        )

        rows_html = "".join(
            f"<tr>"
            f"<td style='padding:8px;border:1px solid #cbd5e1;'><b>{o.order_number}</b></td>"
            f"<td style='padding:8px;border:1px solid #cbd5e1;'>{o.customer_name}</td>"
            f"<td style='padding:8px;border:1px solid #cbd5e1;'>{o.driver_name}</td>"
            f"<td style='padding:8px;border:1px solid #cbd5e1;'>{o.delivery_address}</td>"
            f"</tr>"
            for o in orders
        )

        msg.add_alternative(
            f"""
            <html>
              <body style="font-family: Arial, sans-serif; color: #1e293b;">
                <div style="background-color: #{primary_color_hex.lstrip('#')}; color: #ffffff; padding: 16px 24px; border-radius: 8px 8px 0 0;">
                  <h2 style="margin: 0;">{tenant_name} — Teslimat Kanıtı (PoD) Raporu</h2>
                </div>
                <div style="border: 1px solid #e2e8f0; padding: 20px; border-radius: 0 0 8px 8px;">
                  <p>Merhaba,</p>
                  <p>Tamamlanan <b>{len(orders)}</b> adet siparişe ait teslimat fotoğrafları, alıcı imzaları ve konum bilgileri ekteki <b>{filename}</b> dosyasında ilgili hücrelerin içine gömülü olarak arşivlenmiştir.</p>
                  <table style="border-collapse: collapse; width: 100%; margin-top: 12px; font-size: 14px;">
                    <thead>
                      <tr style="background-color: #f1f5f9; text-align: left;">
                        <th style="padding:8px;border:1px solid #cbd5e1;">Sipariş No</th>
                        <th style="padding:8px;border:1px solid #cbd5e1;">Müşteri</th>
                        <th style="padding:8px;border:1px solid #cbd5e1;">Kurye</th>
                        <th style="padding:8px;border:1px solid #cbd5e1;">Adres</th>
                      </tr>
                    </thead>
                    <tbody>
                      {rows_html}
                    </tbody>
                  </table>
                  <p style="margin-top: 20px; font-size: 12px; color: #64748b;">
                    Bu e-posta {tenant_name} Teslimat Yönetim Sistemi tarafından otomatik oluşturulmuştur.
                  </p>
                </div>
              </body>
            </html>
            """,
            subtype="html",
        )

        # .xlsx Dosyasını Ekle
        msg.add_attachment(
            excel_bytes,
            maintype="application",
            subtype="vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            filename=filename,
        )

        # SMTP kimlik bilgileri tanımlıysa gönder (Önce uygulama içi tenant SMTP ayarlarına bak)
        eff_host = (smtp_override or {}).get("host") or self.smtp_config.host
        eff_port = int((smtp_override or {}).get("port") or self.smtp_config.port or 587)
        eff_user = (smtp_override or {}).get("user") or self.smtp_config.username
        eff_pass = (smtp_override or {}).get("password") or self.smtp_config.password

        if eff_user and eff_pass:
            del msg["From"]
            msg["From"] = f"{tenant_name} Teslimat Sistemi <{eff_user}>"
            with smtplib.SMTP(eff_host, eff_port, timeout=20) as server:
                if self.smtp_config.use_tls:
                    server.starttls()
                server.login(eff_user, eff_pass)
                server.send_message(msg)
            logger.info("PoD Excel arşivi başarıyla e-posta ile gönderildi -> %s (%s)", report_email, filename)
        else:
            logger.info(
                "SMTP bilgileri tanımlı olmadığı için e-posta adımı atlandı; Excel dosyası yerel arşive kaydedildi: %s (%d byte)",
                local_archive_path,
                len(excel_bytes),
            )

        return excel_bytes

    def send_password_reset_otp_email(
        self,
        *,
        to_email: str,
        code: str,
        full_name: str,
        tenant_name: str,
        smtp_override: Optional[dict] = None,
    ) -> bool:
        """
        Şifremi Unuttum akışı için 6 haneli sıfırlama kodunu (OTP) kullanıcının
        e-posta adresine gerçek SMTP üzerinden gönderir.
        """
        eff_host = (smtp_override or {}).get("host") or self.smtp_config.host
        eff_port = int((smtp_override or {}).get("port") or self.smtp_config.port or 587)
        eff_user = (smtp_override or {}).get("user") or self.smtp_config.username
        eff_pass = (smtp_override or {}).get("password") or self.smtp_config.password

        if not eff_user or not eff_pass:
            logger.warning(
                "SMTP bilgileri girilmediği için şifre sıfırlama e-postası gönderilemedi (Alıcı: %s, Kod: %s)",
                to_email,
                code,
            )
            return False

        msg = EmailMessage()
        msg["Subject"] = f"[{tenant_name}] Şifre Sıfırlama Kodunuz: {code}"
        msg["From"] = f"{tenant_name} Güvenlik Merkezi <{eff_user}>"
        msg["To"] = to_email

        msg.set_content(
            f"Merhaba {full_name},\n\n"
            f"Şifrenizi sıfırlamak için 6 haneli doğrulama kodunuz: {code}\n"
            f"Bu kod 15 dakika boyunca geçerlidir.\n\n"
            f"{tenant_name} Teslimat & PoD Yönetim Sistemi"
        )
        msg.add_alternative(
            f"""
            <html>
              <body style="font-family: Arial, sans-serif; color: #1e293b;">
                <div style="max-width: 480px; margin: 0 auto; border: 1px solid #cbd5e1; border-radius: 12px; overflow: hidden;">
                  <div style="background-color: #1e40af; color: #ffffff; padding: 16px 20px;">
                    <h3 style="margin: 0;">{tenant_name} — Şifre Sıfırlama Kodu</h3>
                  </div>
                  <div style="padding: 24px;">
                    <p>Merhaba <b>{full_name}</b>,</p>
                    <p>Hesabınızın şifresini yenilemek için aşağıdaki 6 haneli doğrulama kodunu uygulama ekranına girin:</p>
                    <div style="background-color: #f1f5f9; border: 2px dashed #1e40af; border-radius: 10px; padding: 16px; text-align: center; font-size: 28px; font-weight: bold; letter-spacing: 6px; color: #1e3a8a; margin: 20px 0;">
                      {code}
                    </div>
                    <p style="font-size: 13px; color: #64748b;">Bu kod güvenlik nedeniyle 15 dakika boyunca geçerlidir.</p>
                  </div>
                </div>
              </body>
            </html>
            """,
            subtype="html",
        )

        with smtplib.SMTP(eff_host, eff_port, timeout=20) as server:
            if self.smtp_config.use_tls:
                server.starttls()
            server.login(eff_user, eff_pass)
            server.send_message(msg)
        logger.info("6 haneli şifre sıfırlama kodu e-posta ile gönderildi -> %s", to_email)
        return True


# ============================================================================
# HIZLI TEST VE ÖRNEK ÇALIŞTIRMA BLOĞU
# ============================================================================
def _create_sample_photo_bytes() -> bytes:
    """Test amaçlı örnek bir teslimat fotoğrafı (koli görseli) üretir."""
    img = PILImage.new("RGB", (400, 300), color=(226, 232, 240))
    draw = ImageDraw.Draw(img)
    # Koli kutusu çizimi
    draw.rectangle([90, 60, 310, 240], fill=(217, 119, 6), outline=(120, 53, 15), width=4)
    draw.line([90, 110, 310, 110], fill=(120, 53, 15), width=3)
    draw.rectangle([175, 60, 225, 140], fill=(254, 243, 199))
    draw.text((125, 180), "TESLIM EDILDI - POD", fill=(255, 255, 255))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _create_sample_signature_bytes() -> bytes:
    """Test amaçlı şeffaf arka planlı (RGBA) örnek bir müşteri imzası üretir."""
    img = PILImage.new("RGBA", (400, 200), color=(0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # İmza çizgileri
    points = [(40, 130), (95, 55), (130, 145), (185, 65), (230, 125), (340, 95)]
    draw.line(points, fill=(15, 23, 42, 255), width=5, joint="curve")
    draw.arc([70, 50, 310, 170], start=170, end=355, fill=(30, 64, 175, 255), width=3)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


if __name__ == "__main__":
    sample_service = ExcelPoDMailerService()
    sample_order = OrderPoDRecord(
        order_number="SIP-2026-1042",
        customer_name="Ahmet Yılmaz",
        customer_phone="+90 532 000 11 22",
        delivery_address="Atatürk Mah. Ertuğrul Gazi Sok. No: 14 Kat: 3 Ataşehir / İstanbul",
        driver_name="Mehmet Demir",
        driver_plate="34 KRG 2026",
        recipient_name="Ahmet Yılmaz (Kendisi)",
        delivered_at=datetime.now(),
        dest_lat=40.992310,
        dest_lng=29.124420,
        delivered_lat=40.992345,
        delivered_lng=29.124401,
        pod_photo=_create_sample_photo_bytes(),
        pod_signature=_create_sample_signature_bytes(),
    )

    xlsx_data = sample_service.generate_pod_excel_bytes(
        tenant_name="Yıldız Ekspres Kargo",
        orders=[sample_order],
        primary_color_hex="#1E40AF",
    )

    output_path = Path("ornek_pod_arsivi.xlsx")
    output_path.write_bytes(xlsx_data)
    print(f"Örnek gömülü fotoğraflı ve imzalı Excel oluşturuldu: {output_path.resolve()} ({len(xlsx_data)} bytes)")
