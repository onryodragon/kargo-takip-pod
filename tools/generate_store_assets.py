"""
generate_store_assets.py
-------------------------
Huawei AppGallery için:
1. Profesyonel Modern Lojistik/Canlı Takip Logosu (1024x1024 master, 512x512, 216x216 ve Android/Web ikonları)
2. 5 Adet AppGallery Dikey Mağaza Ekran Görüntüsü (1080x1920 px)
3. 1 Adet AppGallery Tanıtım Afişi (1080x540 px)
"""

import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT_DIR = Path(__file__).resolve().parent.parent
APPGALLERY_DIR = ROOT_DIR / "appgallery_yayin_paketi"
LOGOS_DIR = APPGALLERY_DIR / "2_logolar_ve_afisler"
SCREENSHOTS_DIR = APPGALLERY_DIR / "3_ekran_goruntuleri"
ANDROID_RES_DIR = ROOT_DIR / "mobile_and_web" / "android" / "app" / "src" / "main" / "res"
WEB_DIR = ROOT_DIR / "mobile_and_web" / "web"
WEB_ICONS_DIR = WEB_DIR / "icons"

LOGOS_DIR.mkdir(parents=True, exist_ok=True)
SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)
WEB_ICONS_DIR.mkdir(parents=True, exist_ok=True)

FONT_REGULAR = "C:/Windows/Fonts/segoeui.ttf"
FONT_BOLD = "C:/Windows/Fonts/segoeuib.ttf"
FONT_HEAVY = "C:/Windows/Fonts/segoeuiz.ttf"


def get_font(size: int, bold: bool = False, heavy: bool = False) -> ImageFont.FreeTypeFont:
    path = FONT_HEAVY if heavy else (FONT_BOLD if bold else FONT_REGULAR)
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf", size)


