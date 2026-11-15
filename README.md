# 🚚 Kargo Takip & Teslimat Kanıtı (PoD) Sistemi

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/onryodragon/kargo-takip-pod)
[![Flutter](https://img.shields.io/badge/Flutter-3.47.4-02569B?logo=flutter)](https://flutter.dev)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.115+-009688?logo=fastapi)](https://fastapi.tiangolo.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **Kendi Ücretsiz Sunucunu 1 Dakikada Kur (BYOS — Bring Your Own Server):**
> Bu platform; kargo, lojistik, kurye ve teslimat işletmelerinin **kendi ücretsiz Render bulut sunucusunu tek tıkla kurarak** tüm müşteri, kurye, canlı konum, teslimat kanıtı fotoğrafı ve dijital imza verilerini **kendi bağımsız sunucusunda** saklamasını ve yönetmesini sağlar.

---

## ⚡ 1-Tıkla Ücretsiz Sunucunu Oluştur (1 Dakikada Canlı)

Yukarıdaki **"Deploy to Render"** butonuna basarak veya aşağıdaki adımları izleyerek tamamen ücretsiz sunucunuzu açabilirsiniz:

1. [Render.com](https://render.com)'da ücretsiz bir hesap oluşturun veya giriş yapın.
2. [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/onryodragon/kargo-takip-pod) butonuna tıklayın.
3. Render ekranında **"Apply"** veya **"Deploy Blueprint"** butonuna basın. Veritabanı, Python FastAPI backend'i ve derlenmiş Web arayüzü 1 dakika içinde otomatik olarak canlıya geçer.
4. Render panelinizdeki web servisinizin adresini kopyalayın (Örn: `https://sirketiniz.onrender.com`).
5. **Kargo Takip** mobil veya web uygulamasını açıp Giriş ekranındaki **"İşletme Sunucu Adresi"** kutusuna bu adresi yapıştırıp **"Doğrula ve Bağlan"** butonuna basın. Tebrikler! Tüm altyapı artık tamamen sizin sunucunuza kilitlendi!

---

## 🌟 Öne Çıkan Özellikler

### 1. 🏢 Çoklu İşletme ve Bağımsız Çalışma (Multi-Tenant & BYOS)
- Her işletme ister ortak demo sunucusunu kullanabilir, ister tek tıkla kendi bağımsız ücretsiz sunucusunu bağlayabilir.
- **Sıfır Manuel Kurye Ayarı:** İşletme kuryeye WhatsApp davetiye linki gönderdiğinde (`.../#/driver-invite/TOKEN?api=https://sirketiniz.onrender.com`), kurye uygulaması işletmenin sunucusunu otomatik olarak tanır; kuryenin hiçbir sunucu adresi yazmasına gerek kalmaz.
- **Müşteri Canlı Takip:** WhatsApp üzerinden müşteriye giden canlı takip linkleri doğrudan işletmenizin sunucusunu kullanır.

### 2. 🗺️ Canlı Kurye Haritası & Akıllı Navigasyon
- **Radar Araç Pini:** Müşteri takip ekranında kuryenin anlık konumu, araç tipi, plakası ve etrafında dönen radar dalgasıyla canlı görünür.
- **OSRM Canlı Yol Çizgisi:** Kurye ile teslimat noktası arasındaki en kısa sürüş rotası ve kalan km/dakika bilgisi haritada gerçek zamanlı akar.
- **Saniyelik Polling:** Mobil tarayıcılarda WebSocket bağlantısı kopsa bile 2 saniyelik kesintisiz sorgulama motoruyla araç haritada pürüzsüzce kayar.
- **Tek Tıkla Sesli Navigasyon:** Kurye **"Durağı Kabul Et ve Navigasyonu Başlat 🧭"** butonuna bastığı an hem sipariş durumu `in_transit` (Yolda) olur, hem kurye konumu haritada belirir, hem de cihazdaki Google Maps sesli sürüş modunda otomatik başlar.

### 3. 📸 Dijital Teslimat Kanıtı (PoD) & Fotoğraflı Excel Arşivi
- Teslimat anında kamera ile paket fotoğrafı çekilir ve ekrandan ıslak imza alınır.
- Teslimat tamamlandığında, çekilen fotoğraf ve imza doğrudan Excel hücresine gömülerek **İşletmenin kendi e-posta adresine** (`tenant.report_email`) otomatik rapor olarak gönderilir.

### 4. 🔒 Güvenlik, Dinamik E-Posta & KVKK Uyumluluğu
- **Sıfır Kod Sızıntısı:** Şifre sıfırlama kodları asla API yanıtında veya arayüzde gösterilmez; doğrudan kullanıcının kendi e-postasına şık HTML formatında iletilir.
- **Çoklu Port ve HTTP E-Posta:** Render ücretsiz sunucularda port 587/465 zaman aşımına karşı hem SSL, STARTTLS, Port 2525 hem de isteğe bağlı HTTPS Webhook / API desteği sunulur.
- **KVKK Veri Sorumlusu Güvencesi:** 6698 sayılı Kişisel Verilerin Korunması Kanunu uyarınca sisteme kaydedilen kurye, müşteri ve konum verilerinin veri sorumluluğu kayıt olan işletmeye aittir.

---

## 🏗️ Mimari & Teknoloji Yığını

```
┌────────────────────────────────────────────────────────────────────────┐
│                   Flutter Çoklu Platform İstemcisi                     │
│    (Android Release APK, iOS, Web SPA Glassmorphism Arayüzü)           │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │ HTTPS REST & WSS WebSockets
┌────────────────────────────────────▼───────────────────────────────────┐
│                     FastAPI Python 3.12 Backend                        │
│    - Multi-Tenant İzolasyonu & JWT Token Doğrulama                     │
│    - Real-Time WebSocket Odaları & Konum Yayını                        │
│    - Multi-Port SMTP (465/587/2525) & HTTP E-Posta Motoru               │
│    - Otomatik Veritabanı ve Şema Kurulumu (Zero-Config)                 │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           │                                                   │
┌──────────▼───────────────┐                       ┌───────────▼──────────────┐
│  Yerel SQLite Veritabanı │                       │   Supabase Bulut (Ops)   │
│   (kargo_takip.db)       │                       │  PostgreSQL & Storage    │
└──────────────────────────┘                       └──────────────────────────┘
```

---

## ⚙️ Ortam Değişkenleri (`render.yaml` & `.env`)

| Değişken Adı | Açıklama | Varsayılan Değer |
|---|---|---|
| `PUBLIC_BASE_URL` | Sunucunun genel web adresi | Otomatik (`RENDER_EXTERNAL_URL`) |
| `JWT_SECRET_KEY` | JWT token şifreleme anahtarı | Otomatik üretilir |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | Oturum süresi | `10080` (7 gün) |
| `SMTP_HOST` | E-posta gönderici SMTP sunucusu | `smtp.gmail.com` |
| `SMTP_PORT` | SMTP portu | `587` |
| `SMTP_USE_TLS` | STARTTLS şifreleme | `true` |
| `SMTP_FALLBACK_PORTS` | SMTP yedek deneme portları | `465,587,2525` |
| `EMAIL_DELIVERY_ORDER` | Gönderim deneme sırası | `smtp,http` |

---

## 📱 İstemciyi Kurma ve Çalıştırma

### Android Release APK İndirme
- Derlenmiş son sürüm APK dosyası doğrudan depoda yer almaktadır:
  `kargo-takip-pod-release.apk`
- Telefonunuza indirip kurarak hemen kullanmaya başlayabilirsiniz.

### Web Sürümü
- Backend sunucunuzu açtığınızda web arayüzü doğrudan ana sayfada (`/`) çalışır.

---

## ⚖️ Lisans ve Hukuki Sorumluluk
Bu yazılım MIT lisansı ile ücretsiz olarak sunulmaktadır. Yazılım altyapısı "olduğu gibi" (as-is) sağlanmakta olup; sunucu kesintilerinden, kurye/müşteri konum verilerinden ve kişisel verilerin korunmasından (KVKK) sistemi işleten ilgili işletme münhasıran sorumludur.
