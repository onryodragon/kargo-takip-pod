import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';

/// Müşteriye canlı takip linki, kuryeye kayıt davetiyesi ve kullanıcıya
/// WhatsApp bağlama doğrulaması göndermek için uluslararası telefon numarası normalize edici
/// ve çok dilli derin bağlantı (Deep-Link) yardımcısı.
class WhatsAppHelper {
  const WhatsAppHelper._();

  /// Canlı Web Takip Adresi (Varsayılan Render veya Özel İşletme Sunucusu)
  static String get baseWebUrl => ApiClient.baseUrl;

  /// Telefon numarasını temizler ve geçerli formata dönüştürür.
  /// Türkiye için (05... veya 5...) -> 905...,
  /// Diğer tüm uluslararası numaralar için (+ veya 00 kaldırılmış temiz rakamlar).
  static String normalizePhone(String rawPhone) {
    String digits = rawPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';

    if (digits.startsWith('00')) {
      digits = digits.substring(2);
    }

    if (digits.length == 11 && digits.startsWith('05')) {
      return '90${digits.substring(1)}';
    }

    if (digits.length == 10 && digits.startsWith('5')) {
      return '90$digits';
    }

    return digits;
  }

  /// Geriye dönük uyumluluk takma adı.
  static String normalizeTurkishPhone(String rawPhone) => normalizePhone(rawPhone);

  /// 9 dilde müşteri canlı takip bildirim mesajı
  static String buildWhiteLabelTrackingMessage({
    required String customerName,
    required String tenantName,
    required String orderNumber,
    String? baseUrl,
    required String trackingToken,
    String? language,
  }) {
    final cleanBase = (baseUrl != null && baseUrl.trim().isNotEmpty
            ? baseUrl.trim()
            : baseWebUrl)
        .replaceAll(RegExp(r'/+$'), '');
    final cleanOrderNo = orderNumber.trim().replaceFirst(RegExp(r'^#+'), '');
    final trackingUrl =
        '$cleanBase/#/track/${trackingToken.trim()}?api=${Uri.encodeComponent(cleanBase)}';
    final lang = (language ?? ApiClient.currentLanguage).toLowerCase().trim();
    final cName = customerName.trim();
    final tName = tenantName.trim();

    switch (lang) {
      case 'en':
        return 'Hello $cName, your *$tName* order (#$cleanOrderNo) is on the way! You can track your delivery live on the map here: $trackingUrl';
      case 'de':
        return 'Hallo $cName, Ihre *$tName* Bestellung (#$cleanOrderNo) ist unterwegs! Verfolgen Sie Ihre Lieferung live auf der Karte: $trackingUrl';
      case 'es':
        return '¡Hola $cName! Su pedido de *$tName* (#$cleanOrderNo) está en camino. Siga la entrega en vivo en el mapa aquí: $trackingUrl';
      case 'fr':
        return 'Bonjour $cName, votre commande *$tName* (#$cleanOrderNo) est en route ! Suivez votre livraison en direct sur la carte ici : $trackingUrl';
      case 'ar':
        return 'مرحباً $cName، طلبك من *$tName* رقم (#$cleanOrderNo) في الطريق إليك! تتبع مسار التوصيل مباشرة على الخريطة: $trackingUrl';
      case 'ru':
        return 'Здравствуйте, $cName! Ваш заказ из *$tName* (#$cleanOrderNo) уже в пути! Отслеживайте доставку на карте в реальном времени: $trackingUrl';
      case 'id':
        return 'Halo $cName, pesanan *$tName* Anda (#$cleanOrderNo) sedang dalam perjalanan! Lacak pengiriman langsung di peta: $trackingUrl';
      case 'pt':
        return 'Olá $cName, seu pedido de *$tName* (#$cleanOrderNo) está a caminho! Acompanhe a entrega ao vivo no mapa: $trackingUrl';
      case 'tr':
      default:
        return 'Merhaba $cName, *$tName* siparişiniz (#$cleanOrderNo) yola çıktı! Siparişinizi haritadan canlı olarak buradan izleyebilirsiniz: $trackingUrl';
    }
  }

