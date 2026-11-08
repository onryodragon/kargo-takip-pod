import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Müşteriye canlı takip linki, kuryeye kayıt davetiyesi ve kullanıcıya
/// WhatsApp bağlama doğrulaması göndermek için telefon numarası normalize edici
/// ve derin bağlantı (Deep-Link) yardımcısı.
class WhatsAppHelper {
  const WhatsAppHelper._();

  /// Canlı Render Web Takip Adresi
  static const String baseWebUrl = 'https://kargo-takip-pod.onrender.com';

  /// Telefon numarasını temizler ve Türkiye uluslararası formatına (`905xxxxxxxxx`) dönüştürür.
  static String normalizeTurkishPhone(String rawPhone) {
    String digits = rawPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';

    if (digits.startsWith('00')) {
      digits = digits.substring(2);
    }

    if (digits.length == 11 && digits.startsWith('0')) {
      return '90${digits.substring(1)}';
    }

    if (digits.length == 10 && digits.startsWith('5')) {
      return '90$digits';
    }

    return digits;
  }

  /// White-Label müşteri takip mesaj şablonunu oluşturur.
  static String buildWhiteLabelTrackingMessage({
    required String customerName,
    required String tenantName,
    required String orderNumber,
    String baseUrl = baseWebUrl,
    required String trackingToken,
  }) {
    final cleanBase = (baseUrl.trim().isEmpty ? baseWebUrl : baseUrl.trim())
        .replaceAll(RegExp(r'/+$'), '');
    final cleanOrderNo = orderNumber.trim().replaceFirst(RegExp(r'^#+'), '');
    final trackingUrl = '$cleanBase/#/track/${trackingToken.trim()}';

    return 'Merhaba ${customerName.trim()}, '
        '*${tenantName.trim()}* siparişiniz (#$cleanOrderNo) yola çıktı! '
        'Siparişinizi haritadan canlı olarak buradan izleyebilirsiniz: $trackingUrl';
  }

  /// Mobilde önce `whatsapp://send?phone=...&text=...` şemasını dener;
  /// Web'de veya cihazda WhatsApp yüklü değilse `https://wa.me/...` adresine yönlendirir.
  static Future<bool> launchWhatsAppMessage({
    required String rawPhone,
    required String message,
  }) async {
    final normalizedPhone = normalizeTurkishPhone(rawPhone);
    final encodedMessage = Uri.encodeComponent(message);

    if (!kIsWeb) {
      final nativeUri = Uri.parse(
        'whatsapp://send?phone=$normalizedPhone&text=$encodedMessage',
      );
      try {
        if (await canLaunchUrl(nativeUri)) {
          final launched = await launchUrl(
            nativeUri,
            mode: LaunchMode.externalApplication,
          );
          if (launched) return true;
        }
      } catch (_) {}
    }

    final waMeUri = Uri.parse(
      'https://wa.me/$normalizedPhone?text=$encodedMessage',
    );
    return launchUrl(
      waMeUri,
      mode: LaunchMode.externalApplication,
    );
  }

  static Future<bool> sendLiveTrackingViaWhatsApp({
    required String customerPhone,
    required String customerName,
    required String tenantName,
    required String orderNumber,
    String baseUrl = baseWebUrl,
    required String trackingToken,
  }) async {
    final message = buildWhiteLabelTrackingMessage(
      customerName: customerName,
      tenantName: tenantName,
      orderNumber: orderNumber,
      baseUrl: baseUrl,
      trackingToken: trackingToken,
    );
    return launchWhatsAppMessage(rawPhone: customerPhone, message: message);
  }

  /// GÖREV #2: Yönetici tarafından kuryenin telefon numarasına WhatsApp davet linki gönderir.
  static Future<bool> sendDriverInviteViaWhatsApp({
    required String driverPhone,
    required String tenantName,
    required String inviteUrl,
  }) async {
    final msg = 'Merhaba! *${tenantName.trim()}* saha kuryesi olarak ekibimize katılmanız için '
        'davet edildiniz. Aşağıdaki özel bağlantıya tıklayıp Ad Soyad, Araç Plakası ve '
        'Araç Cinsi bilgilerinizi girerek kaydınızı hemen tamamlayabilirsiniz:\n$inviteUrl';
    return launchWhatsAppMessage(rawPhone: driverPhone, message: msg);
  }

  /// GÖREV #3: Cihazda WhatsApp şemasını doğrular ve kullanıcının WhatsApp bağlantısını test eder.
  static Future<bool> verifyAndOpenWhatsAppBinding({
    required String userPhone,
    required String tenantName,
  }) async {
    final normalized = normalizeTurkishPhone(userPhone);
    if (normalized.length < 10) return false;

    if (!kIsWeb) {
      final schemeTestUri = Uri.parse('whatsapp://send?phone=$normalized');
      try {
        final canOpen = await canLaunchUrl(schemeTestUri);
        if (canOpen) {
          final verifyMsg = Uri.encodeComponent(
            '[$tenantName] WhatsApp bildirim ve canlı takip paylaşım hattım doğrulandı.',
          );
          await launchUrl(
            Uri.parse('whatsapp://send?phone=$normalized&text=$verifyMsg'),
            mode: LaunchMode.externalApplication,
          );
          return true;
        }
      } catch (_) {}
    }

    // Web veya WhatsApp Business / Tarayıcı doğrulaması
    final verifyMsg = Uri.encodeComponent(
      '[$tenantName] WhatsApp bildirim ve canlı takip paylaşım hattım doğrulandı.',
    );
    return launchUrl(
      Uri.parse('https://wa.me/$normalized?text=$verifyMsg'),
      mode: LaunchMode.externalApplication,
    );
  }
}
