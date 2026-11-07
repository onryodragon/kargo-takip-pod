import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';

/// İşletme Sahibi (Admin) için White-Label Marka Ayarları,
/// Otomatik Excel Arşiv E-postası (`report_email`) ve Kurye Ekleme Paneli.
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

  // White-Label & Rapor E-posta Kontrolleri
  late final TextEditingController _nameCtrl;
  late final TextEditingController _logoUrlCtrl;
  late final TextEditingController _reportEmailCtrl;
  late final TextEditingController _primaryColorCtrl;
  bool _savingTenant = false;

  // Yeni Kurye Ekleme Kontrolleri
  final _driverNameCtrl = TextEditingController();
  final _driverEmailCtrl = TextEditingController();
  final _driverPhoneCtrl = TextEditingController();
  final _driverPassCtrl = TextEditingController();
  final _driverPlateCtrl = TextEditingController();
  String _selectedVehicleType = 'Motosiklet';
  bool _savingDriver = false;
  List<Map<String, dynamic>> _drivers = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    final tenant = widget.apiClient.currentTenant;
    _nameCtrl = TextEditingController(text: tenant?.name ?? '');
    _logoUrlCtrl = TextEditingController(text: tenant?.logoUrl ?? '');
    _reportEmailCtrl = TextEditingController(text: tenant?.reportEmail ?? '');
    _primaryColorCtrl = TextEditingController(text: tenant?.primaryColorHex ?? '#1E40AF');
    _loadDrivers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameCtrl.dispose();
    _logoUrlCtrl.dispose();
    _reportEmailCtrl.dispose();
    _primaryColorCtrl.dispose();
    _driverNameCtrl.dispose();
    _driverEmailCtrl.dispose();
    _driverPhoneCtrl.dispose();
    _driverPassCtrl.dispose();
    _driverPlateCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDrivers() async {
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
      );
      widget.onUpdated();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('White-Label işletme ve Excel arşiv ayarları güncellendi.'),
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

  Future<void> _addDriver() async {
    if (_driverNameCtrl.text.trim().isEmpty ||
        _driverEmailCtrl.text.trim().isEmpty ||
        _driverPlateCtrl.text.trim().isEmpty ||
        _driverPassCtrl.text.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen kurye adı, e-posta, plaka ve en az 6 haneli şifre girin.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _savingDriver = true);
    try {
      await widget.apiClient.createDriver(
        fullName: _driverNameCtrl.text.trim(),
        email: _driverEmailCtrl.text.trim(),
        phone: _driverPhoneCtrl.text.trim(),
        password: _driverPassCtrl.text,
        vehiclePlate: _driverPlateCtrl.text.trim().toUpperCase(),
        vehicleType: _selectedVehicleType,
      );
      _driverNameCtrl.clear();
      _driverEmailCtrl.clear();
      _driverPhoneCtrl.clear();
      _driverPassCtrl.clear();
      _driverPlateCtrl.clear();

      await _loadDrivers();
      widget.onUpdated();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Yeni kurye başarıyla eklendi!'),
            backgroundColor: Color(0xFF16A34A),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kurye eklenemedi: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _savingDriver = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
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
                      'İşletme (White-Label) & Kurye Yönetimi',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                Tab(icon: Icon(Icons.palette_outlined), text: 'White-Label & Excel Arşiv'),
                Tab(icon: Icon(Icons.two_wheeler_rounded), text: 'Kuryeler (Drivers)'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // 1. SEKME: WHITE-LABEL & EXCEL RAPOR E-POSTASI
                  ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(20),
                    children: [
                      const Text(
                        'Bu ayarlar yönetici panelinizin ve müşteriye gönderilen geçici canlı takip ekranının (White-Label) görünümünü belirler.',
                        style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'İşletme Adı (White-Label Başlığı)',
                          prefixIcon: Icon(Icons.business),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _reportEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Fotoğraflı Excel PoD Arşiv E-posta Adresi',
                          helperText:
                              'Tamamlanan her teslimatın fotoğraf ve imzası hücrelere gömülerek bu adrese gönderilir.',
                          prefixIcon: Icon(Icons.forward_to_inbox_rounded),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _logoUrlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'İşletme Logo URL',
                          prefixIcon: Icon(Icons.image_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _primaryColorCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Kurumsal Tema Rengi (HEX - Örn: #1E40AF)',
                          prefixIcon: Icon(Icons.color_lens_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: _savingTenant ? null : _saveTenantSettings,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(
                          _savingTenant ? 'KAYDEDİLİYOR...' : 'AYARLARI KAYDET VE UYGULA',
                        ),
                      ),
                    ],
                  ),

                  // 2. SEKME: KURYE EKLEME VE LİSTELEME
                  ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(20),
                    children: [
                      const Text(
                        'Yeni Saha Kuryesi Ekle',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _driverNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Kurye Adı Soyadı *',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _driverEmailCtrl,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                labelText: 'Giriş E-postası *',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _driverPhoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: 'Telefon *',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _driverPlateCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Araç Plakası (34 ABC 12) *',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _selectedVehicleType,
                              decoration: const InputDecoration(
                                labelText: 'Araç Tipi',
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'Motosiklet', child: Text('Motosiklet')),
                                DropdownMenuItem(value: 'Panelvan', child: Text('Panelvan')),
                                DropdownMenuItem(value: 'Kamyonet', child: Text('Kamyonet')),
                                DropdownMenuItem(value: 'Binek Araç', child: Text('Binek Araç')),
                              ],
                              onChanged: (v) {
                                if (v != null) setState(() => _selectedVehicleType = v);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _driverPassCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Kurye Giriş Şifresi (En az 6 karakter) *',
                          prefixIcon: Icon(Icons.lock_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      ElevatedButton.icon(
                        onPressed: _savingDriver ? null : _addDriver,
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: Text(_savingDriver ? 'EKLENİYOR...' : 'KURYEYİ KAYDET'),
                      ),
                      const Divider(height: 32),
                      Text(
                        'Kayıtlı Kuryeler (${_drivers.length})',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 8),
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
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text('${d['email']} • ${d['phone']}'),
                            trailing: Chip(
                              label: Text(
                                d['is_online'] == true ? 'Canlıda' : 'Çevrimdışı',
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
