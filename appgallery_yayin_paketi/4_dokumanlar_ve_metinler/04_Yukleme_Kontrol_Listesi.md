# Huawei AppGallery Connect - Yükleme ve Yayın Kontrol Listesi (Checklist)

Bu kontrol listesi, `appgallery_yayin_paketi/` klasöründeki tüm varlıkları Huawei AppGallery Connect konsoluna **sıfır ret riskiyle** yüklemeniz için hazırlanmıştır.

---

## 📋 Hızlı Kontrol Listesi

- [ ] **1. Temel Uygulama Bilgileri:**
  - **Uygulama Adı:** `Kargo Takip PoD` *(Harfi harfine AndroidManifest.xml ile aynı)*
  - **Kategori:** `İş / Üretkenlik / Lojistik`
  - **Varsayılan Dil:** `Türkçe (tr-TR)`
  - **Desteklenen Cihazlar:** `Telefon` ve `Tablet`

- [ ] **2. Mağaza Görselleri:**
  - **Uygulama İkonu (512x512 px):** `appgallery_yayin_paketi/2_logolar_ve_afisler/app_icon_512x512.png`
  - **Tanıtım Afişi (1080x540 px):** `appgallery_yayin_paketi/2_logolar_ve_afisler/tanitim_afisi_1080x540.png`
  - **Ekran Görüntüleri (1080x1920 px):** `appgallery_yayin_paketi/3_ekran_goruntuleri/` içindeki 5 ekran görüntüsü:
    1. `01_canli_harita.png` (Canlı Harita & 24 Saat Arşiv)
    2. `02_suruculer_filo_haritasi.png` (Sürücüler Sekmesi & Toplu Canlı Filo Haritası)
    3. `03_fotograf_ve_imza_pod.png` (Zorunlu Fotoğraf ve İmza ile Teslimat Kanıtı)
    4. `04_whatsapp_canli_takip.png` (WhatsApp Müşteri Canlı Takip Arayüzü)
    5. `05_excel_eposta_arsiv.png` (Otomatik Fotoğraflı & İmzalı Excel Raporu)

- [ ] **3. Mağaza Metinleri ve Açıklamalar:**
  - `01_Magaza_Metinleri_TR_EN.txt` dosyasından:
    - **Kısa Açıklama (Maks. 80 Karakter):** `Canlı kurye takibi, fotoğraflı ve imzalı teslimat kanıtı (PoD) sistemi.`
    - **Ayrıntılı Tanıtım:** Dosyadaki Türkçe ve İngilizce blokları yapıştırın.
    - **Sürüm Notları (v1.0.0):** Dosyadaki sürüm notunu yapıştırın.
    - **Anahtar Kelimeler:** `kargo takip pod, kurye, teslimat, pod, proof of delivery, canlı takip, lojistik, filo yönetimi`

- [ ] **4. Canlı Gizlilik Politikası (Privacy Policy):**
  - **Gizlilik Politikası URL'si:** `https://kargo-takip-pod.onrender.com/privacy`
  - *(Geliştirici: Olkan Bayat, İletişim: destek@kargotakip.com)*

- [ ] **5. İmzalı Yazılım Paketi:**
  - **Tavsiye Edilen (AAB):** `appgallery_yayin_paketi/1_kurulum_paketleri/app-release.aab`
  - **Alternatif (APK):** `appgallery_yayin_paketi/1_kurulum_paketleri/Kargo_Takip_PoD_v1.0.0_release.apk`
  - **Sertifika SHA-256 Parmak İzi:**
    ```text
    03:CF:BF:E1:25:C1:67:2D:FA:30:E7:D6:6D:3C:7C:8F:51:F3:E5:A5:DD:20:C5:73:E9:72:97:FE:97:85:42:41
    ```

- [ ] **6. Hassas İzin Gerekçeleri (Permission Rationales):**
  - `02_Hassas_Izin_Aciklamalari.txt` dosyasındaki Konum, Kamera ve Pil kısıtlaması istisnası gerekçelerini ilgili alanlara yapıştırın.

- [ ] **7. İnceleme Ekibi Demo Hesapları (Notes for Reviewer):**
  - `03_Inceleme_Ekibi_Demo_Hesaplari.txt` dosyasındaki bilgileri doğrudan İnceleme Notu kutusuna yapıştırın:
    - **Yönetici:** `appgallery_admin@kargotakip.com` / `HuaweiTest2026!`
    - **Kurye:** `appgallery_driver@kargotakip.com` / `HuaweiTest2026!`
    - *(Bu iki test hesabı backend veritabanında silinmez olarak hazır tutulmaktadır).*

---

Yukarıdaki tüm maddeler tamamlandığında sağ üstteki yeşil **"İncelemeye Gönder" (Submit for Review)** butonuna basabilirsiniz.
