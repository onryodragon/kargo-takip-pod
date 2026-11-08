import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/utils/whatsapp_helper.dart';

/// Yönetici veya Kurye ilk kez giriş yaptığında `is_whatsapp_verified == false` ise
/// açılan Zorunlu WhatsApp Uygulaması Bağlama ve Doğrulama Ekranı.
class WhatsAppLinkGateScreen extends StatefulWidget {
  final ApiClient apiClient;
  final VoidCallback onVerified;

  const WhatsAppLinkGateScreen({
    super.key,
    required this.apiClient,
    required this.onVerified,
  });

  @override
  State<WhatsAppLinkGateScreen> createState() => _WhatsAppLinkGateScreenState();
}

class _WhatsAppLinkGateScreenState extends State<WhatsAppLinkGateScreen> {
  final _phoneCtrl = TextEditingController();
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _connectAndVerifyWhatsApp() async {
    final rawPhone = _phoneCtrl.text.trim();
    final normalized = WhatsAppHelper.normalizeTurkishPhone(rawPhone);
    if (normalized.length < 11) {
      setState(() {
        _error =
            'Lütfen geçerli bir WhatsApp telefon numarası girin (Örn: 0532 000 00 00).';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      // 1. Cihazdaki WhatsApp şemasını tetikle ve doğrula
      await WhatsAppHelper.verifyAndOpenWhatsAppBinding(
        userPhone: rawPhone,
        tenantName:
            widget.apiClient.currentTenant?.name ?? 'Teslimat Sistemi',
      );

      // 2. Backend üzerinde whatsapp_phone ve is_whatsapp_verified = true olarak kaydet
      await widget.apiClient.verifyWhatsAppBinding(rawPhone);

      if (!mounted) return;
      widget.onVerified();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'WhatsApp doğrulaması kaydedilemedi: $e';
      });
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roleLabel =
        widget.apiClient.userRole == 'admin' ? 'İşletme Yöneticisi' : 'Kurye';

    return Scaffold(
      backgroundColor: const Color(0xFFF0FDF4),
      appBar: AppBar(
        backgroundColor: const Color(0xFF15803D),
        foregroundColor: Colors.white,
        title: const Text('Zorunlu WhatsApp Bağlantısı'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await widget.apiClient.logout();
              widget.onVerified();
            },
            icon: const Icon(Icons.logout, color: Colors.white, size: 18),
            label: const Text(
              'Çıkış',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              elevation: 6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        color: const Color(0xFF25D366).withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chat_rounded,
                        size: 38,
                        color: Color(0xFF15803D),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'WhatsApp Uygulamasını Bağla',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Merhaba ${widget.apiClient.userFullName} ($roleLabel),\n'
                      'Müşterilere canlı takip linki ve kuryelere davetiye gönderebilmek için WhatsApp numaranızı bağlamanız zorunludur.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: Colors.grey.shade700,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 22),
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'WhatsApp Telefon Numaranız *',
                        hintText: '05xx xxx xx xx',
                        prefixIcon: Icon(
                          Icons.phone_android_rounded,
                          color: Color(0xFF15803D),
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Colors.red.shade800,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : _connectAndVerifyWhatsApp,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.verified_rounded),
                      label: const Text(
                        "WhatsApp'ı Bağla ve Doğrula",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
