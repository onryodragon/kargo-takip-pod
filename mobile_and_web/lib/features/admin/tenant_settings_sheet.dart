import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/api_client.dart';
import '../../core/utils/whatsapp_helper.dart';

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

class _TenantSettingsSheetState extends State<TenantSettingsSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

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

  // Sadece Telefon Numarası ile WhatsApp Kurye Davetiyesi Kontrolleri
  final _invitePhoneCtrl = TextEditingController();
  bool _sendingInvite = false;
  String? _lastGeneratedInviteUrl;
  List<Map<String, dynamic>> _drivers = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    final tenant = widget.apiClient.currentTenant;
    _nameCtrl = TextEditingController(text: tenant?.name ?? '');
    _logoUrlCtrl = TextEditingController(text: tenant?.logoUrl ?? '');
    _reportEmailCtrl = TextEditingController(text: tenant?.reportEmail ?? '');
    _primaryColorCtrl = TextEditingController(
      text: tenant?.primaryColorHex ?? '#1E40AF',
    );
    _loadTenantAndDrivers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameCtrl.dispose();
    _logoUrlCtrl.dispose();
    _reportEmailCtrl.dispose();
    _primaryColorCtrl.dispose();
    _smtpHostCtrl.dispose();
    _smtpPortCtrl.dispose();
    _smtpUserCtrl.dispose();
    _smtpPassCtrl.dispose();
    _invitePhoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTenantAndDrivers() async {
    try {
      final list = await widget.apiClient.listDrivers();
      if (mounted) {
        setState(() => _drivers = list);
      }
    } catch (_) {}
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

  Future<void> _sendWhatsAppDriverInvite() async {
    final rawPhone = _invitePhoneCtrl.text.trim();
    final normalized = WhatsAppHelper.normalizeTurkishPhone(rawPhone);
    if (normalized.length < 11) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Lütfen kuryenin geçerli WhatsApp telefon numarasını girin (Örn: 0532 000 00 00).',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _sendingInvite = true);
    try {
      final res = await widget.apiClient.createDriverInvite(rawPhone);
      final token = res['invite_token']?.toString() ?? '';
      final inviteUrl = res['invite_url']?.toString() ??
          '${ApiClient.baseWebUrl}/#/driver-invite/$token';

      setState(() {
        _lastGeneratedInviteUrl = inviteUrl;
      });

      await WhatsAppHelper.sendDriverInviteViaWhatsApp(
        driverPhone: rawPhone,
        tenantName:
            widget.apiClient.currentTenant?.name ?? 'Teslimat Sistemi',
        inviteUrl: inviteUrl,
      );

      _invitePhoneCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Kurye davetiyesi oluşturuldu ve WhatsApp'a yönlendirildi!",
            ),
            backgroundColor: Color(0xFF16A34A),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Davetiye oluşturulamadı: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingInvite = false);
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
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'İşletme, SMTP & WhatsApp Kurye Yönetimi',
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
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(
                  icon: Icon(Icons.mail_lock_outlined),
                  text: 'Marka, Excel & SMTP',
                ),
                Tab(
                  icon: Icon(Icons.two_wheeler_rounded),
                  text: 'Kurye Davet & Liste',
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // 1. SEKME: WHITE-LABEL, EXCEL ARŞİV & GERÇEK SMTP E-POSTA AYARLARI
                  ListView(
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
                    ],
                  ),

                  // 2. SEKME: WHATSAPP DAVETİYESİ İLE KURYE EKLEME VE LİSTELEME
                  ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(20),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FDF4),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF86EFAC)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.chat_rounded,
                                  color: Color(0xFF15803D),
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "WhatsApp'tan Kurye Davetiyesi Gönder",
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15.5,
                                      color: Color(0xFF14532D),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Sadece kuryenin telefon numarasını girin. Kurye WhatsApp linkine tıkladığında kendi Ad Soyad, Araç Plakası, Araç Cinsi ve Şifresini girerek otomatik olarak işletmenize kaydolur.',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Color(0xFF166534),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _invitePhoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Colors.white,
                                labelText: 'Kuryenin Telefon Numarası *',
                                hintText: '05xx xxx xx xx',
                                prefixIcon: Icon(
                                  Icons.phone_android_rounded,
                                  color: Color(0xFF15803D),
                                ),
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _sendingInvite
                                  ? null
                                  : _sendWhatsAppDriverInvite,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF25D366),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                              ),
                              icon: _sendingInvite
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.send_rounded),
                              label: const Text(
                                "WhatsApp'tan Davetiye Gönder",
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5,
                                ),
                              ),
                            ),
                            if (_lastGeneratedInviteUrl != null) ...[
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Son Davet Linki: $_lastGeneratedInviteUrl',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: Color(0xFF166534),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      Clipboard.setData(
                                        ClipboardData(
                                          text: _lastGeneratedInviteUrl!,
                                        ),
                                      );
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Davet linki panoya kopyalandı.',
                                          ),
                                        ),
                                      );
                                    },
                                    icon: const Icon(
                                      Icons.copy_rounded,
                                      size: 18,
                                    ),
                                    tooltip: 'Linki Kopyala',
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Divider(height: 30),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Kayıtlı Kuryeler (${_drivers.length})',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _loadTenantAndDrivers,
                            icon: const Icon(Icons.refresh, size: 20),
                            tooltip: 'Listeyi Yenile',
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_drivers.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Henüz kayıtlı kurye yok. Yukarıdan telefon numarası girerek WhatsApp davetiyesi gönderin.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ..._drivers.map(
                        (d) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: d['is_online'] == true
                                  ? const Color(0xFFDCFCE7)
                                  : const Color(0xFFF1F5F9),
                              child: Icon(
                                Icons.two_wheeler_rounded,
                                color: d['is_online'] == true
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFF64748B),
                              ),
                            ),
                            title: Text(
                              '${d['full_name']} (${d['vehicle_plate'] ?? '-'})',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${d['vehicle_type'] ?? 'Motosiklet'} • ${d['phone'] ?? ''} • ${d['email'] ?? ''}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Chip(
                              label: Text(
                                d['is_online'] == true
                                    ? 'Canlıda'
                                    : 'Çevrimdışı',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
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
