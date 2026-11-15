# Huawei AppGallery Connect - Adım Adım Mağaza Yükleme ve Yayın Kılavuzu

Bu rehber, projenizin kök dizinindeki `appgallery_yayin_paketi/` klasöründe yer alan tüm materyalleri Huawei AppGallery Connect geliştirici konsoluna **sıfır hatayla ve ilk seferde onay alacak şekilde** yüklemeniz için adım adım hazırlanmıştır.

---

## 📁 Yayın Paketi Klasör Yapısı Özeti

```text
appgallery_yayin_paketi/
├── 1_kurulum_paketleri/
│   ├── kargo-takip-pod-release.apk     (Resmi keystore ile imzalanmış evrensel APK)
│   ├── app-release.aab                 (Resmi keystore ile imzalanmış Android App Bundle)
│   ├── release-keystore.jks            (Yayın anahtarı - Güvenli yerde saklayın!)
│   └── SHA256_Parmak_Izi.txt           (SHA-256, SHA-1 ve MD5 sertifika parmak izleri)
├── 2_logolar_ve_afisler/
│   ├── app_icon_512x512.png            (AppGallery ana mağaza simgesi)
│   ├── app_icon_216x216.png            (Alternatif kare ikon)
│   └── tanitim_afisi_1080x540.png      (Mağaza öne çıkan tanıtım afişi - Banner)
├── 3_ekran_goruntuleri/
│   ├── 01_canli_harita_ve_24_saat_arsiv.png   (Dikey ekran görüntüsü 1 - Canlı Harita)
│   ├── 02_surucu_filo_ve_akilli_rota.png      (Dikey ekran görüntüsü 2 - Sürücüler & Rota)
│   ├── 03_zorunlu_fotograf_ve_imza.png        (Dikey ekran görüntüsü 3 - Fotoğraf & İmza)
│   ├── 04_whatsapp_musteri_takip.png          (Dikey ekran görüntüsü 4 - Müşteri Takip)
│   └── 05_otomatik_fotografli_excel.png       (Dikey ekran görüntüsü 5 - Excel Arşiv)
└── 4_dokumanlar_ve_metinler/
    ├── 01_Magaza_Bilgileri_ve_Aciklamalar.txt (Başlık, açıklamalar, anahtar kelimeler)
    ├── 02_Hassas_Izin_Aciklamalari.txt         (Kamera, Konum ve Pil izin beyanları)
    ├── 03_Huawei_Inceleme_Ekibi_Notu.txt       (İncelemeci hazır test hesapları ve rehber)
    └── 04_Adim_Adim_AppGallery_Yukleme_Listesi.md (Bu doküman)
```

---

## 🚀 ADIM 1: AppGallery Connect Konsoluna Giriş ve Yeni Uygulama Oluşturma

