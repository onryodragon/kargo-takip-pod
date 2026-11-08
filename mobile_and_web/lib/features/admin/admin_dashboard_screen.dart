import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/api/api_client.dart';
import '../../core/services/smart_routing_service.dart';
import '../../core/theme/tenant_theme.dart';
import '../../core/widgets/animated_saas_widgets.dart';
import '../../core/widgets/whatsapp_share_button.dart';
import 'create_order_screen.dart';
import 'tenant_settings_sheet.dart';

/// İşletme Sahibi (Admin) 24 Saatlik Canlı Operasyon Haritası,
/// Üstte Otomatik Adres Arama, OSRM Akıllı Çoklu Durak Rota Çizimi,
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
  WebSocketChannel? _tenantWsChannel;
  StreamSubscription? _tenantWsSub;

  // Üstte Hızlı Adres Arama (Autocomplete)
  final _mapSearchCtrl = TextEditingController();
  Timer? _searchDebounce;
  List<AddressSuggestion> _mapSuggestions = [];
  bool _isSearchingMapAddress = false;
  AddressSuggestion? _pinnedSearchAddress;

  List<Map<String, dynamic>> _mapOrders = [];
  List<Map<String, dynamic>> _drivers = [];
  Map<String, List<LatLng>> _driverRoutePolylines = {};
  bool _isLoading = true;

  static const List<Color> _routePalette = [
    Color(0xFF2563EB),
    Color(0xFF7C3AED),
    Color(0xFF0D9488),
    Color(0xFFDB2777),
    Color(0xFFEA580C),
  ];

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
    _connectTenantRealtimeWebSocket();
    _refreshTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      _fetchDashboardData(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchDebounce?.cancel();
    _tenantWsSub?.cancel();
    try {
      _tenantWsChannel?.sink.close();
    } catch (_) {}
    _mapSearchCtrl.dispose();
    super.dispose();
  }

  void _connectTenantRealtimeWebSocket() {
    final wsUrl = widget.apiClient.buildTenantRealtimeWebSocketUrl();
    if (wsUrl.isEmpty) return;

    try {
      _tenantWsSub?.cancel();
      _tenantWsChannel?.sink.close();
    } catch (_) {}

    try {
      _tenantWsChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _tenantWsSub = _tenantWsChannel!.stream.listen(
        (rawMessage) {
          if (!mounted) return;
          try {
            final msg = jsonDecode(rawMessage.toString()) as Map<String, dynamic>;
            final type = msg['type']?.toString() ?? '';

            if (type == 'driver_location_update') {
              final drvId = msg['driver_id']?.toString() ?? '';
              final lat = (msg['lat'] as num?)?.toDouble();
              final lng = (msg['lng'] as num?)?.toDouble();
              if (drvId.isNotEmpty && lat != null && lng != null) {
                bool found = false;
                for (final d in _drivers) {
                  if (d['id']?.toString() == drvId) {
                    d['last_lat'] = lat;
                    d['last_lng'] = lng;
                    d['is_online'] = true;
                    found = true;
                    break;
                  }
                }
                if (found) {
                  setState(() {});
                } else {
                  _fetchDashboardData(silent: true);
                }
              }
            } else if (type == 'order_deleted') {
              final deletedId = msg['order_id']?.toString() ?? '';
              if (deletedId.isNotEmpty) {
                setState(() {
                  _mapOrders.removeWhere((o) => o['id']?.toString() == deletedId);
                });
                _fetchDashboardData(silent: true);
              }
            } else if (type == 'order_created' ||
                type == 'order_updated' ||
                type == 'order_delivered' ||
                type == 'driver_registered') {
              _fetchDashboardData(silent: true);
            }
          } catch (_) {}
        },
        onError: (_) {},
        onDone: () {},
      );
    } catch (_) {}
  }

  void _onMapSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _mapSuggestions = [];
        _isSearchingMapAddress = false;
      });
      return;
    }

    setState(() => _isSearchingMapAddress = true);
    _searchDebounce = Timer(const Duration(milliseconds: 400), () async {
      final results = await SmartRoutingService.searchAddressAutocomplete(
        query,
        backendBaseUrl: ApiClient.baseUrl,
        authToken: widget.apiClient.accessToken,
        limit: 6,
      );
      if (mounted) {
        setState(() {
          _mapSuggestions = results;
          _isSearchingMapAddress = false;
        });
      }
    });
  }

  void _selectMapSearchSuggestion(AddressSuggestion item) {
    FocusScope.of(context).unfocus();
    setState(() {
      _pinnedSearchAddress = item;
      _mapSearchCtrl.text = item.displayName;
      _mapSuggestions = [];
    });
    _mapController.move(item.latLng, 16.0);
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

      final rawOrders = results[0];
      final drivers = results[1];

      // Kuryelerin aktif siparişlerini Nearest-Neighbor ile sırala ve OSRM karayolu rotasını hesapla
      final driverById = <String, Map<String, dynamic>>{
        for (final d in drivers) d['id'].toString(): d,
      };

      final activeByDriver = <String, List<Map<String, dynamic>>>{};
      final unassignedActive = <Map<String, dynamic>>[];
      final deliveredOrders = <Map<String, dynamic>>[];

      for (final o in rawOrders) {
        if (o['status'] == 'delivered') {
          deliveredOrders.add(o);
        } else if (o['assigned_driver_id'] != null &&
            o['assigned_driver_id'].toString().isNotEmpty) {
          final dId = o['assigned_driver_id'].toString();
          activeByDriver.putIfAbsent(dId, () => []).add(o);
        } else {
          unassignedActive.add(o);
        }
      }

      final optimizedActive = <Map<String, dynamic>>[];
      final newPolylines = <String, List<LatLng>>{};

      for (final entry in activeByDriver.entries) {
        final drvId = entry.key;
        final drv = driverById[drvId];
        LatLng? startPos;
        if (drv != null && drv['last_lat'] != null && drv['last_lng'] != null) {
          startPos = LatLng(
            (drv['last_lat'] as num).toDouble(),
            (drv['last_lng'] as num).toDouble(),
          );
        }

        final sortedStops = SmartRoutingService.optimizeOrdersNearestNeighbor(
          entry.value,
          startPosition: startPos,
        );
        optimizedActive.addAll(sortedStops);

        final waypoints = <LatLng>[
          if (startPos != null) startPos,
          ...sortedStops.map(
            (s) => LatLng(
              (s['dest_lat'] as num).toDouble(),
              (s['dest_lng'] as num).toDouble(),
            ),
          ),
        ];

        if (waypoints.length >= 2) {
          final osrm = await SmartRoutingService.fetchOsrmRoadRoute(waypoints);
          newPolylines[drvId] = osrm.polylinePoints;
        }
      }

      if (mounted) {
        setState(() {
          _mapOrders = [
            ...optimizedActive,
            ...unassignedActive,
            ...deliveredOrders,
          ];
          _drivers = drivers;
          _driverRoutePolylines = newPolylines;
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

  Future<void> _reassignOrderDriver(Map<String, dynamic> order, String? newDriverId) async {
    if (newDriverId == null) return;
    try {
      await widget.apiClient.updateOrderAssignment(
        orderId: order['id'].toString(),
        assignedDriverId: newDriverId,
      );
      await _fetchDashboardData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kurye ataması güncellendi ve akıllı rota yeniden sıralandı.'),
            backgroundColor: Color(0xFF16A34A),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Atama hatası: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _confirmAndDeleteOrder(
    Map<String, dynamic> order, {
    BuildContext? modalContext,
  }) async {
    final orderId = order['id']?.toString() ?? '';
    final orderNumber = order['order_number']?.toString() ?? '';
    final customerName = order['customer_name']?.toString() ?? '';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete_forever_rounded, color: Color(0xFFDC2626)),
            SizedBox(width: 8),
            Expanded(child: Text('Siparişi Sil')),
          ],
        ),
        content: Text(
          '#$orderNumber ($customerName) numaralı siparişi kalıcı olarak silmek istediğinize emin misiniz?\n\n'
          'Bu işlem geri alınamaz ve kurye ile yönetici ekranlarından anında kaldırılır.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dlgCtx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dlgCtx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            icon: const Icon(Icons.delete_forever_rounded, size: 18),
            label: const Text('Evet, Siparişi Sil'),
          ),
        ],
      ),
    );

    if (confirmed != true || orderId.isEmpty) return;

    if (modalContext != null && modalContext.mounted) {
      Navigator.of(modalContext).pop();
    }

    try {
      await widget.apiClient.deleteOrder(orderId);
      if (!mounted) return;
      setState(() {
        _mapOrders.removeWhere((o) => o['id']?.toString() == orderId);
      });
      await _fetchDashboardData(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sipariş #$orderNumber kalıcı olarak silindi.'),
          backgroundColor: const Color(0xFFDC2626),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sipariş silinemedi: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _openOrderDetailsAndPoDModal(Map<String, dynamic> order) {
    final isDelivered = order['status'] == 'delivered';
    final photoUrl = order['pod_photo_url']?.toString();
    final signatureUrl = order['pod_signature_url']?.toString();
    final remainingStr = _formatRemainingVisibility(order['remaining_visibility_minutes']);
    final stopLabel = order['stop_label']?.toString();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: isDelivered ? 0.82 : 0.62,
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
                                : '${stopLabel != null ? "$stopLabel • " : ""}AKTİF SİPARİŞ (${order['status']})',
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
                if (!isDelivered && _drivers.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String?>(
                    initialValue: order['assigned_driver_id']?.toString(),
                    decoration: const InputDecoration(
                      labelText: 'Atanan Kurye (Değiştir / Çoklu Görev Ata)',
                      prefixIcon: Icon(Icons.two_wheeler_rounded),
                      border: OutlineInputBorder(),
                    ),
                    items: _drivers
                        .map(
                          (d) => DropdownMenuItem<String?>(
                            value: d['id'].toString(),
                            child: Text('${d['full_name']} (${d['vehicle_plate'] ?? ''})'),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      Navigator.of(ctx).pop();
                      _reassignOrderDriver(order, val);
                    },
                  ),
                ] else
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
                      borderRadius: BorderRadius.circular(14),
                      child: Image.network(
                        photoUrl,
                        height: 215,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          height: 120,
                          color: const Color(0xFFF1F5F9),
                          alignment: Alignment.center,
                          child: Text('Fotoğraf URL: $photoUrl'),
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 380.ms)
                        .scale(
                          begin: const Offset(0.92, 0.92),
                          end: const Offset(1.0, 1.0),
                          curve: Curves.easeOutBack,
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
                        borderRadius: BorderRadius.circular(14),
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
                    )
                        .animate()
                        .fadeIn(delay: 120.ms, duration: 380.ms)
                        .scale(
                          begin: const Offset(0.92, 0.92),
                          end: const Offset(1.0, 1.0),
                          curve: Curves.easeOutBack,
                        ),
                ],
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => _confirmAndDeleteOrder(
                    order,
                    modalContext: ctx,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                    side: const BorderSide(color: Color(0xFFDC2626)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  icon: const Icon(Icons.delete_forever_rounded, size: 20),
                  label: const Text(
                    'SİPARİŞİ SİL',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openCreateOrderScreen({
    LatLng? initialLatLng,
    String? initialAddress,
  }) async {
    final created = await Navigator.of(context).push<Map<String, dynamic>>(
      createSmoothPageRoute(
        CreateOrderScreen(
          apiClient: widget.apiClient,
          availableDrivers: _drivers,
          initialCenter: initialLatLng ?? const LatLng(40.9923, 29.1244),
          initialAddress: initialAddress,
        ),
      ),
    );
    if (created != null) {
      setState(() => _pinnedSearchAddress = null);
      await _fetchDashboardData();
      if (mounted) {
        final count = created['created_count'];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count != null
                  ? '$count adet sipariş oluşturuldu ve akıllı rota optimize edildi!'
                  : 'Sipariş #${created['order_number']} oluşturuldu!',
            ),
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

    final polylineEntries = _driverRoutePolylines.entries.toList();

    return Scaffold(
      appBar: WhiteLabelAppBar(
        branding: branding,
        subtitle:
            'Yönetici Paneli • Aktif: $activeCount | Son 24s Teslim: $delivered24hCount',
        actions: [
          IconButton(
            tooltip: 'Haritayı ve Akıllı Rotayı Yenile',
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
        onPressed: () => _openCreateOrderScreen(
          initialLatLng: _pinnedSearchAddress?.latLng,
          initialAddress: _pinnedSearchAddress?.displayName,
        ),
        icon: const Icon(Icons.add_location_alt_rounded),
        label: const Text('YENİ SİPARİŞ & ÇOKLU GÖREV ATA'),
      ),
      body: Column(
        children: [
          // EN ÜSTTE: ÜCRETSİZ ADRES ARAMA VE OTOMATİK ÖNERİ ÇUBUĞU (AUTOCOMPLETE)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _mapSearchCtrl,
                  onChanged: _onMapSearchChanged,
                  decoration: InputDecoration(
                    hintText: 'Haritada adres ara ve otomatik odaklan (Nominatim / Photon)...',
                    prefixIcon: Icon(Icons.search_rounded, color: branding.primaryColor),
                    suffixIcon: _isSearchingMapAddress
                        ? const Padding(
                            padding: EdgeInsets.all(12.0),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : (_mapSearchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () {
                                  setState(() {
                                    _mapSearchCtrl.clear();
                                    _mapSuggestions = [];
                                    _pinnedSearchAddress = null;
                                  });
                                },
                              )
                            : null),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                  ),
                ),
                if (_mapSuggestions.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(maxHeight: 200),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFCBD5E1)),
                      boxShadow: const [
                        BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 4)),
                      ],
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _mapSuggestions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final item = _mapSuggestions[idx];
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.place_outlined, color: branding.primaryColor),
                          title: Text(
                            item.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
                          ),
                          trailing: TextButton(
                            onPressed: () {
                              _selectMapSearchSuggestion(item);
                              _openCreateOrderScreen(
                                initialLatLng: item.latLng,
                                initialAddress: item.displayName,
                              );
                            },
                            child: const Text('Sipariş Aç'),
                          ),
                          onTap: () => _selectMapSearchSuggestion(item),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // ÜST HARİTA: 24 SAATLİK CANLI OPERASYON HARİTASI + OSRM GERÇEK YOL ROTALARI
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
                    // Kuryelerin OSRM Gerçek Karayolu Rotaları (Renkli PolylineLayer)
                    if (polylineEntries.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          for (int i = 0; i < polylineEntries.length; i++)
                            Polyline(
                              points: polylineEntries[i].value,
                              strokeWidth: 4.5,
                              color: _routePalette[i % _routePalette.length],
                            ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        // 0) Aranan Adres Pini (Zıplayan `Curves.elasticOut` Animasyonlu)
                        if (_pinnedSearchAddress != null)
                          Marker(
                            point: _pinnedSearchAddress!.latLng,
                            width: 155,
                            height: 78,
                            child: BouncingOrderMapPin(
                              key: ValueKey(
                                'search-${_pinnedSearchAddress!.latLng.latitude}',
                              ),
                              label: 'Seçilen Adres (Sipariş Aç)',
                              isSelectedAddress: true,
                              onTap: () => _openCreateOrderScreen(
                                initialLatLng: _pinnedSearchAddress!.latLng,
                                initialAddress:
                                    _pinnedSearchAddress!.displayName,
                              ),
                            ),
                          ),

                        // 1) Sipariş Hedef (Zıplayan Durak) ve 24 Saatlik Parlayan Yeşil Teslimat Pinleri
                        ..._mapOrders.map((order) {
                          final isDelivered = order['status'] == 'delivered';
                          final lat = (order['delivered_lat'] ??
                              order['dest_lat']) as num;
                          final lng = (order['delivered_lng'] ??
                              order['dest_lng']) as num;
                          final remText = _formatRemainingVisibility(
                            order['remaining_visibility_minutes'],
                          );
                          final stopLabel = order['stop_label']?.toString();

                          return Marker(
                            point: LatLng(lat.toDouble(), lng.toDouble()),
                            width: 155,
                            height: 80,
                            child: BouncingOrderMapPin(
                              key: ValueKey('adm-ord-${order['id']}-${order['status']}'),
                              label: isDelivered
                                  ? '✓ #${order['order_number']} ($remText)'
                                  : (stopLabel != null
                                      ? '$stopLabel • #${order['order_number']}'
                                      : '#${order['order_number']}'),
                              isDelivered: isDelivered,
                              isFirstStop: order['stop_sequence'] == 1,
                              onTap: () => _openOrderDetailsAndPoDModal(order),
                            ),
                          );
                        }),

                        // 2) Kuryelerin Canlı Konum Pinleri (Radar Dalgalı + 3D Araç Tipi Rozetli)
                        ..._drivers
                            .where(
                              (d) =>
                                  d['last_lat'] != null &&
                                  d['last_lng'] != null,
                            )
                            .map((driver) {
                          final dLat = (driver['last_lat'] as num).toDouble();
                          final dLng = (driver['last_lng'] as num).toDouble();
                          return Marker(
                            point: LatLng(dLat, dLng),
                            width: 145,
                            height: 82,
                            child: PulsingRadarVehiclePin(
                              label:
                                  '${driver['full_name']} (${driver['vehicle_plate'] ?? ''})',
                              vehicleType: driver['vehicle_type']?.toString(),
                              primaryColor: branding.primaryColor,
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

          // ALT LİSTE: SHIMMER YÜKLEME VEYA STAGGERED ANİMASYONLU SİPARİŞ KARTLARI
          Expanded(
            flex: 4,
            child: _isLoading && _mapOrders.isEmpty
                ? const ShimmerOrderLoadingList()
                : _mapOrders.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: const GlassmorphicContainer(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'İşletmenizde henüz aktif veya son 24 saatte teslim edilmiş sipariş bulunmuyor.\n'
                              'Üstten adres arayarak veya sağ alttaki butondan yeni sipariş ve kurye ataması yapabilirsiniz.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Color(0xFF64748B)),
                            ),
                          ).animate().fadeIn(),
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
                      final stopLabel = order['stop_label']?.toString();
                      final stopSeq = order['stop_sequence'];

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
                                : (stopSeq != null
                                    ? const Color(0xFFDBEAFE)
                                    : const Color(0xFFFEF3C7)),
                            child: stopSeq != null && !isDelivered
                                ? Text(
                                    '$stopSeq',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1D4ED8),
                                    ),
                                  )
                                : Icon(
                                    isDelivered
                                        ? Icons.verified_rounded
                                        : Icons.local_shipping_outlined,
                                    color: isDelivered
                                        ? const Color(0xFF16A34A)
                                        : const Color(0xFFD97706),
                                  ),
                          ),
                          title: Row(
                            children: [
                              if (stopLabel != null && !isDelivered) ...[
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1D4ED8),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    stopLabel,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                              Expanded(
                                child: Text(
                                  '#${order['order_number']} — ${order['customer_name']}',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
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
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  WhatsAppShareButton(
                                    order: order,
                                    tenantName: branding.name,
                                    compact: true,
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _confirmAndDeleteOrder(order),
                                    style: TextButton.styleFrom(
                                      foregroundColor: const Color(0xFFDC2626),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.delete_forever_rounded,
                                      size: 17,
                                    ),
                                    label: const Text(
                                      'Siparişi Sil',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
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
                      )
                          .animate()
                          .fadeIn(
                            duration: 340.ms,
                            delay: (index * 55).ms,
                          )
                          .slideY(
                            begin: 0.12,
                            end: 0,
                            curve: Curves.easeOutCubic,
                          );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
