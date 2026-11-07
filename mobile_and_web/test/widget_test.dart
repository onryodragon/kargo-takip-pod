import 'package:flutter_test/flutter_test.dart';
import 'package:kargo_takip_pod/core/utils/whatsapp_helper.dart';

void main() {
  test('WhatsAppHelper telefon normalize ve mesaj şablonu testi', () {
    expect(WhatsAppHelper.normalizeTurkishPhone('0532 111 22 33'), '905321112233');
    expect(WhatsAppHelper.normalizeTurkishPhone('5321112233'), '905321112233');
    final msg = WhatsAppHelper.buildWhiteLabelTrackingMessage(
      customerName: 'Ahmet Yılmaz',
      tenantName: 'Yıldız Ekspres Kargo',
      orderNumber: 'SIP-2026-1001',
      trackingToken: 'demo-token',
    );
    expect(msg.contains('https://kargo-takip-pod.onrender.com/#/track/demo-token'), isTrue);
  });
}