1. Tarayıcınızda [Huawei AppGallery Connect Konsolu](https://developer.huawei.com/consumer/en/service/josp/agc/index.html) adresini açın ve Huawei Geliştirici hesabınızla oturum açın.
2. Ana menüden **"Uygulamalarım" (My Apps)** sekmesine tıklayın.
3. Sağ üstteki mavi **"Yeni Uygulama" (+ New App)** butonuna basın.
4. Açılan pencerede şu bilgileri seçin:
   - **Paket Türü (Package Type):** `APK veya App Bundle (AAB)`
   - **Cihaz (Device):** `Telefon` ve `Tablet` işaretleyin.
   - **Uygulama Adı:** `Kargo Takip & Canlı Kurye POD`
   - **Kategori:** `Uygulama (App)`
   - **Varsayılan Dil:** `Türkçe (tr-TR)`
5. **Tamam (OK)** butonuna tıklayarak taslak kaydı oluşturun.

---

## 🎨 ADIM 2: Görsellerin ve Mağaza Tanıtım Sayfasının Yüklenmesi

Oluşturduğunuz uygulamanın **"Uygulama Bilgileri" (App Information)** menüsüne girin:

### 1. Uygulama Simgesi (App Icon)
- **Dosya Seç:** `appgallery_yayin_paketi/2_logolar_ve_afisler/app_icon_512x512.png` dosyasını yükleyin.

### 2. Tanıtım Afişi (Promo Banner)
- **Dosya Seç:** `appgallery_yayin_paketi/2_logolar_ve_afisler/tanitim_afisi_1080x540.png` dosyasını yükleyin (1080x540 px, zorunlu veya önerilen afiş alanına).

### 3. Ekran Görüntüleri (Device Screenshots)
- Telefon (Phone) sekmesi altında `appgallery_yayin_paketi/3_ekran_goruntuleri/` klasöründeki 5 dikey görseli sırasıyla yükleyin:
  1. `01_canli_harita_ve_24_saat_arsiv.png`
  2. `02_surucu_filo_ve_akilli_rota.png`
  3. `03_zorunlu_fotograf_ve_imza.png`
  4. `04_whatsapp_musteri_takip.png`
  5. `05_otomatik_fotografli_excel.png`

---

## 📝 ADIM 3: Metinlerin, Açıklamaların ve Gizlilik URL'sinin Girilmesi

`appgallery_yayin_paketi/4_dokumanlar_ve_metinler/01_Magaza_Bilgileri_ve_Aciklamalar.txt` dosyasını açıp ilgili alanları kopyalayıp yapıştırın:

1. **Kısa Açıklama (Brief Introduction):**
   > `Canlı kurye takibi, fotoğraflı ve imzalı teslimat kanıtı (PoD) sistemi.`
2. **Ayrıntılı Tanıtım (Description):**
   `01_Magaza_Bilgileri_ve_Aciklamalar.txt` dosyasındaki Türkçe açıklama bloğunu yapıştırın.
3. **Yeni Sürüm Özellikleri (New Features / Release Notes):**
   `01_Magaza_Bilgileri_ve_Aciklamalar.txt` içerisindeki v1.0.0 sürüm notlarını yapıştırın.
4. **Kategori Seçimi:** `İş / Üretkenlik (Business & Productivity)` veya `Navigasyon / Ulaşım`.
5. **Gizlilik Politikası URL'si (Privacy Policy URL) [ÇOK ÖNEMLİ]:**
   > `https://kargo-takip-pod.onrender.com/privacy`
6. **Destek E-Postası (Customer Service Email):**
   > `destek@kargotakip.com` veya `onryodragon@users.noreply.github.com`
7. Sağ üstteki **"Kaydet" (Save)** butonuna basın.

---

## 📦 ADIM 4: İmzalı Kurulum Paketinin Yüklenmesi (AAB veya APK)

Sol menüden **"Sürüm Yönetimi" (Version Management) > "Sürüm Hazırla" (Draft Version)** sayfasına geçin:

1. **Yazılım Paketi Yükle (Software Packages):**
   - **Tavsiye Edilen (App Bundle):** `appgallery_yayin_paketi/1_kurulum_paketleri/app-release.aab` dosyasını sürükleyip bırakın.
   - Alternatif (APK): `appgallery_yayin_paketi/1_kurulum_paketleri/kargo-takip-pod-release.apk` dosyasını yükleyebilirsiniz.
2. Paket yüklendikten sonra sistem sürüm numarasını (`v1.0.0+1`) ve paket adını (`com.kargotakip.pod`) otomatik doğrulayacaktır.

---

## 🔑 ADIM 5: SHA-256 Sertifika Parmak İzi Tanımlama

Huawei AppGallery API ve servislerinin paketinizi tanıması için sertifika parmak izini ekleyin:
1. Konsolda **Proje Ayarları (Project Settings)** veya **Uygulama Bilgileri (App Information)** altındaki **SHA-256 Sertifika Parmak İzi** kutucuğuna gidin.
2. `appgallery_yayin_paketi/1_kurulum_paketleri/SHA256_Parmak_Izi.txt` dosyasındaki şu değeri kopyalayıp kaydedin:
   ```text
   03:CF:BF:E1:25:C1:67:2D:FA:30:E7:D6:6D:3C:7C:8F:51:F3:E5:A5:DD:20:C5:73:E9:72:97:FE:97:85:42:41
   ```

---

## 🛡️ ADIM 6: Hassas İzin Beyanları ve İnceleme Ekibi Test Hesapları

Reddedilmeyi önlemenin en kritik adımıdır. Sürüm onay sayfasında yer alan açıklama kutularını doldurun:

### 1. Hassas İzinler (Sensitive Permissions Rationale)
- Panelde konum ve kamera izni gerekçesi sorulduğunda:
  `appgallery_yayin_paketi/4_dokumanlar_ve_metinler/02_Hassas_Izin_Aciklamalari.txt` dosyasındaki Türkçe ve İngilizce gerekçe metinlerini yapıştırın.

### 2. İnceleme Ekibi İçin Giriş Bilgileri (Review Notes & Test Credentials)
- **"Giriş Bilgileri Gerekli mi?"** sorusunu `Evet` olarak işaretleyin.
- `appgallery_yayin_paketi/4_dokumanlar_ve_metinler/03_Huawei_Inceleme_Ekibi_Notu.txt` dosyasındaki tüm içeriği bu alana yapıştırın.
  - **Yönetici E-Postası:** `appgallery_admin@kargotakip.com`
  - **Yönetici Şifresi:** `HuaweiTest2026!`
  - **Kurye E-Postası:** `appgallery_driver@kargotakip.com`
  - **Kurye Şifresi:** `HuaweiTest2026!`

---

## ✅ ADIM 7: İncelemeye Gönder (Submit for Review)

1. Sayfanın en altındaki **"Telif Hakkı ve KVKK Uyumluluğu"** onay kutularını işaretleyin.
2. Sağ üstteki yeşil **"İncelemeye Gönder" (Submit for Review)** butonuna tıklayın.
3. Uygulamanız Huawei AppGallery test laboratuvarları tarafından incelenmeye alınacaktır. Hazırladığımız hazır hesaplar ve canlı gizlilik politikası sayesinde inceleme genellikle 24-48 saat içinde başarıyla onaylanarak mağazada yayına girer!
