import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/services/location_service.dart';
import '../../core/theme/tenant_theme.dart';
import '../../core/widgets/whatsapp_share_button.dart';
import 'pod_delivery_screen.dart';

/// İŞ KURALI #2 & #4: Saha Kuryesi (Driver) Ana Ekranı.
///
/// Kritik Kurallar:
/// - Kurye kendisine atanan siparişlerin adresini, müşterisini ve haritadaki hedef konumunu
///   SALT-OKUNUR (Read-Only) olarak görür; adresi, konumu veya atamayı KESİNLİKLE değiştiremez.
/// - Harita üzerinde kendi canlı GPS konumu ile hedef nokta arasındaki rotayı görür.
/// - "Teslimat Noktasına Vardım / Teslim Et" butonu ile zorunlu Fotoğraf + İmza ekranına geçer.
class DriverHomeScreen extends StatefulWidget {
  final ApiClient apiClient;
  final GmsFreeLocationService locationService;
  final VoidCallback onLogout;

  const DriverHomeScreen({
    super.key,
    required this.apiClient,
    required this.locationService,
    required this.onLogout,
  });

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  final MapController _mapController = MapController();

  List<Map<String, dynamic>> _myOrders = [];
  Map<String, dynamic>? _selectedOrder;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    widget.locationService.addListener(_onLocationUpdated);
    _loadAssignedOrders();
  }

  @override
  void dispose() {
    widget.locationService.removeListener(_onLocationUpdated);
    super.dispose();
  }

  void _onLocationUpdated() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAssignedOrders() async {
    setState(() => _isLoading = true);
    try {
      final list = await widget.apiClient.getDriverAssignedOrders();
      if (mounted) {
        setState(() {
          _myOrders = list;
          _selectedOrder = list.isNotEmpty ? list.first : null;
          _isLoading = false;
        });
      }

      // Aktif sipariş varsa GMS bağımsız canlı konum paylaşımını başlat
      await widget.locationService.startLiveTracking(
        activeOrderId: _selectedOrder?['id']?.toString(),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _launchTurnByTurnNavigation(double destLat, double destLng) async {
    // Huawei Petal Maps, OSMAnd veya yüklü harita uygulamasını tetikleyen standart geo URI
    final geoUri = Uri.parse('geo:$destLat,$destLng?q=$destLat,$destLng(Teslimat Noktası)');
    final osmWebUri = Uri.parse(
      'https://www.openstreetmap.org/directions?engine=fossgis_osrm_car&route='
      '${widget.locationService.currentLatLng.latitude},${widget.locationService.currentLatLng.longitude}'
      ';$destLat,$destLng',
    );

    if (await canLaunchUrl(geoUri)) {
      await launchUrl(geoUri, mode: LaunchMode.externalApplication);
    } else {
      await launchUrl(osmWebUri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _callCustomer(String phone) async {
    final telUri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(telUri)) {
      await launchUrl(telUri);
    }
  }

  Future<void> _openMandatoryPodScreen(Map<String, dynamic> order) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => PodDeliveryScreen(
          apiClient: widget.apiClient,
          locationService: widget.locationService,
          order: order,
        ),
      ),
    );

    if (result != null) {
      await _loadAssignedOrders();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Teslimat tamamlandı! Fotoğraf ve imzalı Excel arşivi işletme yöneticisine gönderildi.',
            ),
            backgroundColor: Color(0xFF16A34A),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final branding = widget.apiClient.currentTenant ?? TenantBranding.defaultTheme();
    final driverPos = widget.locationService.currentLatLng;

    LatLng? destPos;
    if (_selectedOrder != null) {
      destPos = LatLng(
        (_selectedOrder!['dest_lat'] as num).toDouble(),
        (_selectedOrder!['dest_lng'] as num).toDouble(),
      );
    }

    return Scaffold(
      appBar: WhiteLabelAppBar(
        branding: branding,
        subtitle:
            'Kurye: ${widget.apiClient.userFullName} • ${widget.locationService.isStreaming ? "Canlı GPS Aktif" : "GPS Bekleniyor"}',
        actions: [
          IconButton(
            tooltip: 'Siparişleri Yenile',
            onPressed: _loadAssignedOrders,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Çıkış Yap',
            onPressed: () async {
              await widget.locationService.stopLiveTracking();
              widget.onLogout();
            },
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          // ÜST HARİTA: KURYENİN CANLI KONUMU VE HEDEF ARASINDAKİ ROTA ÇİZGİSİ
          Expanded(
            flex: 5,
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: destPos ?? driverPos,
                initialZoom: 13.5,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.podsystem.kargotakip',
                ),
                if (destPos != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: [driverPos, destPos],
                        strokeWidth: 4.5,
                        color: const Color(0xFF2563EB),
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    // Kuryenin Kendi Canlı Konumu
                    Marker(
                      point: driverPos,
                      width: 64,
                      height: 64,
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: Color(0xFF2563EB),
                            child: Icon(
                              Icons.two_wheeler_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Hedef Teslimat Noktası (Salt-Okunur Pin)
                    if (destPos != null)
                      Marker(
                        point: destPos,
                        width: 64,
                        height: 64,
                        child: const Icon(
                          Icons.location_on_rounded,
                          size: 46,
                          color: Color(0xFFDC2626),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          // ALT BÖLÜM: KİLİTLİ (SALT-OKUNUR) SİPARİŞ KARTLARI
          Expanded(
            flex: 5,
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _myOrders.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24.0),
                          child: Text(
                            'Şu anda size atanmış aktif bir teslimat bulunmuyor.\nYöneticiniz yeni sipariş atadığında burada görünecektir.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFF64748B)),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(14),
                        itemCount: _myOrders.length,
                        itemBuilder: (context, index) {
                          final order = _myOrders[index];
                          final isSelected = _selectedOrder?['id'] == order['id'];
                          final dLat = (order['dest_lat'] as num).toDouble();
                          final dLng = (order['dest_lng'] as num).toDouble();

                          return Card(
                            elevation: isSelected ? 4 : 1,
                            margin: const EdgeInsets.only(bottom: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: isSelected
                                    ? branding.primaryColor
                                    : const Color(0xFFE2E8F0),
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                setState(() => _selectedOrder = order);
                                _mapController.move(LatLng(dLat, dLng), 15.0);
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFDBEAFE),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            '#${order['order_number']}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF1E40AF),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Chip(
                                          visualDensity: VisualDensity.compact,
                                          avatar: Icon(Icons.lock_outline, size: 14),
                                          label: Text(
                                            'Salt-Okunur Rota',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          tooltip: 'Müşteriyi Ara',
                                          onPressed: () =>
                                              _callCustomer(order['customer_phone'].toString()),
                                          icon: const Icon(
                                            Icons.phone_in_talk_rounded,
                                            color: Color(0xFF16A34A),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Alıcı: ${order['customer_name']} (${order['customer_phone']})',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Icon(
                                          Icons.place_outlined,
                                          size: 18,
                                          color: Color(0xFF64748B),
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            order['delivery_address'].toString(),
                                            style: const TextStyle(fontSize: 13.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (order['delivery_notes'] != null &&
                                        order['delivery_notes'].toString().trim().isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        'Not: ${order['delivery_notes']}',
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          fontStyle: FontStyle.italic,
                                          color: Color(0xFFB45309),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      width: double.infinity,
                                      child: WhatsAppShareButton(
                                        order: order,
                                        tenantName: branding.name,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: () =>
                                                _launchTurnByTurnNavigation(dLat, dLng),
                                            icon: const Icon(Icons.navigation_outlined, size: 18),
                                            label: const Text('Yol Tarifi Al'),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          flex: 2,
                                          child: ElevatedButton.icon(
                                            onPressed: () => _openMandatoryPodScreen(order),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(0xFF16A34A),
                                            ),
                                            icon: const Icon(Icons.camera_alt_outlined, size: 18),
                                            label: const Text('Teslim Et (Foto + İmza)'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