  /// 9 dilde kurye davetiye mesajı
  static String buildDriverInviteMessage({
    required String tenantName,
    required String inviteUrl,
    String? language,
  }) {
    final lang = (language ?? ApiClient.currentLanguage).toLowerCase().trim();
    final tName = tenantName.trim();

    switch (lang) {
      case 'en':
        return 'Hello! You have been invited to join *$tName* as a delivery courier. Click the link below to complete your registration:\n$inviteUrl';
      case 'de':
        return 'Hallo! Sie wurden eingeladen, als Kurier dem Team von *$tName* beizutreten. Klicken Sie auf den Link, um Ihre Registrierung abzuschließen:\n$inviteUrl';
      case 'es':
        return '¡Hola! Has sido invitado a unirte a *$tName* como repartidor. Haz clic en el enlace para completar tu registro:\n$inviteUrl';
      case 'fr':
        return 'Bonjour ! Vous êtes invité à rejoindre l\'équipe de *$tName* en tant que livreur. Cliquez sur le lien pour finaliser votre inscription :\n$inviteUrl';
      case 'ar':
        return 'مرحباً! لقد تمت دعوتك للانضمام إلى فريق *$tName* كمندوب توصيل. اضغط على الرابط التالي لإكمال تسجيلك:\n$inviteUrl';
      case 'ru':
        return 'Здравствуйте! Вы приглашены присоединиться к *$tName* в качестве курьера. Перейдите по ссылке для завершения регистрации:\n$inviteUrl';
      case 'id':
        return 'Halo! Anda diundang untuk bergabung dengan *$tName* sebagai kurir. Klik tautan berikut untuk menyelesaikan pendaftaran Anda:\n$inviteUrl';
      case 'pt':
        return 'Olá! Você foi convidado para fazer parte da equipe *$tName* como entregador. Clique no link para concluir seu cadastro:\n$inviteUrl';
      case 'tr':
      default:
        return 'Merhaba! *$tName* saha kuryesi olarak ekibimize katılmanız için davet edildiniz. Aşağıdaki özel bağlantıya tıklayıp Ad Soyad, Araç Plakası ve Araç Cinsi bilgilerinizi girerek kaydınızı hemen tamamlayabilirsiniz:\n$inviteUrl';
    }
  }

  /// 9 dilde WhatsApp doğrulama mesajı
  static String buildWhatsAppBindingVerifyMessage({
    required String tenantName,
    String? language,
  }) {
    final lang = (language ?? ApiClient.currentLanguage).toLowerCase().trim();
    final tName = tenantName.trim();

    switch (lang) {
      case 'en':
        return '[$tName] WhatsApp notification and live tracking channel verified.';
      case 'de':
        return '[$tName] WhatsApp-Benachrichtigung und Live-Tracking-Kanal bestätigt.';
      case 'es':
        return '[$tName] Notificaciones de WhatsApp y canal de seguimiento en vivo confirmados.';
      case 'fr':
        return '[$tName] Canal de notification et de suivi en direct WhatsApp vérifié.';
      case 'ar':
        return '[$tName] تم تأكيد قناة إشعارات وتتبع واتساب المباشرة بنجاح.';
      case 'ru':
        return '[$tName] Линия уведомлений и отслеживания WhatsApp успешно подтверждена.';
      case 'id':
        return '[$tName] Notifikasi WhatsApp dan saluran pelacakan langsung berhasil diverifikasi.';
      case 'pt':
        return '[$tName] Notificações de WhatsApp e canal de rastreamento ao vivo confirmados.';
      case 'tr':
      default:
        return '[$tName] WhatsApp bildirim ve canlı takip paylaşım hattım doğrulandı.';
    }
  }

  /// Mobilde önce `whatsapp://send?phone=...&text=...` şemasını dener;
  /// Web'de veya cihazda WhatsApp yüklü değilse `https://wa.me/...` adresine yönlendirir.
  static Future<bool> launchWhatsAppMessage({
    required String rawPhone,
    required String message,
  }) async {
    final normalizedPhone = normalizePhone(rawPhone);
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
    String? baseUrl,
    required String trackingToken,
    String? language,
  }) async {
    final message = buildWhiteLabelTrackingMessage(
      customerName: customerName,
      tenantName: tenantName,
      orderNumber: orderNumber,
      baseUrl: baseUrl,
      trackingToken: trackingToken,
      language: language,
    );
    return launchWhatsAppMessage(rawPhone: customerPhone, message: message);
  }

  /// Yönetici tarafından kuryenin telefon numarasına WhatsApp davet linki gönderir.
  static Future<bool> sendDriverInviteViaWhatsApp({
    required String driverPhone,
    required String tenantName,
    required String inviteUrl,
    String? language,
  }) async {
    final msg = buildDriverInviteMessage(
      tenantName: tenantName,
      inviteUrl: inviteUrl,
      language: language,
    );
    return launchWhatsAppMessage(rawPhone: driverPhone, message: msg);
  }

  /// Cihazda WhatsApp şemasını doğrular ve kullanıcının WhatsApp bağlantısını test eder.
  static Future<bool> verifyAndOpenWhatsAppBinding({
    required String userPhone,
    required String tenantName,
    String? language,
  }) async {
    final normalized = normalizePhone(userPhone);
    if (normalized.length < 7) return false;

    final verifyMsg = Uri.encodeComponent(
      buildWhatsAppBindingVerifyMessage(tenantName: tenantName, language: language),
    );

    if (!kIsWeb) {
      final schemeTestUri = Uri.parse('whatsapp://send?phone=$normalized');
      try {
        final canOpen = await canLaunchUrl(schemeTestUri);
        if (canOpen) {
          await launchUrl(
            Uri.parse('whatsapp://send?phone=$normalized&text=$verifyMsg'),
            mode: LaunchMode.externalApplication,
          );
          return true;
        }
      } catch (_) {}
    }

    // Web veya WhatsApp Business / Tarayıcı doğrulaması
    return launchUrl(
      Uri.parse('https://wa.me/$normalized?text=$verifyMsg'),
      mode: LaunchMode.externalApplication,
    );
  }
}
