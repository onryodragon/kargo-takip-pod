import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/api/api_client.dart';
import '../../core/utils/whatsapp_helper.dart';
import '../../core/widgets/animated_saas_widgets.dart';

/// Yönetici Paneli: "Sürücüler & Filo" Bağımsız Sekmesi
///
/// 1. En üstte: Hızlı "Yeni Sürücü Davet Et (WhatsApp)" kartı.
/// 2. Toplu Canlı Filo Haritası: Boşta (Yeşil) ve Meşgul (Kırmızı/Turuncu) tüm kuryelerin anlık konumları.
/// 3. Filtreleme Çipleri: Tümü, 🟢 Boşta Olanlar, 🔴 Meşgul (Görevde) Olanlar.
/// 4. Sürücü Listesi: Araç cinsi, plaka, online/offline, aktif sipariş sayısı rozeti.
/// 5. Tek Tıkla Görev Verme: Sürücüye tıklandığında `CreateOrderScreen` otomatik atanmış kurye ile açılır.
class AdminDriversTab extends StatefulWidget {
  final ApiClient apiClient;
  final VoidCallback onRefreshNeeded;
  final Function(String? driverId) onAssignTask;

  const AdminDriversTab({
    super.key,
    required this.apiClient,
    required this.onRefreshNeeded,
    required this.onAssignTask,
  });

  @override
  State<AdminDriversTab> createState() => _AdminDriversTabState();
}

class _AdminDriversTabState extends State<AdminDriversTab> {
  final MapController _mapController = MapController();
  final TextEditingController _invitePhoneCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _drivers = [];
  bool _isLoading = false;
  bool _sendingInvite = false;
  String? _lastGeneratedInviteUrl;

  // Filtre: 'all' | 'idle' | 'busy'
  String _statusFilter = 'all';
  // Görünüm Modu: 'split' (üst harita + alt liste) | 'map' | 'list'
  String _viewMode = 'split';

  Timer? _pollingTimer;
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;

