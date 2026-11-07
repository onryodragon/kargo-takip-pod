import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../utils/whatsapp_helper.dart';

/// Yönetici ve Kurye ekranlarında müşteriye tek tıkla White-Label
/// "WhatsApp'tan Canlı Takip Gönder" aksiyonu sunan ortak buton bileşeni.
///
/// İş Kuralı:
/// Siparişin durumu `delivered` olduğunda veya `tracking_link_enabled == false`
/// olduğunda buton otomatik olarak pasif (`onPressed: null`) hale gelir.
class WhatsAppShareButton extends StatelessWidget {
  final Map<String, dynamic> order;
  final String tenantName;
  final String? baseUrlOverride;
  final bool compact;

  const WhatsAppShareButton({
    super.key,
    required this.order,
    required this.tenantName,
    this.baseUrlOverride,
    this.compact = false,
  });

  /// Sipariş teslim edilmişse veya takip bağlantısı devre dışıysa buton pasiftir.
  bool get isTrackingLinkActive {
    final status = (order['status'] ?? '').toString().toLowerCase();
    final linkEnabled = order['tracking_link_enabled'] != false;
    final token = (order['tracking_token'] ?? '').toString().trim();

    if (status == 'delivered' || status == 'cancelled') {
      return false;
    }
    if (!linkEnabled || token.isEmpty) {
      return false;
    }
    return true;
  }

  String _resolveBaseUrl() {
    if (baseUrlOverride != null && baseUrlOverride!.trim().isNotEmpty) {
      return baseUrlOverride!.trim();
    }
    if (kIsWeb) {
      return Uri.base.origin;
    }
    return ApiClient.baseUrl;
  }

  Future<void> _handlePress(BuildContext context) async {
    if (!isTrackingLinkActive) return;

    final customerName = (order['customer_name'] ?? 'Müşterimiz').toString();
    final customerPhone = (order['customer_phone'] ?? '').toString();
    final orderNumber = (order['order_number'] ?? '').toString();
    final trackingToken = (order['tracking_token'] ?? '').toString();

    final ok = await WhatsAppHelper.sendLiveTrackingViaWhatsApp(
      customerPhone: customerPhone,
      customerName: customerName,
      tenantName: tenantName,
      orderNumber: orderNumber,
      baseUrl: _resolveBaseUrl(),
      trackingToken: trackingToken,
    );

    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('WhatsApp bağlantısı açılamadı.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = isTrackingLinkActive;

    return ElevatedButton.icon(
      onPressed: enabled ? () => _handlePress(context) : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF25D366), // Resmi WhatsApp Yeşili
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFCBD5E1),
        disabledForegroundColor: const Color(0xFF64748B),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 18,
          vertical: compact ? 10 : 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      icon: Icon(
        Icons.chat_rounded,
        size: compact ? 17 : 20,
      ),
      label: Text(
        enabled
            ? "WhatsApp'tan Canlı Takip Gönder"
            : 'Takip Linki Kapalı (Teslim Edildi)',
        style: TextStyle(
          fontSize: compact ? 12.5 : 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
