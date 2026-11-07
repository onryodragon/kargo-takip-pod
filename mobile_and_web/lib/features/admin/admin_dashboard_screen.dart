import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/api_client.dart';
import '../../core/theme/tenant_theme.dart';
import '../../core/widgets/whatsapp_share_button.dart';
import 'create_order_screen.dart';
import 'tenant_settings_sheet.dart';

/// İşletme Sahibi (Admin) 24 Saatlik Canlı Operasyon Haritası,
/// Sipariş / Kurye Atama, Müşteri Geçici Takip Linki Paylaşımı ve PoD İnceleme Ekranı.
class AdminDashboardScreen extends StatefulWidget {
  final ApiClient apiClient;
  final VoidCallback onLogout;

  const AdminDashboardScreen({
    super.key,
    required this.apiClient,
    required this.onLogout,
  });

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final MapController _mapController = MapController();
  Timer? _refreshTimer;

  List<Map<String, dynamic>> _mapOrders = [];
  List<Map<String, dynamic>> _drivers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _fetchDashboardData(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchDashboardData({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      final results = await Future.wait([
        widget.apiClient.getAdminMapOrders(),
        widget.apiClient.listDrivers(),
      ]);
      if (mounted) {
        setState(() {
          _mapOrders = results[0];
          _drivers = results[1];
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatRemainingVisibility(dynamic minutesRaw) {
    if (minutesRaw == null) return '24s';
    final totalMin = int.tryParse(minutesRaw.toString()) ?? 0;
    final hours = totalMin ~/ 60;
    final mins = totalMin % 60;
    if (hours > 0) {
      return '${hours}s ${mins}dk';
    }
    return '${mins}dk';
  }

  Future<void> _shareCustomerTrackingLink(Map<String, dynamic> order) async {
    final token = order['tracking_token']?.toString() ?? '';
    if (token.isEmpty) return;

    final link = widget.apiClient.buildCustomerShareableTrackingUrl(token);
    final tenantName = widget.apiClient.currentTenant?.name ?? 'Teslimat Sistemi';
    final orderNo = order['order_number'] ?? '';

    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Müşteri canlı takip linki panoya kopyalandı: $link'),
          backgroundColor: const Color(0xFF16A34A),
        ),
      );
    }

    try {
      await Share.share(
        '[$tenantName] #$orderNo numaralı siparişinizin canlı kurye konumunu uygulama indirmeden aşağıdaki geçici bağlantıdan takip edebilirsiniz:\n$link',
        subject: '$tenantName - Canlı Kurye Takip Bağlantısı',
      );
    } catch (_) {}
  }

  void _openOrderDetailsAndPoDModal(Map<String, dynamic> order) {
    final isDelivered = order['status'] == 'delivered';
    final photoUrl = order['pod_photo_url']?.toString();
    final signatureUrl = order['pod_signature_url']?.toString();
    final remainingStr = _formatRemainingVisibility(order['remaining_visibility_minutes']);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: isDelivered ? 0.82 : 0.55,
          minChildSize: 0.4,
          maxChildSize: 0.94,
          expand: false,
          builder: (_, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: isDelivered
                          ? const Color(0xFFDCFCE7)
                          : const Color(0xFFDBEAFE),
                      child: Icon(
                        isDelivered ? Icons.verified_rounded : Icons.local_shipping_rounded,
                        color: isDelivered
                            ? const Color(0xFF16A34A)
                            : const Color(0xFF1D4ED8),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Sipariş #${order['order_number']}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            isDelivered
                                ? 'TESLİM EDİLDİ • Haritada kalan süre: $remainingStr'
                                : 'AKTİF SİPARİŞ (${order['status']})',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDelivered
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFFD97706),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const Divider(height: 24),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text('Müşteri: ${order['customer_name']}'),
                  subtitle: Text('Tel: ${order['customer_phone']}'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place_outlined),
                  title: const Text('Teslimat Adresi'),
                  subtitle: Text(
                    '${order['delivery_address']}\nKoordinat: ${order['dest_lat']}, ${order['dest_lng']}',
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.two_wheeler_rounded),
                  title: Text('Atanan Kurye: ${order['driver_name'] ?? 'Henüz Atanmadı'}'),
                  subtitle: Text('Plaka: ${order['vehicle_plate'] ?? '-'}'),
                ),
                const SizedBox(height: 12),
                WhatsAppShareButton(
                  order: order,
                  tenantName:
                      widget.apiClient.currentTenant?.name ?? 'Teslimat Sistemi',
                ),
                if (!isDelivered) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _shareCustomerTrackingLink(order),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('TAKİP LİNKİNİ PANOYA KOPYALA / DİĞER PAYLAŞ'),
                  ),
                ] else ...[
                  const Divider(height: 28),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF86EFAC)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.verified_user_rounded, color: Color(0xFF15803D)),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Zorunlu Teslimat Kanıtı (PoD) & Otomatik Excel Arşivi',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF14532D),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('Teslim Alan: ${order['recipient_name'] ?? order['customer_name']}'),
                        Text('Teslimat Zamanı: ${order['delivered_at'] ?? '-'}'),
                        Text(
                          'Excel E-posta Arşivi: Gönderildi (${widget.apiClient.currentTenant?.reportEmail ?? ''})',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '1. Çekilen Teslimat Fotoğrafı',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  if (photoUrl != null && photoUrl.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        photoUrl,
                        height: 210,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          height: 120,
                          color: const Color(0xFFF1F5F9),
                          alignment: Alignment.center,
                          child: Text('Fotoğraf URL: $photoUrl'),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    '2. Alıcı İmzası (Ekrana Atılan İmza)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  if (signatureUrl != null && signatureUrl.isNotEmpty)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Image.network(
                        signatureUrl,
                        height: 140,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Container(
                          height: 100,
                          alignment: Alignment.center,
                          child: Text('İmza URL: $signatureUrl'),
                        ),
                      ),
                    ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openCreateOrderScreen() async {
    final created = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => CreateOrderScreen(
          apiClient: widget.apiClient,
          availableDrivers: _drivers,
        ),
      ),
    );
    if (created != null) {
      await _fetchDashboardData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sipariş #${created['order_number']} oluşturuldu!'),
            backgroundColor: const Color(0xFF16A34A),
          ),
        );
      }
    }
  }

  void _openTenantSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => TenantSettingsSheet(
        apiClient: widget.apiClient,
        onUpdated: () {
          setState(() {});
          _fetchDashboardData(silent: true);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branding = widget.apiClient.currentTenant ?? TenantBranding.defaultTheme();
    final activeCount = _mapOrders.where((o) => o['status'] != 'delivered').length;
    final delivered24hCount = _mapOrders.where((o) => o['status'] == 'delivered').length;

    return Scaffold(
      appBar: WhiteLabelAppBar(
        branding: branding,
        subtitle:
            'Yönetici Paneli • Aktif: $activeCount | Son 24s Teslim: $delivered24hCount',
        actions: [
          IconButton(
            tooltip: 'Haritayı Yenile',
            onPressed: () => _fetchDashboardData(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'White-Label & Kurye Ayarları',
            onPressed: _openTenantSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'Çıkış Yap',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateOrderScreen,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: const Text('YENİ SİPARİŞ & KURYE ATA'),
      ),
      body: Column(
        children: [
          // ÜST HARİTA: 24 SAATLİK CANLI OPERASYON HARİTASI (flutter_map / OSM)
          Expanded(
            flex: 6,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: const MapOptions(
                    initialCenter: LatLng(40.9923, 29.1244),
                    initialZoom: 12.5,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.podsystem.kargotakip',
                    ),
                    MarkerLayer(
                      markers: [
                        // 1) Sipariş Hedef ve 24 Saatlik Teslimat Pinleri
                        ..._mapOrders.map((order) {
                          final isDelivered = order['status'] == 'delivered';
                          final lat = (order['delivered_lat'] ?? order['dest_lat']) as num;
                          final lng = (order['delivered_lng'] ?? order['dest_lng']) as num;
                          final remText = _formatRemainingVisibility(
                            order['remaining_visibility_minutes'],
                          );

                          return Marker(
                            point: LatLng(lat.toDouble(), lng.toDouble()),
                            width: 125,
                            height: 74,
                            child: GestureDetector(
                              onTap: () => _openOrderDetailsAndPoDModal(order),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isDelivered
                                          ? const Color(0xFF15803D)
                                          : const Color(0xFFD97706),
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: const [
                                        BoxShadow(color: Colors.black26, blurRadius: 4),
                                      ],
                                    ),
                                    child: Text(
                                      isDelivered
                                          ? '✓ #${order['order_number']} ($remText)'
                                          : '#${order['order_number']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    isDelivered
                                        ? Icons.check_circle_rounded
                                        : Icons.location_on_rounded,
                                    size: 38,
                                    color: isDelivered
                                        ? const Color(0xFF16A34A)
                                        : const Color(0xFFEA580C),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),

                        // 2) Kuryelerin Canlı Konum Pinleri
                        ..._drivers
                            .where((d) => d['last_lat'] != null && d['last_lng'] != null)
                            .map((driver) {
                          final dLat = (driver['last_lat'] as num).toDouble();
                          final dLng = (driver['last_lng'] as num).toDouble();
                          return Marker(
                            point: LatLng(dLat, dLng),
                            width: 110,
                            height: 62,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E3A8A),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${driver['full_name']} (${driver['vehicle_plate'] ?? ''})',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const CircleAvatar(
                                  radius: 16,
                                  backgroundColor: Color(0xFF2563EB),
                                  child: Icon(
                                    Icons.two_wheeler_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ],
                ),
                if (_isLoading)
                  const Positioned(
                    top: 12,
                    right: 12,
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(8.0),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ALT LİSTE: SİPARİŞ KARTLARI, MÜŞTERİ LİNK PAYLAŞIMI VE 24s PoD ARŞİVİ
          Expanded(
            flex: 4,
            child: _mapOrders.isEmpty
                ? const Center(
                    child: Text(
                      'Haritada aktif veya son 24 saatte teslim edilmiş sipariş bulunmuyor.\nSağ alttaki butondan yeni sipariş açabilirsiniz.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF64748B)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 80),
                    itemCount: _mapOrders.length,
                    itemBuilder: (context, index) {
                      final order = _mapOrders[index];
                      final isDelivered = order['status'] == 'delivered';
                      final remStr = _formatRemainingVisibility(
                        order['remaining_visibility_minutes'],
                      );

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () {
                            final lat =
                                (order['delivered_lat'] ?? order['dest_lat']) as num;
                            final lng =
                                (order['delivered_lng'] ?? order['dest_lng']) as num;
                            _mapController.move(
                              LatLng(lat.toDouble(), lng.toDouble()),
                              15.5,
                            );
                            _openOrderDetailsAndPoDModal(order);
                          },
                          leading: CircleAvatar(
                            backgroundColor: isDelivered
                                ? const Color(0xFFDCFCE7)
                                : const Color(0xFFFEF3C7),
                            child: Icon(
                              isDelivered
                                  ? Icons.verified_rounded
                                  : Icons.local_shipping_outlined,
                              color: isDelivered
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFFD97706),
                            ),
                          ),
                          title: Text(
                            '#${order['order_number']} — ${order['customer_name']}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isDelivered
                                    ? 'Teslim Edildi (Fotoğraf + İmza Hazır) • Haritada: $remStr kaldı'
                                    : '${order['delivery_address']} • Kurye: ${order['driver_name'] ?? 'Atanmadı'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 8),
                              WhatsAppShareButton(
                                order: order,
                                tenantName: branding.name,
                                compact: true,
                              ),
                            ],
                          ),
                          trailing: isDelivered
                              ? OutlinedButton.icon(
                                  onPressed: () => _openOrderDetailsAndPoDModal(order),
                                  icon: const Icon(Icons.photo_library_outlined, size: 16),
                                  label: const Text('PoD Gör'),
                                )
                              : IconButton(
                                  tooltip: 'Müşteri İzleme Linkini Paylaş',
                                  onPressed: () => _shareCustomerTrackingLink(order),
                                  icon: const Icon(
                                    Icons.share_rounded,
                                    color: Color(0xFF2563EB),
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
