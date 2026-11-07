import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api/api_client.dart';

/// Sadece İşletme Sahibi (Admin) tarafından kullanılabilen;
/// Haritadan (`flutter_map` OpenStreetMap) dokunarak hedef teslimat noktası seçme,
/// açık adres girme ve kurye atama ekranı.
class CreateOrderScreen extends StatefulWidget {
  final ApiClient apiClient;
  final List<Map<String, dynamic>> availableDrivers;
  final LatLng initialCenter;

  const CreateOrderScreen({
    super.key,
    required this.apiClient,
    required this.availableDrivers,
    this.initialCenter = const LatLng(40.9923, 29.1244),
  });

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

class _CreateOrderScreenState extends State<CreateOrderScreen> {
  final _orderNumberCtrl = TextEditingController();
  final _customerNameCtrl = TextEditingController();
  final _customerPhoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  late LatLng _selectedDest;
  String? _selectedDriverId;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedDest = widget.initialCenter;
    if (widget.availableDrivers.isNotEmpty) {
      _selectedDriverId = widget.availableDrivers.first['id']?.toString();
    }
  }

  @override
  void dispose() {
    _orderNumberCtrl.dispose();
    _customerNameCtrl.dispose();
    _customerPhoneCtrl.dispose();
    _addressCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitOrder() async {
    if (_customerNameCtrl.text.trim().isEmpty ||
        _customerPhoneCtrl.text.trim().isEmpty ||
        _addressCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Müşteri adı, telefonu ve teslimat adresi zorunludur.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final created = await widget.apiClient.createOrder(
        orderNumber: _orderNumberCtrl.text.trim(),
        customerName: _customerNameCtrl.text.trim(),
        customerPhone: _customerPhoneCtrl.text.trim(),
        deliveryAddress: _addressCtrl.text.trim(),
        deliveryNotes: _notesCtrl.text.trim().isNotEmpty ? _notesCtrl.text.trim() : null,
        destLat: _selectedDest.latitude,
        destLng: _selectedDest.longitude,
        assignedDriverId: _selectedDriverId,
      );

      if (mounted) {
        Navigator.of(context).pop(created);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sipariş oluşturulamadı: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Yeni Sipariş Oluştur & Kurye Ata (Admin)'),
      ),
      body: Column(
        children: [
          // ÜST BÖLÜM: OPENSTREETMAP HEDEF NOKTASI SEÇİM HARİTASI
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                FlutterMap(
                  options: MapOptions(
                    initialCenter: _selectedDest,
                    initialZoom: 14.5,
                    onTap: (tapPosition, latLng) {
                      setState(() {
                        _selectedDest = latLng;
                      });
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.podsystem.kargotakip',
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _selectedDest,
                          width: 56,
                          height: 56,
                          child: const Icon(
                            Icons.location_on_rounded,
                            size: 48,
                            color: Color(0xFFDC2626),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Card(
                    color: Colors.white.withValues(alpha: 0.94),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          Icon(Icons.touch_app_rounded, color: primary, size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Teslimat noktasını belirlemek için haritaya dokunun.\n'
                              'Seçilen Koordinat: ${_selectedDest.latitude.toStringAsFixed(6)}, ${_selectedDest.longitude.toStringAsFixed(6)}',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
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

          // ALT BÖLÜM: SİPARİŞ VE KURYE ATAMA FORMU
          Expanded(
            flex: 6,
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _orderNumberCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Sipariş No (Boşsa Otomatik)',
                          hintText: 'SIP-2026-1042',
                          prefixIcon: Icon(Icons.tag),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        initialValue: _selectedDriverId,
                        decoration: const InputDecoration(
                          labelText: 'Atanacak Kurye / Araç',
                          prefixIcon: Icon(Icons.two_wheeler_rounded),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Sonra Ata (Beklemede)'),
                          ),
                          ...widget.availableDrivers.map(
                            (d) => DropdownMenuItem<String?>(
                              value: d['id'].toString(),
                              child: Text(
                                '${d['full_name']} (${d['vehicle_plate'] ?? ''})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (val) => setState(() => _selectedDriverId = val),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customerNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Müşteri Adı Soyadı *',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _customerPhoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Müşteri Telefonu *',
                          prefixIcon: Icon(Icons.phone_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _addressCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Açık Teslimat Adresi (Kurye Değiştiremez) *',
                    prefixIcon: Icon(Icons.place_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Teslimat Notu (Kat, Daire, Zile Basmayın vb.)',
                    prefixIcon: Icon(Icons.notes_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  onPressed: _isSubmitting ? null : _submitOrder,
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text(
                    _isSubmitting
                        ? 'SİPARİŞ OLUŞTURULUYOR...'
                        : 'SİPARİŞİ OLUŞTUR VE GEÇİCİ TAKİP LİNKİ ÜRET',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
