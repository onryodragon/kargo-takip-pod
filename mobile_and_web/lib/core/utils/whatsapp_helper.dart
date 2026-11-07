import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Müşteriye WhatsApp üzerinden White-Label geçici canlı takip bağlantısı
/// göndermek için telefon numarası normalize edici ve derin bağlantı (Deep-Link) yardımcısı.
class WhatsAppHelper {
  const WhatsAppHelper._();

  /// Müşteri telefon numarasını temizler ve Türkiye uluslararası formatına (`905xxxxxxxxx`) dönüştürür.
  ///
  /// Örnekler:
  /// - `0532 111 22 33` -> `905321112233`
  /// - `5321112233`     -> `905321112233`
  /// - `+90 (532) 111 22 33` -> `905321112233`
  /// - `00905321112233` -> `905321112233`
  static String normalizeTurkishPhone(String rawPhone) {
    String digits = rawPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';

    if (digits.startsWith('00')) {
      digits = digits.substring(2);
    }

    if (digits.length == 11 && digits.startsWith('0')) {
      // 05xx xxx xx xx -> 905xx xxx xx xx
      return '90${digits.substring(1)}';
    }

    if (digits.length == 10 && digits.startsWith('5')) {
      // 5xx xxx xx xx -> 905xx xxx xx xx
      return '90$digits';
    }

    return digits;
  }

  /// White-Label mesaj şablonunu oluşturur:
  /// "Merhaba {customer_name}, *{tenant_name}* siparişiniz (#{order_number}) yola çıktı!
  ///  Siparişinizi haritadan canlı olarak buradan izleyebilirsiniz: {base_url}/#/track/{tracking_token}"
  static String buildWhiteLabelTrackingMessage({
    required String customerName,
    required String tenantName,
    required String orderNumber,
    required String baseUrl,
    required String trackingToken,
  }) {
    final cleanBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final cleanOrderNo = orderNumber.trim().replaceFirst(RegExp(r'^#+'), '');
    final trackingUrl = '$cleanBase/#/track/${trackingToken.trim()}';

    return 'Merhaba ${customerName.trim()}, '
        '*${tenantName.trim()}* siparişiniz (#$cleanOrderNo) yola çıktı! '
        'Siparişinizi haritadan canlı olarak buradan izleyebilirsiniz: $trackingUrl';
  }

  /// Mobilde önce `whatsapp://send?phone=...&text=...` şemasını dener;
  /// Web'de veya cihazda WhatsApp yüklü değilse `https://wa.me/...` adresine yönlendirir.
  static Future<bool> sendLiveTrackingViaWhatsApp({
    required String customerPhone,
    required String customerName,
    required String tenantName,
    required String orderNumber,
    required String baseUrl,
    required String trackingToken,
  }) async {
    final normalizedPhone = normalizeTurkishPhone(customerPhone);
    final message = buildWhiteLabelTrackingMessage(
      customerName: customerName,
      tenantName: tenantName,
      orderNumber: orderNumber,
      baseUrl: baseUrl,
      trackingToken: trackingToken,
    );
    final encodedMessage = Uri.encodeComponent(message);

    // 1) Mobil cihazlarda önce yerel WhatsApp şemasını (`whatsapp://send`) dene
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
      } catch (_) {
        // whatsapp:// şeması başarısız olursa wa.me fallback'ine geç
      }
    }

    // 2) Web'de veya WhatsApp uygulaması bulunamadığında https://wa.me/ adresine yönlendir
    final waMeUri = Uri.parse(
      'https://wa.me/$normalizedPhone?text=$encodedMessage',
    );
    return launchUrl(
      waMeUri,
      mode: LaunchMode.externalApplication,
    );
  }
}
