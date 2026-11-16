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


POD_EXCEL_TRANSLATIONS = {
    "tr": {
        "sheet_title": "Teslimat Kanıtı Arşivi",
        "title_suffix": "TESLİMAT KANITI (PoD) VE SİPARİŞ ARŞİV RAPORU",
        "report_date": "Rapor Oluşturulma Tarihi",
        "total_orders": "Toplam Tamamlanan Sipariş",
        "units": "Adet",
        "osm_note": "Harita Altyapısı: OpenStreetMap (GMS Bağımsız)",
        "headers": [
            "Sipariş No",
            "Müşteri Bilgisi",
            "Teslimat Adresi",
            "Kurye / Araç",
            "Teslim Saati",
            "Koordinat (OSM)",
            "Teslimat Fotoğrafı",
            "Alıcı İmzası",
        ],
        "no_photo": "Fotoğraf Yok",
        "no_signature": "İmza Yok",
        "open_map": "Haritada Aç",
        "phone_label": "Tel",
        "recipient_label": "Teslim Alan",
        "plate_label": "Plaka",
        "single_email_subject": "[{tenant_name}] Sipariş Teslim Kanıtı (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] Toplu Teslimat Kanıtı Arşivi ({count} Sipariş)",
        "email_greeting": "Merhaba {tenant_name} Yönetimi,",
        "email_body_intro": "Tamamlanan {count} adet teslimata ait Fotoğraf ve Alıcı İmzası gömülü Excel arşiv dosyanız ({filename}) ekte yer almaktadır.",
        "email_signoff": "İyi çalışmalar dileriz.",
        "email_footer": "Bu e-posta {tenant_name} Teslimat Yönetim Sistemi tarafından otomatik oluşturulmuştur.",
        "otp_subject": "[{tenant_name}] Şifre Sıfırlama Doğrulama Kodunuz",
        "otp_title": "Şifre Sıfırlama Kodu",
        "otp_subtitle": "{tenant_name} Güvenlik Merkezi",
        "otp_greeting": "Merhaba {full_name},",
        "otp_intro": "Hesabınızın şifresini sıfırlamak için 6 haneli doğrulama kodunuz:",
        "otp_instructions": "Hesabınız için bir şifre sıfırlama talebi aldık. Uygulamadaki “Şifremi Unuttum” ekranına aşağıdaki 6 haneli doğrulama kodunu girin:",
        "otp_warning": "⏱️ Bu kod 15 dakika boyunca geçerlidir ve yalnızca bir kez kullanılabilir.<br>🛡️ Kodu kimseyle paylaşmayın. {tenant_name} çalışanları sizden asla bu kodu istemez.",
        "otp_ignore": "Bu talebi siz yapmadıysanız bu e-postayı görmezden gelebilirsiniz; şifreniz değişmeyecektir.",
        "otp_footer": "© {year} {tenant_name} • Teslimat &amp; PoD Yönetim Sistemi<br>Bu e-posta otomatik olarak gönderilmiştir, lütfen yanıtlamayın.",
    },
    "en": {
        "sheet_title": "Proof of Delivery Archive",
        "title_suffix": "PROOF OF DELIVERY (PoD) & ORDER ARCHIVE REPORT",
        "report_date": "Report Generated",
        "total_orders": "Total Completed Orders",
        "units": "Orders",
        "osm_note": "Map Infrastructure: OpenStreetMap (GMS Independent)",
        "headers": [
            "Order No",
            "Customer Info",
            "Delivery Address",
            "Courier / Vehicle",
            "Delivered At",
            "Coordinates (OSM)",
            "Delivery Photo",
            "Recipient Signature",
        ],
        "no_photo": "No Photo",
        "no_signature": "No Signature",
        "open_map": "Open Map",
        "phone_label": "Phone",
        "recipient_label": "Received By",
        "plate_label": "Plate",
        "single_email_subject": "[{tenant_name}] Proof of Delivery (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] Bulk Proof of Delivery Archive ({count} Orders)",
        "email_greeting": "Hello {tenant_name} Team,",
        "email_body_intro": "Your Excel archive file ({filename}) with embedded Delivery Photos and Recipient Signatures for {count} completed order(s) is attached.",
        "email_signoff": "Best regards,",
        "email_footer": "This email was automatically generated by {tenant_name} Delivery Management System.",
        "otp_subject": "[{tenant_name}] Password Reset Verification Code",
        "otp_title": "Password Reset Code",
        "otp_subtitle": "{tenant_name} Security Center",
        "otp_greeting": "Hello {full_name},",
        "otp_intro": "Your 6-digit verification code to reset your account password:",
        "otp_instructions": "We received a request to reset your password. Please enter the 6-digit verification code below in the app's 'Forgot Password' screen:",
        "otp_warning": "⏱️ This code is valid for 15 minutes and can be used only once.<br>🛡️ Do not share this code with anyone. {tenant_name} staff will never ask for it.",
        "otp_ignore": "If you did not request this, you can safely ignore this email; your password will not be changed.",
        "otp_footer": "© {year} {tenant_name} • Delivery &amp; PoD Management System<br>This is an automated email, please do not reply.",
    },
    "de": {
        "sheet_title": "Zustellnachweis-Archiv",
        "title_suffix": "ZUSTELLNACHWEIS (PoD) & AUFTRAGSARCHIV",
        "report_date": "Berichtserstellung",
        "total_orders": "Abgeschlossene Aufträge",
        "units": "Stück",
        "osm_note": "Karteninfrastruktur: OpenStreetMap (GMS-unabhängig)",
        "headers": [
            "Auftrags-Nr",
            "Kundeninfo",
            "Lieferadresse",
            "Kurier / Fahrzeug",
            "Lieferzeitpunkt",
            "Koordinaten (OSM)",
            "Lieferfoto",
            "Empfängerunterschrift",
        ],
        "no_photo": "Kein Foto",
        "no_signature": "Keine Unterschrift",
        "open_map": "Auf Karte öffnen",
        "phone_label": "Tel",
        "recipient_label": "Empfangen von",
        "plate_label": "Kennzeichen",
        "single_email_subject": "[{tenant_name}] Zustellnachweis (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] Sammel-Zustellnachweis-Archiv ({count} Aufträge)",
        "email_greeting": "Hallo {tenant_name} Leitung,",
        "email_body_intro": "Ihre Excel-Archivdatei ({filename}) mit eingebetteten Zustellfotos und Empfängerunterschriften für {count} Auftrag/Aufträge ist beigefügt.",
        "email_signoff": "Mit freundlichen Grüßen,",
        "email_footer": "Diese E-Mail wurde automatisch vom {tenant_name} Zustellsystem erstellt.",
        "otp_subject": "[{tenant_name}] Bestätigungscode zum Zurücksetzen des Passworts",
        "otp_title": "Passwort-Rücksetzcode",
        "otp_subtitle": "{tenant_name} Sicherheitszentrum",
        "otp_greeting": "Hallo {full_name},",
        "otp_intro": "Ihr 6-stelliger Bestätigungscode zum Zurücksetzen Ihres Passworts lautet:",
        "otp_instructions": "Wir haben eine Anfrage zum Zurücksetzen Ihres Passworts erhalten. Geben Sie den folgenden 6-stelligen Bestätigungscode in der App ein:",
        "otp_warning": "⏱️ Dieser Code ist 15 Minuten gültig und kann nur einmal verwendet werden.<br>🛡️ Teilen Sie den Code mit niemandem.",
        "otp_ignore": "Falls Sie dies nicht angefordert haben, können Sie diese E-Mail ignorieren.",
        "otp_footer": "© {year} {tenant_name} • Zustell- &amp; PoD-System<br>Automatische E-Mail, bitte nicht antworten.",
    },
    "es": {
        "sheet_title": "Archivo de Prueba de Entrega",
        "title_suffix": "PRUEBA DE ENTREGA (PoD) Y ARCHIVO DE PEDIDOS",
        "report_date": "Fecha de Generación",
        "total_orders": "Total de Pedidos Completados",
        "units": "Pedidos",
        "osm_note": "Infraestructura de Mapas: OpenStreetMap (Independiente de GMS)",
        "headers": [
            "Nº de Pedido",
            "Datos del Cliente",
            "Dirección de Entrega",
            "Repartidor / Vehículo",
            "Hora de Entrega",
            "Coordenadas (OSM)",
            "Foto de Entrega",
            "Firma del Receptor",
        ],
        "no_photo": "Sin Foto",
        "no_signature": "Sin Firma",
        "open_map": "Abrir en Mapa",
        "phone_label": "Tel",
        "recipient_label": "Recibido por",
        "plate_label": "Matrícula",
        "single_email_subject": "[{tenant_name}] Prueba de Entrega (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] Archivo de Entregas Múltiples ({count} Pedidos)",
        "email_greeting": "Hola equipo de {tenant_name},",
        "email_body_intro": "Se adjunta su archivo Excel ({filename}) con fotos de entrega y firmas para {count} pedido(s) completado(s).",
        "email_signoff": "Saludos cordiales,",
        "email_footer": "Este correo electrónico ha sido generado automáticamente por el Sistema {tenant_name}.",
        "otp_subject": "[{tenant_name}] Código de Verificación para Restablecer Contraseña",
        "otp_title": "Restablecimiento de Contraseña",
        "otp_subtitle": "Centro de Seguridad de {tenant_name}",
        "otp_greeting": "Hola {full_name},",
        "otp_intro": "Su código de verificación de 6 dígitos para restablecer su contraseña es:",
        "otp_instructions": "Hemos recibido una solicitud para restablecer su contraseña. Ingrese el siguiente código de 6 dígitos en la aplicación:",
        "otp_warning": "⏱️ Este código es válido durante 15 minutos y solo se puede usar una vez.<br>🛡️ No comparta este código con nadie.",
        "otp_ignore": "Si no solicitó esto, ignore este correo; su contraseña no se modificará.",
        "otp_footer": "© {year} {tenant_name} • Sistema de Gestión de Entregas y PoD<br>Correo automático, por favor no responda.",
    },
    "fr": {
        "sheet_title": "Archive Preuve de Livraison",
        "title_suffix": "PREUVE DE LIVRAISON (PoD) ET RAPPORT D'ARCHIVES",
        "report_date": "Date de Génération",
        "total_orders": "Commandes Livrées",
        "units": "Commandes",
        "osm_note": "Cartographie: OpenStreetMap (Indépendant de GMS)",
        "headers": [
            "N° Commande",
            "Info Client",
            "Adresse de Livraison",
            "Livreur / Véhicule",
            "Heure de Livraison",
            "Coordonnées (OSM)",
            "Photo de Livraison",
            "Signature Récepteur",
        ],
        "no_photo": "Sans Photo",
        "no_signature": "Sans Signature",
        "open_map": "Ouvrir sur la carte",
        "phone_label": "Tél",
        "recipient_label": "Reçu par",
        "plate_label": "Plaque",
        "single_email_subject": "[{tenant_name}] Preuve de Livraison (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] Archive Groupée de Livraisons ({count} Commandes)",
        "email_greeting": "Bonjour l'équipe {tenant_name},",
        "email_body_intro": "Votre fichier Excel ({filename}) avec photos de livraison et signatures pour {count} commande(s) est joint.",
        "email_signoff": "Cordialement,",
        "email_footer": "Cet e-mail a été généré automatiquement par le système {tenant_name}.",
        "otp_subject": "[{tenant_name}] Code de vérification de réinitialisation de mot de passe",
        "otp_title": "Réinitialisation de Mot de Passe",
        "otp_subtitle": "Centre de Sécurité {tenant_name}",
        "otp_greeting": "Bonjour {full_name},",
        "otp_intro": "Votre code de vérification à 6 chiffres pour réinitialiser votre mot de passe:",
        "otp_instructions": "Nous avons reçu une demande de réinitialisation de votre mot de passe. Entrez le code à 6 chiffres ci-dessous dans l'application:",
        "otp_warning": "⏱️ Ce code est valable 15 minutes et n'est utilisable qu'une seule fois.<br>🛡️ Ne partagez ce code avec personne.",
        "otp_ignore": "Si vous n'êtes pas à l'origine de cette demande, vous pouvez ignorer cet e-mail.",
        "otp_footer": "© {year} {tenant_name} • Gestion de Livraison &amp; PoD<br>E-mail automatique, ne pas répondre.",
    },
    "ar": {
        "sheet_title": "أرشيف إثبات التسليم",
        "title_suffix": "تقرير أرشيف إثبات التسليم (PoD) والطلبات",
        "report_date": "تاريخ إنشاء التتقرير",
        "total_orders": "إجمالي الطلبات المكتملة",
        "units": "طلب",
        "osm_note": "بنية الخرائط: OpenStreetMap (مستقل عن خدمات جوجل)",
        "headers": [
            "رقم الطلب",
            "بيانات العميل",
            "عنوان التسليم",
            "المندوب / المركبة",
            "وقت التسليم",
            "الإحداثيات (OSM)",
            "صورة التسليم",
            "توقيع المستلم",
        ],
        "no_photo": "لا توجد صورة",
        "no_signature": "لا يوجد توقيع",
        "open_map": "فتح في الخريطة",
        "phone_label": "الهاتف",
        "recipient_label": "المستلم",
        "plate_label": "اللوحة",
        "single_email_subject": "[{tenant_name}] إثبات تسليم الطلب (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] أرشيف إثباتات التسليم المجمعة ({count} طلب)",
        "email_greeting": "مرحباً بإدارة {tenant_name}،",
        "email_body_intro": "مرفق ملف Excel ({filename}) متضمناً صور التسليم وتوقيعات المستلمين لـ {count} طلب مكتمل.",
        "email_signoff": "مع أطيب التحيات،",
        "email_footer": "تم إنشاء هذا البريد تلقائياً بواسطة نظام إدارة التوصيل {tenant_name}.",
        "otp_subject": "[{tenant_name}] رمز التحقق لإعادة تعيين كلمة المرور",
        "otp_title": "رمز إعادة تعيين كلمة المرور",
        "otp_subtitle": "مركز الأمان {tenant_name}",
        "otp_greeting": "مرحباً {full_name}،",
        "otp_intro": "رمز التحقق المكون من 6 أرقام لإعادة تعيين كلمة مرور حسابك:",
        "otp_instructions": "تلقينا طلباً لإعادة تعيين كلمة المرور الخاصة بك. يرجى إدخال رمز التحقق التالي في التطبيق:",
        "otp_warning": "⏱️ هذا الرمز صالح لمدة 15 دقيقة فقط ويمكن استخدامه مرة واحدة.<br>🛡️ لا تشارك هذا الرمز مع أي شخص.",
        "otp_ignore": "إذا لم تكن قد طلبت ذلك، يمكنك تجاهل هذه الرسالة بأمان.",
        "otp_footer": "© {year} {tenant_name} • نظام إدارة التوصيل وإثبات التسليم<br>هذه رسالة آلية، يرجى عدم الرد.",
    },
    "ru": {
        "sheet_title": "Архив подтверждений доставки",
        "title_suffix": "ОТЧЕТ ПО ПОДТВЕРЖДЕНИЯМ ДОСТАВКИ (PoD) И ЗАКАЗАМ",
        "report_date": "Дата создания отчета",
        "total_orders": "Всего выполненных заказов",
        "units": "шт",
        "osm_note": "Картография: OpenStreetMap (не зависит от GMS)",
        "headers": [
            "№ Заказа",
            "Клиент",
            "Адрес доставки",
            "Курьер / Транспорт",
            "Время доставки",
            "Координаты (OSM)",
            "Фото доставки",
            "Подпись получателя",
        ],
        "no_photo": "Нет фото",
        "no_signature": "Нет подписи",
        "open_map": "Открыть на карте",
        "phone_label": "Тел",
        "recipient_label": "Получатель",
        "plate_label": "Номер авто",
        "single_email_subject": "[{tenant_name}] Подтверждение доставки (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] Архив подтверждений доставки ({count} заказов)",
        "email_greeting": "Здравствуйте, руководство {tenant_name},",
        "email_body_intro": "Во вложении находится архив Excel ({filename}) с фотографиями и подписями по {count} доставленным заказам.",
        "email_signoff": "С уважением,",
        "email_footer": "Это письмо создано автоматически системой управления доставкой {tenant_name}.",
        "otp_subject": "[{tenant_name}] Код подтверждения сброса пароля",
        "otp_title": "Код сброса пароля",
        "otp_subtitle": "Центр безопасности {tenant_name}",
        "otp_greeting": "Здравствуйте, {full_name},",
        "otp_intro": "Ваш 6-значный код подтверждения для сброса пароля:",
        "otp_instructions": "Мы получили запрос на сброс пароля. Введите следующий 6-значный код в приложении:",
        "otp_warning": "⏱️ Код действителен 15 минут и может быть использован только один раз.<br>🛡️ Никому не сообщайте этот код.",
        "otp_ignore": "Если вы не отправляли запрос, проигнорируйте это письмо.",
        "otp_footer": "© {year} {tenant_name} • Система управления доставкой и PoD<br>Автоматическое письмо, пожалуйста, не отвечайте.",
    },
    "id": {
        "sheet_title": "Arsip Bukti Pengiriman",
        "title_suffix": "LAPORAN ARSIP BUKTI PENGIRIMAN (PoD) & PESANAN",
        "report_date": "Tanggal Pembuatan",
        "total_orders": "Total Pesanan Selesai",
        "units": "Pesanan",
        "osm_note": "Infrastruktur Peta: OpenStreetMap (Bebas GMS)",
        "headers": [
            "No Pesanan",
            "Info Pelanggan",
            "Alamat Pengiriman",
            "Kurir / Kendaraan",
            "Waktu Pengiriman",
            "Koordinat (OSM)",
            "Foto Pengiriman",
            "Tanda Tangan Penerima",
        ],
        "no_photo": "Tidak Ada Foto",
        "no_signature": "Tidak Ada Tanda Tangan",
        "open_map": "Buka di Peta",
        "phone_label": "Telp",
        "recipient_label": "Diterima oleh",
        "plate_label": "Plat",
        "single_email_subject": "[{tenant_name}] Bukti Pengiriman (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] Arsip Bukti Pengiriman Massal ({count} Pesanan)",
        "email_greeting": "Halo Manajemen {tenant_name},",
        "email_body_intro": "Terlampir file arsip Excel ({filename}) dengan foto pengiriman dan tanda tangan untuk {count} pesanan yang selesai.",
        "email_signoff": "Salam hangat,",
        "email_footer": "Email ini dibuat secara otomatis oleh Sistem Manajemen Pengiriman {tenant_name}.",
        "otp_subject": "[{tenant_name}] Kode Verifikasi Reset Kata Sandi",
        "otp_title": "Kode Reset Kata Sandi",
        "otp_subtitle": "Pusat Keamanan {tenant_name}",
        "otp_greeting": "Halo {full_name},",
        "otp_intro": "Kode verifikasi 6 digit untuk mengatur ulang kata sandi Anda:",
        "otp_instructions": "Kami menerima permintaan pengaturan ulang kata sandi. Masukkan kode 6 digit berikut di aplikasi:",
        "otp_warning": "⏱️ Kode ini berlaku selama 15 menit dan hanya dapat digunakan sekali.<br>🛡️ Jangan bagikan kode ini kepada siapa pun.",
        "otp_ignore": "Jika Anda tidak meminta ini, abaikan email ini; kata sandi Anda tidak akan berubah.",
        "otp_footer": "© {year} {tenant_name} • Sistem Manajemen Pengiriman &amp; PoD<br>Email otomatis, mohon tidak membalas.",
    },
    "pt": {
        "sheet_title": "Arquivo de Comprovante de Entrega",
        "title_suffix": "RELATÓRIO DE COMPROVANTE DE ENTREGA (PoD) E PEDIDOS",
        "report_date": "Data de Geração",
        "total_orders": "Total de Pedidos Concluídos",
        "units": "Pedidos",
        "osm_note": "Infraestrutura de Mapas: OpenStreetMap (Independente de GMS)",
        "headers": [
            "Nº do Pedido",
            "Dados do Cliente",
            "Endereço de Entrega",
            "Entregador / Veículo",
            "Hora da Entrega",
            "Coordenadas (OSM)",
            "Foto da Entrega",
            "Assinatura do Receptor",
        ],
        "no_photo": "Sem Foto",
        "no_signature": "Sem Assinatura",
        "open_map": "Abrir no Mapa",
        "phone_label": "Tel",
        "recipient_label": "Recebido por",
        "plate_label": "Placa",
        "single_email_subject": "[{tenant_name}] Comprovante de Entrega (PoD) — #{order_number}",
        "batch_email_subject": "[{tenant_name}] Arquivo de Comprovantes em Lote ({count} Pedidos)",
        "email_greeting": "Olá equipe {tenant_name},",
        "email_body_intro": "Segue em anexo o arquivo Excel ({filename}) com fotos de entrega e assinaturas de {count} pedido(s) concluído(s).",
        "email_signoff": "Atenciosamente,",
        "email_footer": "Este e-mail foi gerado automaticamente pelo Sistema de Gestão {tenant_name}.",
        "otp_subject": "[{tenant_name}] Código de Verificação para Redefinir Senha",
        "otp_title": "Redefinição de Senha",
        "otp_subtitle": "Centro de Segurança {tenant_name}",
        "otp_greeting": "Olá {full_name},",
        "otp_intro": "Seu código de verificação de 6 dígitos para redefinir sua senha:",
        "otp_instructions": "Recebemos uma solicitação para redefinir sua senha. Digite o código de 6 dígitos abaixo no aplicativo:",
        "otp_warning": "⏱️ Este código é válido por 15 minutos e só pode ser usado uma vez.<br>🛡️ Não compartilhe este código com ninguém.",
        "otp_ignore": "Se você não fez essa solicitação, ignore este e-mail; sua senha não será alterada.",
        "otp_footer": "© {year} {tenant_name} • Sistema de Entregas e PoD<br>E-mail automático, por favor não responda.",
    },
}