# ---------------------------------------------------------------------------
# 1. PROFESYONEL LOGO TASARIMI (1024x1024 Master)
# ---------------------------------------------------------------------------
def create_master_logo(size: int = 1024) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 1. Squircle (Yuvarlatılmış Kare) Arka Plan + Zengin Gradyan
    margin = int(size * 0.05)
    r = int(size * 0.22)
    box = (margin, margin, size - margin, size - margin)

    # Gradyan katmanı oluştur
    grad = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad_draw = ImageDraw.Draw(grad)
    for y in range(size):
        ratio = y / size
        # Koyu Gece Mavisi (#0B132B) -> Asil Kraliyet Mavisi (#1D4ED8) -> Canlı Turkuaz (#06B6D4)
        if ratio < 0.5:
            t = ratio / 0.5
            cr = int(11 * (1 - t) + 29 * t)
            cg = int(19 * (1 - t) + 78 * t)
            cb = int(43 * (1 - t) + 216 * t)
        else:
            t = (ratio - 0.5) / 0.5
            cr = int(29 * (1 - t) + 6 * t)
            cg = int(78 * (1 - t) + 182 * t)
            cb = int(216 * (1 - t) + 212 * t)
        grad_draw.line([(0, y), (size, y)], fill=(cr, cg, cb, 255))

    # Maske olarak Squircle uygula
    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(box, radius=r, fill=255)
    img.paste(grad, (0, 0), mask)

    # Dış İnce Işıma Çerçevesi
    border_draw = ImageDraw.Draw(img)
    border_draw.rounded_rectangle(box, radius=r, outline=(255, 255, 255, 75), width=int(size * 0.012))

    # 2. Modern Geometrik Kargo Paketi & GPS Konum Pini
    center_x = size // 2
    center_y = int(size * 0.58)

    # Kargo Paketi (İzometrik 3D Küp Perspektifi)
    box_w = int(size * 0.28)
    box_h = int(size * 0.24)

    # Alt/Ön Sol Yüz (#F8FAFC)
    p_top = (center_x, center_y - box_h)
    p_center = (center_x, center_y)
    p_bottom = (center_x, center_y + box_h)
    p_left = (center_x - box_w, center_y - int(box_h * 0.5))
    p_bottom_left = (center_x - box_w, center_y + int(box_h * 0.5))
    p_right = (center_x + box_w, center_y - int(box_h * 0.5))
    p_bottom_right = (center_x + box_w, center_y + int(box_h * 0.5))

    # Üst Yüz (Açık Altın / Amber Vurgulu Kargo Bandı)
    draw.polygon([p_top, p_right, p_center, p_left], fill=(254, 240, 138, 255))
    # Ön Sol Yüz (Temiz Karton / Beyaz Vurgulu)
    draw.polygon([p_left, p_center, p_bottom, p_bottom_left], fill=(226, 232, 240, 245))
    # Ön Sağ Yüz (Gölgeli Yüz)
    draw.polygon([p_center, p_right, p_bottom_right, p_bottom], fill=(148, 163, 184, 245))

    # Paket Koli Bandı Çizgileri
    draw.line([p_top, p_center], fill=(217, 119, 6, 255), width=int(size * 0.018))
    draw.line([p_center, p_bottom], fill=(217, 119, 6, 255), width=int(size * 0.018))

    # 3. Canlı Konum (GPS) Pini (Üstte Yükselen Parlak Turkuaz/Zümrüt Pin)
    pin_x = center_x
    pin_y = int(size * 0.32)
    pin_r = int(size * 0.13)

    # Pin Dış Işıması (Neon Parlama)
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        (pin_x - pin_r - 20, pin_y - pin_r - 20, pin_x + pin_r + 20, pin_y + pin_r + 20),
        fill=(6, 182, 212, 100),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(16))
    img.paste(glow, (0, 0), glow)

    # Pin Gövdesi (Teardrop / Konum İğnesi)
    pin_tip = (pin_x, pin_y + int(pin_r * 1.55))
    pin_left = (pin_x - int(pin_r * 0.88), pin_y + int(pin_r * 0.3))
    pin_right = (pin_x + int(pin_r * 0.88), pin_y + int(pin_r * 0.3))

    draw.polygon([pin_left, pin_tip, pin_right], fill=(16, 185, 129, 255))
    draw.ellipse((pin_x - pin_r, pin_y - pin_r, pin_x + pin_r, pin_y + pin_r), fill=(16, 185, 129, 255))
    draw.ellipse(
        (pin_x - pin_r, pin_y - pin_r, pin_x + pin_r, pin_y + pin_r),
        outline=(255, 255, 255, 230),
        width=int(size * 0.014),
    )

    # Pin İçi Beyaz Nokta / Radar
    inner_r = int(pin_r * 0.38)
    draw.ellipse((pin_x - inner_r, pin_y - inner_r, pin_x + inner_r, pin_y + inner_r), fill=(255, 255, 255, 255))

    # 4. Teslimat Onay Rozeti (Sağ Altta Yeşil Kalkan/Onay)
    badge_x = int(size * 0.74)
    badge_y = int(size * 0.72)
    badge_r = int(size * 0.13)

    draw.ellipse(
        (badge_x - badge_r, badge_y - badge_r, badge_x + badge_r, badge_y + badge_r),
        fill=(37, 99, 235, 255),
        outline=(255, 255, 255, 255),
        width=int(size * 0.016),
    )

    # Beyaz Onay Tipi (Checkmark)
    ck1 = (badge_x - int(badge_r * 0.45), badge_y)
    ck2 = (badge_x - int(badge_r * 0.1), badge_y + int(badge_r * 0.4))
    ck3 = (badge_x + int(badge_r * 0.45), badge_y - int(badge_r * 0.35))
    draw.line([ck1, ck2, ck3], fill=(255, 255, 255, 255), width=int(size * 0.024), joint="curve")

    return img


def export_app_icons(master: Image.Image) -> None:
    print("[1/3] Logo ve Uygulama İkonları Üretiliyor...")

    # 1. AppGallery 512x512 ve 216x216
    icon_512 = master.resize((512, 512), Image.Resampling.LANCZOS)
    icon_512.save(LOGOS_DIR / "app_icon_512x512.png", "PNG", optimize=True)

    icon_216 = master.resize((216, 216), Image.Resampling.LANCZOS)
    icon_216.save(LOGOS_DIR / "app_icon_216x216.png", "PNG", optimize=True)

    # 2. Android Mipmap İkonları
    sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, px in sizes.items():
        target_dir = ANDROID_RES_DIR / folder
        target_dir.mkdir(parents=True, exist_ok=True)
        resized = master.resize((px, px), Image.Resampling.LANCZOS)
        resized.save(target_dir / "ic_launcher.png", "PNG", optimize=True)

    # 3. Web İkonları
    web_sizes = {
        "Icon-192.png": 192,
        "Icon-512.png": 512,
        "Icon-maskable-192.png": 192,
        "Icon-maskable-512.png": 512,
    }
    for fname, px in web_sizes.items():
        resized = master.resize((px, px), Image.Resampling.LANCZOS)
        resized.save(WEB_ICONS_DIR / fname, "PNG", optimize=True)

    favicon = master.resize((64, 64), Image.Resampling.LANCZOS)
    favicon.save(WEB_DIR / "favicon.png", "PNG", optimize=True)

    print("  -> Logolar ve Android/Web ikonları başarıyla kaydedildi.")


