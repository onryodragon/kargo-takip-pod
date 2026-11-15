import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';

/// İşletme Sahibi (Admin) için:
/// 1. White-Label Marka Ayarları + Otomatik Excel Arşiv E-postası (`report_email`) +
///    Gerçek E-Posta (SMTP) Gönderim Ayarları (Gmail + 16 Haneli Uygulama Şifresi)
/// 2. Sadece Kurye Telefon Numarası Girerek WhatsApp'tan Kurye Davetiyesi Gönderme
///    ve Kayıtlı Kuryeleri Listeleme Paneli.
class TenantSettingsSheet extends StatefulWidget {
  final ApiClient apiClient;
  final VoidCallback onUpdated;

  const TenantSettingsSheet({
    super.key,
    required this.apiClient,
    required this.onUpdated,
  });

  @override
  State<TenantSettingsSheet> createState() => _TenantSettingsSheetState();
}

class _TenantSettingsSheetState extends State<TenantSettingsSheet> {
  // White-Label, Rapor E-postası & SMTP Kontrolleri
  late final TextEditingController _nameCtrl;
  late final TextEditingController _logoUrlCtrl;
  late final TextEditingController _reportEmailCtrl;
  late final TextEditingController _primaryColorCtrl;
  final _smtpHostCtrl = TextEditingController(text: 'smtp.gmail.com');
  final _smtpPortCtrl = TextEditingController(text: '587');
  final _smtpUserCtrl = TextEditingController();
  final _smtpPassCtrl = TextEditingController();
  bool _savingTenant = false;

  @override
  void initState() {
    super.initState();
    final tenant = widget.apiClient.currentTenant;
    _nameCtrl = TextEditingController(text: tenant?.name ?? '');
    _logoUrlCtrl = TextEditingController(text: tenant?.logoUrl ?? '');
    _reportEmailCtrl = TextEditingController(text: tenant?.reportEmail ?? '');
    _primaryColorCtrl = TextEditingController(
      text: tenant?.primaryColorHex ?? '#1E40AF',
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _logoUrlCtrl.dispose();
    _reportEmailCtrl.dispose();
    _primaryColorCtrl.dispose();
    _smtpHostCtrl.dispose();
    _smtpPortCtrl.dispose();
    _smtpUserCtrl.dispose();
    _smtpPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveTenantSettings() async {
    setState(() => _savingTenant = true);
    try {
      await widget.apiClient.updateMyTenant(
        name: _nameCtrl.text.trim(),
        logoUrl: _logoUrlCtrl.text.trim(),
        reportEmail: _reportEmailCtrl.text.trim(),
        primaryColor: _primaryColorCtrl.text.trim(),
        smtpHost: _smtpHostCtrl.text.trim().isEmpty
            ? 'smtp.gmail.com'
            : _smtpHostCtrl.text.trim(),
        smtpPort: int.tryParse(_smtpPortCtrl.text.trim()) ?? 587,
        smtpUser: _smtpUserCtrl.text.trim().isEmpty
            ? null
            : _smtpUserCtrl.text.trim(),
        smtpPassword: _smtpPassCtrl.text.trim().isEmpty
            ? null
            : _smtpPassCtrl.text.trim(),
      );
      widget.onUpdated();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'İşletme, Excel arşiv ve E-posta (SMTP) ayarları kaydedildi.',
            ),
            backgroundColor: Color(0xFF16A34A),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _savingTenant = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.55,
      maxChildSize: 0.96,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'İşletme, Marka & SMTP E-Posta Ayarları',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(20),
                children: [
                      const Text(
                        '1. White-Label Marka & Fotoğraflı Excel Arşiv Ayarları',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'İşletme Adı (White-Label Başlığı)',
                          prefixIcon: Icon(Icons.business),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _reportEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText:
                              'Fotoğraflı Excel PoD Arşiv E-posta Adresi',
                          helperText:
                              'Tamamlanan her teslimatın fotoğraf ve imzası Excel hücresine gömülerek bu adrese gönderilir.',
                          prefixIcon: Icon(Icons.forward_to_inbox_rounded),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _logoUrlCtrl,
                              decoration: const InputDecoration(
                                labelText: 'İşletme Logo URL',
                                prefixIcon: Icon(Icons.image_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _primaryColorCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Tema HEX',
                                prefixIcon: Icon(Icons.color_lens_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 30),

                      // E-POSTA (SMTP) GÖNDERİM AYARLARI
                      const Text(
                        '2. E-Posta (SMTP) Gönderim Ayarları (Gmail / Kurumsal)',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFBFDBFE)),
                        ),
                        child: const Text(
                          'Hem "Şifremi Unuttum" 6 haneli doğrulama kodlarının hem de Fotoğraflı Excel Teslimat Raporlarının gerçek e-posta olarak gitmesi için Gmail adresinizi ve 16 haneli Google Uygulama Şifrenizi girin.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1E3A8A),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _smtpHostCtrl,
                              decoration: const InputDecoration(
                                labelText: 'SMTP Sunucusu',
                                hintText: 'smtp.gmail.com',
                                prefixIcon: Icon(Icons.dns_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _smtpPortCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Port',
                                hintText: '587',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _smtpUserCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Gönderici Gmail / E-Posta Adresi',
                          hintText: 'sirketiniz@gmail.com',
                          prefixIcon: Icon(Icons.alternate_email),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _smtpPassCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText:
                              '16 Haneli Gmail Uygulama Şifresi (App Password)',
                          hintText: 'xxxx xxxx xxxx xxxx',
                          prefixIcon: Icon(Icons.key_rounded),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: _savingTenant ? null : _saveTenantSettings,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(
                          _savingTenant
                              ? 'KAYDEDİLİYOR...'
                              : 'TÜM AYARLARI KAYDET VE UYGULA',
                        ),
                      ),
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF93C5FD)),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.delivery_dining_rounded,
                              color: Color(0xFF1D4ED8),
                              size: 24,
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Sürücü davet etme, anlık filo haritası ve doğrudan görev atama işlemleri için ana navigasyondaki "Sürücüler" sekmesini kullanabilirsiniz.',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Color(0xFF1E40AF),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: InkWell(
                          onTap: () async {
                            final base = ApiClient.baseUrl.replaceAll(RegExp(r'/api/v1/?$'), '');
                            final uri = Uri.parse('$base/privacy');
                            try {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            } catch (_) {}
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.shield_outlined, size: 14, color: Color(0xFF64748B)),
                                SizedBox(width: 6),
                                Text(
                                  'Gizlilik Politikası & KVKK / GDPR Bildirimi',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: Color(0xFF64748B),
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
  }
}