def get_excel_mailer_i18n(lang: Optional[str]) -> dict:
    code = (lang or "tr").lower().strip()[:2]
    return POD_EXCEL_TRANSLATIONS.get(code, POD_EXCEL_TRANSLATIONS["tr"])


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
        language: str = "tr",
    ) -> bytes:
        """
        Verilen sipariş listesini ve PoD görsellerini (Fotoğraf + İmza)
        hücrelerin içine gömerek Excel (.xlsx) dosyası byte dizisi üretir.
        """
        wb = Workbook()
        ws = wb.active
        i18n = get_excel_mailer_i18n(language)
        ws.title = i18n["sheet_title"]

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
        ws["A1"] = f"{tenant_name.upper()} — {i18n['title_suffix']}"
        ws["A1"].fill = title_fill
        ws["A1"].font = title_font
        ws["A1"].alignment = center_align
        ws.row_dimensions[1].height = 34

        # 2. Satır: Rapor Meta Bilgisi
        ws.merge_cells("A2:H2")
        now_str = datetime.now().strftime("%d.%m.%Y %H:%M")
        ws["A2"] = (
            f"{i18n['report_date']}: {now_str}   |   "
            f"{i18n['total_orders']}: {len(orders)} {i18n['units']}   |   "
            f"{i18n['osm_note']}"
        )
        ws["A2"].font = subtitle_font
        ws["A2"].alignment = center_align
        ws.row_dimensions[2].height = 22

        # 3. Satır: Sütun Başlıkları
        headers = i18n["headers"]
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
            coord_text = f"{lat:.6f}, {lng:.6f}\n({i18n['open_map']})"
            osm_url = f"https://www.openstreetmap.org/?mlat={lat:.6f}&mlon={lng:.6f}#map=18/{lat:.6f}/{lng:.6f}"

            # Müşteri ve Kurye metinleri
            customer_text = f"{order.customer_name}\n{i18n['phone_label']}: {order.customer_phone}"
            if order.recipient_name:
                customer_text += f"\n{i18n['recipient_label']}: {order.recipient_name}"

            driver_text = order.driver_name
            if order.driver_plate:
                driver_text += f"\n{i18n['plate_label']}: {order.driver_plate}"

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
                ws.cell(row=row_num, column=7, value=i18n["no_photo"]).alignment = center_align

            # --- H Sütunu: Alıcı İmzasını Hücreye Göm ---
            sig_stream = cls._prepare_cell_image_stream(order.pod_signature, is_signature=True)
            if sig_stream:
                active_image_streams.append(sig_stream)
                xl_sig = XLImage(sig_stream)
                xl_sig.width = CELL_IMAGE_WIDTH_PX
                xl_sig.height = CELL_IMAGE_HEIGHT_PX
                ws.add_image(xl_sig, f"H{row_num}")
            else:
                ws.cell(row=row_num, column=8, value=i18n["no_signature"]).alignment = center_align

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
        language: str = "tr",
    ) -> bytes:
        """
        Excel raporunu oluşturur ve işletmenin `report_email` adresine e-posta eki olarak gönderir.
        Oluşturulan Excel dosyasının byte verisini de geri döndürür.
        """
        if not orders:
            raise ValueError("Arşivlenecek tamamlanmış sipariş bulunamadı.")

        i18n = get_excel_mailer_i18n(language)

        excel_bytes = self.generate_pod_excel_bytes(
            tenant_name=tenant_name,
            orders=orders,
            primary_color_hex=primary_color_hex,
            language=language,
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

        # E-posta Konusu ve Gövdesi
        if len(orders) == 1:
            subject = i18n["single_email_subject"].format(tenant_name=tenant_name, order_number=orders[0].order_number)
        else:
            subject = i18n["batch_email_subject"].format(tenant_name=tenant_name, count=len(orders))

        text_body = (
            f"{i18n['email_greeting'].format(tenant_name=tenant_name)}\n\n"
            f"{i18n['email_body_intro'].format(tenant_name=tenant_name, count=len(orders), filename=filename)}\n\n"
            f"{i18n['email_signoff']}"
        )

        rows_html = "".join(
            f"<tr>"
            f"<td style='padding:8px;border:1px solid #cbd5e1;'><b>{html_escape(o.order_number)}</b></td>"
            f"<td style='padding:8px;border:1px solid #cbd5e1;'>{html_escape(o.customer_name)}</td>"
            f"<td style='padding:8px;border:1px solid #cbd5e1;'>{html_escape(o.driver_name)}</td>"
            f"<td style='padding:8px;border:1px solid #cbd5e1;'>{html_escape(o.delivery_address)}</td>"
            f"</tr>"
            for o in orders
        )

        html_body = f"""
            <html>
              <body style="font-family: Arial, sans-serif; color: #1e293b;">
                <div style="background-color: #{primary_color_hex.lstrip('#')}; color: #ffffff; padding: 16px 24px; border-radius: 8px 8px 0 0;">
                  <h2 style="margin: 0;">{html_escape(tenant_name)} — {i18n['title_suffix']}</h2>
                </div>
                <div style="border: 1px solid #e2e8f0; padding: 20px; border-radius: 0 0 8px 8px;">
                  <p>{i18n['email_greeting'].format(tenant_name=html_escape(tenant_name))}</p>
                  <p>{i18n['email_body_intro'].format(tenant_name=html_escape(tenant_name), count=len(orders), filename=filename)}</p>
                  <table style="border-collapse: collapse; width: 100%; margin-top: 12px; font-size: 14px;">
                    <thead>
                      <tr style="background-color: #f1f5f9; text-align: left;">
                        <th style="padding:8px;border:1px solid #cbd5e1;">{i18n['headers'][0]}</th>
                        <th style="padding:8px;border:1px solid #cbd5e1;">{i18n['headers'][1]}</th>
                        <th style="padding:8px;border:1px solid #cbd5e1;">{i18n['headers'][3]}</th>
                        <th style="padding:8px;border:1px solid #cbd5e1;">{i18n['headers'][2]}</th>
                      </tr>
                    </thead>
                    <tbody>
                      {rows_html}
                    </tbody>
                  </table>
                  <p style="margin-top: 20px; font-size: 12px; color: #64748b;">
                    {i18n['email_footer'].format(tenant_name=html_escape(tenant_name))}
                  </p>
                </div>
              </body>
            </html>
            """

        # Herhangi bir e-posta kanalı (SMTP veya HTTP API) tanımlıysa gönder
        has_channel = resolve_smtp_credentials(smtp_override) is not None or bool(
            settings.RESEND_API_KEY or settings.BREVO_API_KEY or settings.SENDGRID_API_KEY
        )
        if has_channel:
            result = send_email(
                to_email=report_email,
                subject=subject,
                html_body=html_body,
                text_body=text_body,
                sender_name=f"{tenant_name} Teslimat Sistemi",
                attachments=[
                    EmailAttachment(
                        filename=filename,
                        content=excel_bytes,
                        mime_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    )
                ],
                smtp_override=smtp_override,
            )
            logger.info(
                "PoD Excel arşivi e-posta ile gönderildi (%s) -> %s (%s)",
                result.channel,
                report_email,
                filename,
            )
        else:
            logger.info(
                "E-posta kanalı tanımlı olmadığı için gönderim atlandı; Excel dosyası yerel arşive kaydedildi: %s (%d byte)",
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
        language: str = "tr",
    ) -> EmailDeliveryResult:
        """
        Şifremi Unuttum akışı için 6 haneli sıfırlama kodunu (OTP) şık bir HTML şablonla
        kullanıcının e-posta adresine gönderir (HTTP API -> SMTP 465 SSL -> 587 STARTTLS -> 2525).
        Gönderim başarısız olursa gerçek hata ayrıntılarını içeren `EmailDeliveryError` fırlatır.
        Kod hiçbir koşulda log'a veya API yanıtına yazılmaz.
        """
        i18n = get_excel_mailer_i18n(language)
        safe_name = html_escape(full_name or "User")
        safe_tenant = html_escape(tenant_name or "PoD System")
        digits_html = "".join(
            f'<td style="padding:0 4px;"><div style="width:44px;height:56px;line-height:56px;'
            f'background:#ffffff;border:2px solid #c7d2fe;border-radius:12px;font-size:30px;'
            f'font-weight:800;color:#1e3a8a;text-align:center;font-family:Consolas,Menlo,monospace;">{d}</div></td>'
            for d in str(code)
        )
        year = datetime.now().year

        subject = i18n["otp_subject"].format(tenant_name=tenant_name)
        text_body = (
            f"{i18n['otp_greeting'].format(full_name=full_name)}\n\n"
            f"{i18n['otp_intro']} {code}\n"
            f"{i18n['otp_warning'].replace('<br>', chr(10))}\n\n"
            f"{i18n['otp_ignore']}\n\n"
            f"{tenant_name}"
        )
        html_body = f"""<!DOCTYPE html>
<html lang="{language or 'en'}">
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
  <body style="margin:0;padding:0;background:#eef2ff;font-family:'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#0f172a;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2ff;padding:32px 12px;">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:20px;overflow:hidden;box-shadow:0 12px 32px rgba(30,58,138,0.15);">
          <tr>
            <td style="background:linear-gradient(135deg,#1e3a8a 0%,#4f46e5 100%);background-color:#1e3a8a;padding:28px 28px 24px;text-align:center;">
              <div style="font-size:40px;line-height:1;">🔐</div>
              <h1 style="margin:12px 0 4px;font-size:22px;color:#ffffff;font-weight:800;">{i18n['otp_title']}</h1>
              <p style="margin:0;font-size:13px;color:#c7d2fe;">{i18n['otp_subtitle'].format(tenant_name=safe_tenant)}</p>
            </td>
          </tr>
          <tr>
            <td style="padding:28px;">
              <p style="margin:0 0 12px;font-size:15px;">{i18n['otp_greeting'].format(full_name=f'<b>{safe_name}</b>')}</p>
              <p style="margin:0 0 20px;font-size:14px;line-height:1.6;color:#334155;">
                {i18n['otp_instructions']}
              </p>
              <table role="presentation" align="center" cellpadding="0" cellspacing="0" style="margin:0 auto 20px;background:#eef2ff;border-radius:16px;padding:16px 12px;">
                <tr>{digits_html}</tr>
              </table>
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fef9c3;border:1px solid #fde047;border-radius:12px;">
                <tr><td style="padding:12px 14px;font-size:12.5px;color:#854d0e;line-height:1.5;">
                  {i18n['otp_warning'].format(tenant_name=safe_tenant)}
                </td></tr>
              </table>
              <p style="margin:20px 0 0;font-size:12.5px;color:#64748b;line-height:1.5;">
                {i18n['otp_ignore']}
              </p>
            </td>
          </tr>
          <tr>
            <td style="background:#f8fafc;border-top:1px solid #e2e8f0;padding:16px 28px;text-align:center;font-size:11.5px;color:#94a3b8;">
              {i18n['otp_footer'].format(year=year, tenant_name=safe_tenant)}
            </td>
          </tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>"""

        result = send_email(
            to_email=to_email,
            subject=subject,
            html_body=html_body,
            text_body=text_body,
            sender_name=f"{tenant_name}",
            smtp_override=smtp_override,
        )
        logger.info("6 haneli şifre sıfırlama kodu e-posta ile gönderildi (%s) -> %s", result.channel, to_email)
        return result


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