# ---------------------------------------------------------------------------
# 2. MAĞAZA EKRAN GÖRÜNTÜLERİ (1080x1920 px Dikey)
# ---------------------------------------------------------------------------
def draw_gradient_background(draw: ImageDraw.ImageDraw, w: int, h: int, top_color, bottom_color):
    for y in range(h):
        t = y / h
        r = int(top_color[0] * (1 - t) + bottom_color[0] * t)
        g = int(top_color[1] * (1 - t) + bottom_color[1] * t)
        b = int(top_color[2] * (1 - t) + bottom_color[2] * t)
        draw.line([(0, y), (w, y)], fill=(r, g, b))


def draw_device_mockup(
    base: Image.Image,
    title_badge: str,
    headline: str,
    subheadline: str,
    accent_color: tuple,
    screen_builder_fn,
) -> Image.Image:
    w, h = 1080, 1920
    canvas = Image.new("RGBA", (w, h), (15, 23, 42, 255))
    draw = ImageDraw.Draw(canvas)

    # Zengin Arka Plan Gradyanı
    draw_gradient_background(draw, w, h, (15, 23, 42), (30, 58, 138))

    # Dekoratif Radar / Işık Halka Çizgileri
    for rad in [260, 420, 600, 800]:
        draw.arc(
            (w // 2 - rad, 120 - rad, w // 2 + rad, 120 + rad),
            start=0,
            end=360,
            fill=(255, 255, 255, 14),
            width=2,
        )

    # 1. Üst Rozet (Badge Pill)
    badge_font = get_font(26, bold=True)
    badge_text = f"  {title_badge}  "
    bbox = badge_font.getbbox(badge_text)
    bw = bbox[2] - bbox[0] + 32
    bh = 54
    bx = (w - bw) // 2
    by = 90
    draw.rounded_rectangle((bx, by, bx + bw, by + bh), radius=27, fill=(*accent_color, 45), outline=(*accent_color, 180), width=2)
    draw.text((bx + 16, by + 10), badge_text.strip(), fill=(255, 255, 255), font=badge_font)

    # 2. Ana Başlık (Türkçe 2 Satır)
    title_font = get_font(52, heavy=True)
    draw.text((w // 2, 210), headline, fill=(255, 255, 255), font=title_font, anchor="mm", align="center")

    # 3. Alt Açıklama
    sub_font = get_font(28, bold=False)
    draw.text((w // 2, 305), subheadline, fill=(203, 213, 225), font=sub_font, anchor="mm", align="center")

    # 4. Telefon Cihaz Çerçevesi (Device Frame Mockup)
    phone_w = 880
    phone_h = 1440
    px = (w - phone_w) // 2
    py = 420
    pr = 56

    # Telefon Dış Gövde & Gölge
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    s_draw = ImageDraw.Draw(shadow)
    s_draw.rounded_rectangle((px - 8, py - 4, px + phone_w + 8, py + phone_h + 16), radius=pr + 6, fill=(0, 0, 0, 160))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    canvas.paste(shadow, (0, 0), shadow)

    draw.rounded_rectangle((px, py, px + phone_w, py + phone_h), radius=pr, fill=(30, 41, 59), outline=(100, 116, 139), width=8)

    # Telefon Ekran İçi Alanı
    scr_m = 16
    scr_x = px + scr_m
    scr_y = py + scr_m
    scr_w = phone_w - (scr_m * 2)
    scr_h = phone_h - (scr_m * 2)

    scr_img = Image.new("RGBA", (scr_w, scr_h), (241, 245, 249, 255))
    scr_draw = ImageDraw.Draw(scr_img)

    # Ekran Tasarım Fonksiyonunu Çağır
    screen_builder_fn(scr_img, scr_draw, scr_w, scr_h, accent_color)

    # Dinamik Ada / Kamera Çentiği (Dynamic Island Mockup)
    island_w = 160
    island_h = 32
    ix = (scr_w - island_w) // 2
    scr_draw.rounded_rectangle((ix, 14, ix + island_w, 14 + island_h), radius=16, fill=(15, 23, 42, 255))
    scr_draw.ellipse((ix + island_w - 30, 22, ix + island_w - 14, 38), fill=(30, 41, 59, 255))

    # Maskeli Yapıştır (Köşeler telefon çerçevesine otursun)
    scr_mask = Image.new("L", (scr_w, scr_h), 0)
    ImageDraw.Draw(scr_mask).rounded_rectangle((0, 0, scr_w, scr_h), radius=pr - 12, fill=255)
    canvas.paste(scr_img, (scr_x, scr_y), scr_mask)

    return canvas


# --- Mock 1: Canlı Harita & 24 Saat Görünürlük ---
def build_screen_1(img: Image.Image, draw: ImageDraw.ImageDraw, w: int, h: int, color):
    # Üst Harita Görsel Simülasyonu
    draw.rectangle((0, 0, w, int(h * 0.62)), fill=(224, 231, 255))

    # Yollar (Cadde & Sokaklar)
    for y in [120, 240, 380, 520, 680]:
        draw.line([(0, y), (w, y + 40)], fill=(255, 255, 255), width=24)
    for x in [140, 320, 540, 720]:
        draw.line([(x, 0), (x - 40, int(h * 0.62))], fill=(255, 255, 255), width=20)

    # Karayolu Rota Çizgisi (OSRM Mavi Çizgi)
    route = [(180, 560), (320, 420), (540, 440), (520, 260)]
    draw.line(route, fill=(37, 99, 235), width=10, joint="curve")

    # Kurye Aracı Pin (Radar dalgalı)
    cx, cy = 320, 420
    draw.ellipse((cx - 45, cy - 45, cx + 45, cy + 45), fill=(37, 99, 235, 80))
    draw.ellipse((cx - 26, cy - 26, cx + 26, cy + 26), fill=(37, 99, 235), outline=(255, 255, 255), width=4)
    draw.text((cx, cy), "🛵", font=get_font(24), anchor="mm")
    draw.rounded_rectangle((cx - 95, cy - 70, cx + 95, cy - 42), radius=12, fill=(15, 23, 42), outline=(255, 255, 255), width=2)
    draw.text((cx, cy - 56), "Ahmet K. • 34 KRY 26", fill=(255, 255, 255), font=get_font(14, bold=True), anchor="mm")

    # Teslimat Hedef Pini
    tx, ty = 520, 260
    draw.polygon([(tx - 18, ty - 20), (tx, ty + 18), (tx + 18, ty - 20)], fill=(220, 38, 38))
    draw.ellipse((tx - 24, ty - 44, tx + 24, ty + 4), fill=(220, 38, 38), outline=(255, 255, 255), width=3)
    draw.ellipse((tx - 9, ty - 20, tx + 9, ty - 2), fill=(255, 255, 255))
    draw.rounded_rectangle((tx - 80, ty - 76, tx + 80, ty - 48), radius=10, fill=(30, 41, 59))
    draw.text((tx, ty - 62), "1. Durak • #1042", fill=(255, 255, 255), font=get_font(13, bold=True), anchor="mm")

    # Üst Cam Bar: Canlı Yayın 🟢 Rozeti
    draw.rounded_rectangle((24, 60, w - 24, 120), radius=18, fill=(255, 255, 255, 235), outline=(147, 197, 253), width=2)
    draw.ellipse((48, 83, 62, 97), fill=(22, 163, 74))
    draw.text((74, 90), "CANLI YAYIN • Kuryeniz 1.4 km mesafede (~4 dk)", fill=(15, 23, 42), font=get_font(18, bold=True), anchor="lm")

    # Alt Sipariş & 24 Saat Görünürlük Kartı
    card_y = int(h * 0.64)
    draw.rounded_rectangle((20, card_y, w - 20, h - 24), radius=22, fill=(255, 255, 255), outline=(226, 232, 240), width=2)
    draw.text((44, card_y + 36), "Sipariş #1042 — Zeynep Kaya", fill=(15, 23, 42), font=get_font(26, bold=True))
    draw.text((44, card_y + 74), "Bağdat Cad. No: 184/6 Kadıköy / İstanbul", fill=(100, 116, 139), font=get_font(18))

    # 24 Saat Rozeti
    draw.rounded_rectangle((44, card_y + 115, 420, card_y + 165), radius=12, fill=(240, 253, 244), outline=(134, 239, 172))
    draw.text((60, card_y + 140), "⏱ Haritada Görünürlük: 23s 48dk", fill=(21, 128, 61), font=get_font(17, bold=True), anchor="lm")

    # Müşteri Takip Butonu
    draw.rounded_rectangle((44, card_y + 190, w - 44, card_y + 260), radius=16, fill=(37, 99, 235))
    draw.text((w // 2, card_y + 225), "WhatsApp'tan Canlı Takip Gönder 🚀", fill=(255, 255, 255), font=get_font(20, bold=True), anchor="mm")


# --- Mock 2: Sürücü Filosu & Boşta/Meşgul Durumu ---
def build_screen_2(img: Image.Image, draw: ImageDraw.ImageDraw, w: int, h: int, color):
    # Üst Bölüm: Hızlı Davet Kartı
    draw.rounded_rectangle((20, 60, w - 20, 200), radius=18, fill=(255, 255, 255), outline=(187, 247, 208), width=2)
    draw.text((40, 90), "Yeni Sürücü Davet Et (WhatsApp)", fill=(21, 128, 61), font=get_font(22, bold=True))
    draw.rounded_rectangle((40, 120, w - 210, 180), radius=12, fill=(248, 250, 252), outline=(203, 213, 225))
    draw.text((60, 150), "0532 123 45 67", fill=(51, 65, 85), font=get_font(18), anchor="lm")
    draw.rounded_rectangle((w - 195, 120, w - 40, 180), radius=12, fill=(22, 163, 74))
    draw.text((w - 118, 150), "Davet Et 🚀", fill=(255, 255, 255), font=get_font(18, bold=True), anchor="mm")

    # Filtre Çipleri
    chips = [("Tümü (4)", True), ("🟢 Boşta (2)", False), ("🔴 Meşgul (2)", False)]
    cx = 24
    for txt, active in chips:
        bw = len(txt) * 16 + 24
        draw.rounded_rectangle((cx, 220, cx + bw, 265), radius=14, fill=(37, 99, 235) if active else (255, 255, 255), outline=(37, 99, 235))
        draw.text((cx + bw // 2, 242), txt, fill=(255, 255, 255) if active else (37, 99, 235), font=get_font(16, bold=True), anchor="mm")
        cx += bw + 12

    # Sürücü Kartları
    drivers = [
        ("Mehmet Demir", "34 KRY 88", "Motosiklet", "🔴 Meşgul (2 Görevde)", (220, 38, 38), (254, 226, 226)),
        ("Ali Yıldız", "34 PLK 104", "Panelvan", "🟢 Boşta / Müsait", (22, 163, 74), (220, 252, 231)),
        ("Can Eren", "34 BSK 12", "Bisiklet", "🟢 Boşta / Müsait", (22, 163, 74), (220, 252, 231)),
        ("Burak Arda", "34 ARB 55", "Otomobil", "🔴 Meşgul (1 Görevde)", (220, 38, 38), (254, 226, 226)),
    ]

    dy = 285
    for name, plate, vtype, status, sc, sbg in drivers:
        draw.rounded_rectangle((20, dy, w - 20, dy + 155), radius=18, fill=(255, 255, 255), outline=(226, 232, 240), width=2)
        # Sürücü Avatar
        draw.ellipse((40, dy + 35, 120, dy + 115), fill=(241, 245, 249))
        draw.text((80, dy + 75), "🛵" if "Moto" in vtype else "🚐", font=get_font(32), anchor="mm")

        draw.text((140, dy + 35), name, fill=(15, 23, 42), font=get_font(24, bold=True))
        draw.text((140, dy + 72), f"{plate} • {vtype}", fill=(100, 116, 139), font=get_font(18))

        # Durum Rozeti
        draw.rounded_rectangle((140, dy + 105, 340, dy + 140), radius=10, fill=sbg)
        draw.text((150, dy + 122), status, fill=sc, font=get_font(14, bold=True), anchor="lm")

        # Görev Ver Butonu
        draw.rounded_rectangle((w - 180, dy + 50, w - 36, dy + 105), radius=12, fill=(37, 99, 235))
        draw.text((w - 108, dy + 78), "Görev Ver +", fill=(255, 255, 255), font=get_font(16, bold=True), anchor="mm")
        dy += 175


# --- Mock 3: Zorunlu Fotoğraf ve Islak İmza ---
def build_screen_3(img: Image.Image, draw: ImageDraw.ImageDraw, w: int, h: int, color):
    # Üst Uyarı Rozeti
    draw.rounded_rectangle((20, 60, w - 20, 150), radius=16, fill=(254, 242, 242), outline=(248, 113, 113), width=2)
    draw.text((40, 85), "Zorunlu Teslimat Kanıtı (PoD)", fill=(185, 28, 28), font=get_font(22, bold=True))
    draw.text((40, 118), "Fotoğraf ve Alıcı İmzası olmadan sipariş teslim edilemez.", fill=(153, 27, 27), font=get_font(16))

    # 1. Fotoğraf Çekim Alanı
    draw.rounded_rectangle((20, 175, w - 20, 560), radius=18, fill=(255, 255, 255), outline=(203, 213, 225), width=2)
    draw.text((44, 200), "1. Adım: Teslimat / Paket Fotoğrafı", fill=(15, 23, 42), font=get_font(22, bold=True))

    # Fotoğraf Kutusu Simülasyonu
    draw.rounded_rectangle((40, 240, w - 40, 535), radius=14, fill=(241, 245, 249), outline=(148, 163, 184))
    draw.text((w // 2, 350), "📷", font=get_font(54), anchor="mm")
    draw.text((w // 2, 420), "Fotoğraf Çekildi • Doğrulandı ✓", fill=(22, 163, 74), font=get_font(20, bold=True), anchor="mm")
    draw.text((w // 2, 455), "GPS: 41.0082° K, 28.9784° D • 14:32:10", fill=(100, 116, 139), font=get_font(15), anchor="mm")

    # 2. Dijital İmza Alanı
    draw.rounded_rectangle((20, 580, w - 20, 965), radius=18, fill=(255, 255, 255), outline=(203, 213, 225), width=2)
    draw.text((44, 605), "2. Adım: Alıcı Dijital İmzası", fill=(15, 23, 42), font=get_font(22, bold=True))

    draw.rounded_rectangle((40, 645, w - 40, 940), radius=14, fill=(254, 252, 232), outline=(250, 204, 21))
    # Sahte İmza Çizgisi
    sig_points = [(100, 780), (160, 720), (220, 840), (280, 710), (360, 820), (460, 750), (560, 790), (680, 740)]
    draw.line(sig_points, fill=(30, 58, 138), width=5, joint="curve")
    draw.text((w // 2, 890), "Alıcı: Ayşe Yılmaz (Bizzat Teslim Alındı)", fill=(71, 85, 105), font=get_font(18, bold=True), anchor="mm")

    # Slide to Deliver (Kaydırarak Teslim Et) Butonu
    draw.rounded_rectangle((20, 990, w - 20, 1070), radius=40, fill=(22, 163, 74))
    draw.ellipse((28, 998, 96, 1062), fill=(255, 255, 255))
    draw.text((62, 1030), "➔", fill=(22, 163, 74), font=get_font(28, bold=True), anchor="mm")
    draw.text((w // 2 + 30, 1030), "KAYDIRARAK TESLİM ET ⚡", fill=(255, 255, 255), font=get_font(22, bold=True), anchor="mm")


# --- Mock 4: WhatsApp Müşteri Takip Linki ---
def build_screen_4(img: Image.Image, draw: ImageDraw.ImageDraw, w: int, h: int, color):
    # WhatsApp Mesajlaşma Arayüzü Simülasyonu
    draw.rectangle((0, 0, w, 110), fill=(7, 94, 84))
    draw.text((40, 60), "💬 WhatsApp — Kargo Takip Bildirimi", fill=(255, 255, 255), font=get_font(24, bold=True))

    # Gelen Mesaj Balonu
    draw.rounded_rectangle((30, 150, w - 80, 480), radius=18, fill=(220, 248, 198), outline=(187, 247, 208))
    msg_text = (
        "Merhaba Canan Hanım,\n\n"
        "*Kuzey Lojistik* siparişiniz (#2089) kuryemiz tarafından teslimata çıkarılmıştır!\n\n"
        "Canlı kurye konumunu harita üzerinden anlık izlemek için linke tıklayın:\n"
        "👉 https://kargo-takip-pod.onrender.com/#/track/live_tk_98124\n\n"
        "İyi günler dileriz! 🚀"
    )
    draw.text((60, 175), msg_text, fill=(15, 23, 42), font=get_font(19))

    # Web Canlı Takip Önizleme Kartı (Uygulama İndirmeden Açılan Harita)
    draw.rounded_rectangle((30, 520, w - 30, h - 30), radius=22, fill=(255, 255, 255), outline=(203, 213, 225), width=2)
    draw.text((54, 555), "Müşteri Web Canlı Takip Ekranı", fill=(15, 23, 42), font=get_font(26, bold=True))
    draw.text((54, 595), "Uygulama indirmeden tüm telefonlarda çalışır (iOS & Android).", fill=(100, 116, 139), font=get_font(17))

    # Mini Harita & Tahmini Varış
    draw.rounded_rectangle((50, 640, w - 50, 880), radius=16, fill=(224, 231, 255))
    draw.ellipse((220, 750, 270, 800), fill=(37, 99, 235))
    draw.text((245, 775), "🛵", font=get_font(22), anchor="mm")
    draw.line([(245, 775), (580, 740)], fill=(37, 99, 235), width=6)
    draw.ellipse((560, 720, 600, 760), fill=(220, 38, 38))

    draw.rounded_rectangle((50, 910, w - 50, 990), radius=14, fill=(240, 253, 244), outline=(134, 239, 172))
    draw.text((w // 2, 950), "🟢 Kurye Yaklaştı: Kalan Mesafe 850m (~3 Dk)", fill=(21, 128, 61), font=get_font(20, bold=True), anchor="mm")


# --- Mock 5: Otomatik Fotoğraflı & İmzalı Excel Raporu ---
def build_screen_5(img: Image.Image, draw: ImageDraw.ImageDraw, w: int, h: int, color):
    # E-Posta Başlığı
    draw.rounded_rectangle((20, 60, w - 20, 210), radius=18, fill=(30, 64, 175))
    draw.text((44, 95), "📬 Otomatik PoD Excel Raporu", fill=(255, 255, 255), font=get_font(26, bold=True))
    draw.text((44, 135), "Kime: yonetim@sirketiniz.com", fill=(191, 219, 254), font=get_font(18))
    draw.text((44, 168), "Ek: PoD_Arsiv_Kuzey_Lojistik_20261115.xlsx (Fotoğraflar Gömülü)", fill=(254, 240, 138), font=get_font(17, bold=True))

    # Excel Tablo Simülasyonu
    draw.rounded_rectangle((20, 235, w - 20, h - 30), radius=18, fill=(255, 255, 255), outline=(203, 213, 225), width=2)

    # Başlık Satırı (Koyu Mavi Excel Başlığı)
    draw.rectangle((20, 235, w - 20, 310), fill=(30, 41, 59))
    draw.text((44, 272), "Sipariş No", fill=(255, 255, 255), font=get_font(17, bold=True), anchor="lm")
    draw.text((220, 272), "Müşteri & Adres", fill=(255, 255, 255), font=get_font(17, bold=True), anchor="lm")
    draw.text((500, 272), "Teslimat Fotoğrafı", fill=(255, 255, 255), font=get_font(17, bold=True), anchor="lm")
    draw.text((700, 272), "Alıcı İmzası", fill=(255, 255, 255), font=get_font(17, bold=True), anchor="lm")

    # Tablo Satırları (Hücre İçi Fotoğraf ve İmza)
    rows = [
        ("#1042", "Zeynep K.\nKadıköy", "📷 Paket Görseli", "✍️ Islak İmza"),
        ("#1043", "Ahmet T.\nBeşiktaş", "📷 Paket Görseli", "✍️ Islak İmza"),
        ("#1044", "Selin M.\nÜsküdar", "📷 Paket Görseli", "✍️ Islak İmza"),
    ]

    ry = 320
    for r_no, r_cust, r_photo, r_sig in rows:
        draw.line([(20, ry + 160), (w - 20, ry + 160)], fill=(226, 232, 240), width=1)
        draw.text((44, ry + 70), r_no, fill=(37, 99, 235), font=get_font(20, bold=True), anchor="lm")
        draw.text((220, ry + 60), r_cust, fill=(51, 65, 85), font=get_font(17), anchor="lm")

        # Hücreye gömülü fotoğraf simülasyonu
        draw.rounded_rectangle((500, ry + 20, 660, ry + 140), radius=10, fill=(241, 245, 249), outline=(148, 163, 184))
        draw.text((580, ry + 80), r_photo, fill=(71, 85, 105), font=get_font(14, bold=True), anchor="mm")

        # Hücreye gömülü imza simülasyonu
        draw.rounded_rectangle((700, ry + 20, 840, ry + 140), radius=10, fill=(254, 252, 232), outline=(250, 204, 21))
        draw.text((770, ry + 80), r_sig, fill=(180, 83, 9), font=get_font(14, bold=True), anchor="mm")
        ry += 170


def export_screenshots(master_logo: Image.Image) -> None:
    print("[2/3] AppGallery Mağaza Ekran Görüntüleri Üretiliyor (1080x1920 px)...")

    items = [
        (
            "01_canli_harita_ve_24_saat_arsiv.png",
            "CANLI HARİTA & 24 SAAT ARŞİV",
            "Canlı Kurye Takibi ve 24 Saat Görünürlük",
            "Anlık hareket eden araç pini, OSRM rota çizgisi ve kalan süre sayacı",
            (37, 99, 235),
            build_screen_1,
        ),
        (
            "02_surucu_filo_ve_akilli_rota.png",
            "FİLO YÖNETİMİ & AKILLI ROTA",
            "Boşta & Meşgul Kurye Haritası",
            "Müsait sürücülere tek tıkla görev atama ve En Yakın Komşu sıralama",
            (16, 185, 129),
            build_screen_2,
        ),
        (
            "03_zorunlu_fotograf_ve_imza.png",
            "ZORUNLU KANIT (PoD)",
            "Fotoğraf ve İmzasız Kapanmayan Teslimat",
            "Teslim anında paket fotoğrafı ve alıcı imzası zorunluluğu ile sıfır kayıp",
            (220, 38, 38),
            build_screen_3,
        ),
        (
            "04_whatsapp_musteri_takip.png",
            "UYGULAMA İNDİRMEDEN TAKİP",
            "WhatsApp Canlı Müşteri Takip Linki",
            "Müşteriye tek tıkla giden bağlantı ile haritada canlı izleme keyfi",
            (37, 211, 102),
            build_screen_4,
        ),
        (
            "05_otomatik_fotografli_excel.png",
            "FOTOĞRAFLI EXCEL RAPORU",
            "Otomatik Fotoğraflı & İmzalı Excel Arşivi",
            "Tamamlanan her siparişin görseli Excel hücresine gömülüp e-postalanır",
            (14, 165, 233),
            build_screen_5,
        ),
    ]

    for fname, badge, title, subtitle, color, fn in items:
        img = draw_device_mockup(master_logo, badge, title, subtitle, color, fn)
        img.save(SCREENSHOTS_DIR / fname, "PNG", optimize=True)
        print(f"  -> {fname} oluşturuldu.")


# ---------------------------------------------------------------------------
# 3. APPGALLERY TANITIM AFİŞİ (1080x540 px Yatay)
# ---------------------------------------------------------------------------
def export_promo_banner(master_logo: Image.Image) -> None:
    print("[3/3] AppGallery Tanıtım Afişi Üretiliyor (1080x540 px)...")
    w, h = 1080, 540
    banner = Image.new("RGBA", (w, h), (15, 23, 42, 255))
    draw = ImageDraw.Draw(banner)

    # Zengin Gradyan
    draw_gradient_background(draw, w, h, (11, 19, 43), (30, 58, 138))

    # Dekoratif Radar Işıkları
    draw.arc((w - 200, -200, w + 400, 400), start=0, end=360, fill=(6, 182, 212, 35), width=3)
    draw.arc((w - 100, -100, w + 300, 300), start=0, end=360, fill=(37, 99, 235, 45), width=2)

    # Sol Tarafta Logo
    logo_size = 280
    scaled_logo = master_logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
    banner.paste(scaled_logo, (60, (h - logo_size) // 2), scaled_logo)

    # Sağ Tarafta Başlık ve Maddeler
    tx = 380
    draw.text((tx, 110), "Kargo Takip & PoD", fill=(255, 255, 255), font=get_font(46, heavy=True))
    draw.text((tx, 175), "Çoklu İşletme Canlı Kurye & Teslimat Yönetimi", fill=(147, 197, 253), font=get_font(24, bold=True))

    bullets = [
        "✓ Canlı Kurye GPS Takibi ve 24 Saat Harita Görünürlüğü",
        "✓ Fotoğraf ve Alıcı İmzası Gömülü Otomatik Excel Raporu",
        "✓ WhatsApp Müşteri Takip Linki & Akıllı Çoklu Durak Sıralama",
        "✓ Huawei AppGallery & GMS-Free Cihazlarla %100 Uyumlu",
    ]
    by = 230
    for b in bullets:
        draw.text((tx, by), b, fill=(226, 232, 240), font=get_font(18))
        by += 38

    # Sağ Altta %100 Ücretsiz Rozeti
    draw.rounded_rectangle((tx, 400, tx + 240, 455), radius=14, fill=(16, 185, 129), outline=(255, 255, 255))
    draw.text((tx + 120, 427), "ÜCRETSİZ & AÇIK KAYNAK", fill=(255, 255, 255), font=get_font(15, bold=True), anchor="mm")

    banner.save(LOGOS_DIR / "tanitim_afisi_1080x540.png", "PNG", optimize=True)
    print("  -> tanitim_afisi_1080x540.png oluşturuldu.")


def main():
    print("=== HUAWEI APPGALLERY GÖRSEL MATERYAL ÜRETİCİ BAŞLATILDI ===")
    master = create_master_logo(1024)
    export_app_icons(master)
    export_screenshots(master)
    export_promo_banner(master)
    print("=== TÜM GÖRSELLER BAŞARIYLA TAMAMLANDI ===")


if __name__ == "__main__":
    main()