  @override
  void initState() {
    super.initState();
    _loadDrivers();
    _startPollingTimer();
    _connectRealtimeWebSocket();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _wsSub?.cancel();
    _wsChannel?.sink.close();
    _invitePhoneCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _startPollingTimer() {
    _pollingTimer?.cancel();
    // 3 saniyede bir sürücülerin durumunu, konumlarını ve sipariş sayılarını arka planda tazeler
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _loadDrivers(silent: true);
    });
  }

  void _connectRealtimeWebSocket() {
    try {
      final wsUrl = widget.apiClient.buildTenantRealtimeWebSocketUrl();
      _wsChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _wsSub = _wsChannel!.stream.listen(
        (data) {
          if (!mounted) return;
          try {
            final decoded = jsonDecode(data.toString());
            final event = decoded['event']?.toString();
            if (event == 'driver_location_update' ||
                event == 'order_status_updated' ||
                event == 'order_created') {
              _loadDrivers(silent: true);
            }
          } catch (_) {}
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  Future<void> _loadDrivers({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      final list = await widget.apiClient.listDrivers();
      if (!mounted) return;
      setState(() {
        _drivers = list;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (!silent) setState(() => _isLoading = false);
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
      final currentBase = ApiClient.baseUrl;
      final inviteUrl =
          '$currentBase/#/driver-invite/$token?api=${Uri.encodeComponent(currentBase)}';

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
      await _loadDrivers(silent: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Davet oluşturulamadı: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingInvite = false);
    }
  }

  List<Map<String, dynamic>> get _filteredDrivers {
    return _drivers.where((d) {
      final isBusy = (d['active_orders_count'] ?? 0) > 0 || d['is_busy'] == true;
      if (_statusFilter == 'idle' && isBusy) return false;
      if (_statusFilter == 'busy' && !isBusy) return false;

      final query = _searchCtrl.text.trim().toLowerCase();
      if (query.isNotEmpty) {
        final name = (d['full_name'] ?? '').toString().toLowerCase();
        final phone = (d['phone'] ?? '').toString().toLowerCase();
        final plate = (d['vehicle_plate'] ?? '').toString().toLowerCase();
        if (!name.contains(query) &&
            !phone.contains(query) &&
            !plate.contains(query)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  IconData _vehicleIcon(String? type) {
    final t = (type ?? '').toLowerCase();
    if (t.contains('moto') || t.contains('motor') || t.contains('scooter')) {
      return Icons.two_wheeler_rounded;
    }
    if (t.contains('panelvan') || t.contains('van') || t.contains('kamyonet')) {
      return Icons.local_shipping_rounded;
    }
    if (t.contains('bisiklet')) {
      return Icons.pedal_bike_rounded;
    }
    return Icons.directions_car_rounded;
  }

  void _openDriverDetailSheet(Map<String, dynamic> driver) {
    final isBusy = (driver['active_orders_count'] ?? 0) > 0 || driver['is_busy'] == true;
    final activeOrders = (driver['active_orders'] as List<dynamic>?) ?? [];
    final activeCount = driver['active_orders_count'] ?? activeOrders.length;
    final primaryColor = Theme.of(context).colorScheme.primary;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: isBusy
                        ? const Color(0xFFFEE2E2)
                        : const Color(0xFFDCFCE7),
                    child: Icon(
                      _vehicleIcon(driver['vehicle_type']?.toString()),
                      color: isBusy
                          ? const Color(0xFFDC2626)
                          : const Color(0xFF16A34A),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          driver['full_name']?.toString() ?? 'Sürücü',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${driver['vehicle_plate'] ?? "Plakasız"} • ${driver['phone'] ?? "Telefon Yok"}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isBusy
                          ? const Color(0xFFFEE2E2)
                          : const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isBusy
                            ? const Color(0xFFFCA5A5)
                            : const Color(0xFF86EFAC),
                      ),
                    ),
                    child: Text(
                      isBusy ? '🔴 $activeCount Görevde' : '🟢 Boşta / Müsait',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isBusy
                            ? const Color(0xFFB91C1C)
                            : const Color(0xFF15803D),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Divider(height: 1),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Aktif Görev Listesi',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '$activeCount Sipariş',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (activeOrders.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: const Center(
                    child: Text(
                      'Bu kuryenin üzerinde şu an bekleyen sipariş bulunmuyor.\n"Görev Ata" butonuna basarak anında yeni sipariş verebilirsiniz.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 12.5),
                    ),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: activeOrders.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (ctx, i) {
                      final ord = activeOrders[i];
                      return Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E40AF),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '#${ord['order_number']}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    ord['customer_name']?.toString() ?? 'Müşteri',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  Text(
                                    ord['delivery_address']?.toString() ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFF64748B),
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: ord['status'] == 'in_transit'
                                    ? const Color(0xFFFEF3C7)
                                    : const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                ord['status'] == 'in_transit'
                                    ? 'Yolda 🧭'
                                    : 'Atandı',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                  color: ord['status'] == 'in_transit'
                                      ? const Color(0xFFB45309)
                                      : const Color(0xFF1D4ED8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  widget.onAssignTask(driver['id']?.toString());
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.add_task_rounded),
                label: Text(
                  '${driver['full_name']} İçin Yeni Görev Ata 🚀',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final totalCount = _drivers.length;
    final idleCount = _drivers
        .where((d) => (d['active_orders_count'] ?? 0) == 0 && d['is_busy'] != true)
        .length;
    final busyCount = totalCount - idleCount;

    final driversWithLocation = _drivers
        .where((d) => d['last_lat'] != null && d['last_lng'] != null)
        .toList();

    return Column(
      children: [
        // -------------------------------------------------------------
        // 1. HIZLI SÜRÜCÜ DAVET ET (WHATSAPP) KARTI
        // -------------------------------------------------------------
        Container(
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF25D366).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person_add_alt_1_rounded,
                      color: Color(0xFF15803D),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Yeni Sürücü Davet Et (WhatsApp)',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  // Görünüm Modu Değiştirici
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'split',
                        icon: Icon(Icons.vertical_split_rounded, size: 14),
                      ),
                      ButtonSegment(
                        value: 'map',
                        icon: Icon(Icons.map_rounded, size: 14),
                      ),
                      ButtonSegment(
                        value: 'list',
                        icon: Icon(Icons.list_alt_rounded, size: 14),
                      ),
                    ],
                    selected: {_viewMode},
                    onSelectionChanged: (val) {
                      setState(() => _viewMode = val.first);
                    },
                    style: SegmentedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _invitePhoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        hintText: 'Kurye Tel (Örn: 0532 123 45 67)',
                        prefixIcon: const Icon(
                          Icons.phone_iphone_rounded,
                          size: 18,
                          color: Color(0xFF25D366),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _sendingInvite ? null : _sendWhatsAppDriverInvite,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF15803D),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: _sendingInvite
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send_rounded, size: 16),
                    label: const Text(
                      'Davetiye Gönder',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              if (_lastGeneratedInviteUrl != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Davet Linki: $_lastGeneratedInviteUrl',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF15803D),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      tooltip: 'Kopyala',
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: _lastGeneratedInviteUrl!),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Davet bağlantısı kopyalandı.'),
                            backgroundColor: Color(0xFF16A34A),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        // -------------------------------------------------------------
        // 2. FİLO HARİTASI (VIEW MODE 'split' veya 'map' İSE)
        // -------------------------------------------------------------
        if (_viewMode == 'split' || _viewMode == 'map')
          Expanded(
            flex: _viewMode == 'map' ? 10 : 5,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: driversWithLocation.isNotEmpty
                        ? LatLng(
                            (driversWithLocation.first['last_lat'] as num)
                                .toDouble(),
                            (driversWithLocation.first['last_lng'] as num)
                                .toDouble(),
                          )
                        : const LatLng(40.9923, 29.1244),
                    initialZoom: 12.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.podsystem.kargotakip',
                    ),
                    MarkerLayer(
                      markers: driversWithLocation.map((driver) {
                        final dLat =
                            (driver['last_lat'] as num).toDouble();
                        final dLng =
                            (driver['last_lng'] as num).toDouble();
                        final isBusy = (driver['active_orders_count'] ?? 0) > 0 ||
                            driver['is_busy'] == true;
                        final activeCount = driver['active_orders_count'] ?? 0;
                        final pinColor = isBusy
                            ? const Color(0xFFDC2626)
                            : const Color(0xFF16A34A);

                        final pinLabel = isBusy
                            ? '${driver['full_name']} ($activeCount Görevde)'
                            : '${driver['full_name']} (Müsait)';

                        return Marker(
                          point: LatLng(dLat, dLng),
                          width: 160,
                          height: 86,
                          child: GestureDetector(
                            onTap: () => _openDriverDetailSheet(driver),
                            child: PulsingRadarVehiclePin(
                              label: pinLabel,
                              vehicleType: driver['vehicle_type']?.toString(),
                              primaryColor: pinColor,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
                Positioned(
                  top: 10,
                  left: 12,
                  child: GlassmorphicContainer(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    borderRadius: 12,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.radar_rounded,
                          size: 14,
                          color: Color(0xFF16A34A),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Canlı Filo: ${driversWithLocation.length} Kurye Çevrimiçi',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_isLoading)
                  const Positioned(
                    top: 10,
                    right: 12,
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(6.0),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

        // -------------------------------------------------------------
        // 3. FİLTRE VE ARAMA ÇUBUĞU
        // -------------------------------------------------------------
        if (_viewMode != 'map')
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ChoiceChip(
                          label: Text('Tümü ($totalCount)'),
                          selected: _statusFilter == 'all',
                          onSelected: (_) => setState(() => _statusFilter = 'all'),
                          visualDensity: VisualDensity.compact,
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: Text(
                            '🟢 Boşta ($idleCount)',
                            style: TextStyle(
                              color: _statusFilter == 'idle'
                                  ? Colors.white
                                  : const Color(0xFF15803D),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          selected: _statusFilter == 'idle',
                          selectedColor: const Color(0xFF16A34A),
                          onSelected: (_) => setState(() => _statusFilter = 'idle'),
                          visualDensity: VisualDensity.compact,
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: Text(
                            '🔴 Meşgul ($busyCount)',
                            style: TextStyle(
                              color: _statusFilter == 'busy'
                                  ? Colors.white
                                  : const Color(0xFFB91C1C),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          selected: _statusFilter == 'busy',
                          selectedColor: const Color(0xFFDC2626),
                          onSelected: (_) => setState(() => _statusFilter = 'busy'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Sürücü Ara...',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 16),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),

        // -------------------------------------------------------------
        // 4. SÜRÜCÜ KARTLARI LİSTESİ
        // -------------------------------------------------------------
        if (_viewMode != 'map')
          Expanded(
            flex: _viewMode == 'list' ? 10 : 5,
            child: _filteredDrivers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.group_off_rounded,
                            size: 44,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _drivers.isEmpty
                                ? 'Henüz sisteme kayıtlı kurye bulunmuyor.\nYukarıdaki alana telefon numarası girerek kuryenizi WhatsApp üzerinden davet edebilirsiniz.'
                                : 'Seçilen filtreye uygun sürücü bulunamadı.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 80),
                    itemCount: _filteredDrivers.length,
                    itemBuilder: (ctx, idx) {
                      final driver = _filteredDrivers[idx];
                      final isBusy = (driver['active_orders_count'] ?? 0) > 0 ||
                          driver['is_busy'] == true;
                      final activeCount = driver['active_orders_count'] ?? 0;
                      final hasLoc = driver['last_lat'] != null &&
                          driver['last_lng'] != null;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: isBusy
                                ? const Color(0xFFFECACA)
                                : const Color(0xFFE2E8F0),
                            width: isBusy ? 1.2 : 1,
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            if (hasLoc) {
                              try {
                                _mapController.move(
                                  LatLng(
                                    (driver['last_lat'] as num).toDouble(),
                                    (driver['last_lng'] as num).toDouble(),
                                  ),
                                  15.0,
                                );
                              } catch (_) {}
                            }
                            _openDriverDetailSheet(driver);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Stack(
                                  children: [
                                    CircleAvatar(
                                      radius: 22,
                                      backgroundColor: isBusy
                                          ? const Color(0xFFFEE2E2)
                                          : const Color(0xFFDCFCE7),
                                      child: Icon(
                                        _vehicleIcon(
                                          driver['vehicle_type']?.toString(),
                                        ),
                                        color: isBusy
                                            ? const Color(0xFFDC2626)
                                            : const Color(0xFF16A34A),
                                        size: 22,
                                      ),
                                    ),
                                    Positioned(
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: hasLoc
                                              ? const Color(0xFF22C55E)
                                              : Colors.grey,
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 1.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              driver['full_name']?.toString() ??
                                                  'Sürücü',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isBusy
                                                  ? const Color(0xFFFEE2E2)
                                                  : const Color(0xFFDCFCE7),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              isBusy
                                                  ? '🔴 $activeCount Görevde'
                                                  : '🟢 Müsait',
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w800,
                                                color: isBusy
                                                    ? const Color(0xFFB91C1C)
                                                    : const Color(0xFF15803D),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${driver['vehicle_plate'] ?? "Plakasız"} • ${driver['phone'] ?? "Tel Yok"}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF64748B),
                                        ),
                                      ),
                                      if (hasLoc) ...[
                                        const SizedBox(height: 2),
                                        const Row(
                                          children: [
                                            Icon(
                                              Icons.location_on_rounded,
                                              size: 12,
                                              color: Color(0xFF16A34A),
                                            ),
                                            SizedBox(width: 2),
                                            Text(
                                              'Canlı GPS Aktif',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF16A34A),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  onPressed: () {
                                    widget.onAssignTask(
                                      driver['id']?.toString(),
                                    );
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: primaryColor,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.add_task_rounded,
                                    size: 15,
                                  ),
                                  label: const Text(
                                    'Görev Ver',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
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
    );
  }
}
