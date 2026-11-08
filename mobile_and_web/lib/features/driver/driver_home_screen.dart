import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/api/api_client.dart';
import '../../core/services/location_service.dart';
import '../../core/services/smart_routing_service.dart';
import '../../core/theme/tenant_theme.dart';
import '../../core/widgets/animated_saas_widgets.dart';
import '../../core/widgets/whatsapp_share_button.dart';
import 'pod_delivery_screen.dart';

/// İŞ KURALI #2, #4 & OYUNLAŞTIRILMIŞ MODERN SAAS KURYE EKRANI:
/// - Günlük Görev İlerleme Çubuğu ("Bugünkü Performansın: X / Y Teslimat Tamamlandı 🔥")
/// - Harita üzerinde Radar Dalgalı (Pulse) Kurye İkonu ve Zıplayan (`Curves.elasticOut`) Durak Pinleri
/// - OSRM Gerçek Karayolu Rotası + Glassmorphism Bilgi Kartları + Shimmer Yükleme
/// - Staggered `flutter_animate` ile süzülerek açılan görev kartları
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
  WebSocketChannel? _tenantWsChannel;
  StreamSubscription? _tenantWsSub;

  List<Map<String, dynamic>> _myOrders = [];
  Map<String, dynamic>? _selectedOrder;
  List<LatLng> _osrmRoutePolyline = [];
  double _totalRouteKm = 0.0;
  double _totalRouteMinutes = 0.0;
  bool _isLoading = true;
  LatLng? _lastRoutedDriverPos;
  int _completedTodayCount = 0;

  @override
  void initState() {
    super.initState();
    widget.locationService.addListener(_onLocationUpdated);
    _connectTenantRealtimeWebSocket();
    _loadAssignedOrders();
  }

  @override
  void dispose() {
    widget.locationService.removeListener(_onLocationUpdated);
    _tenantWsSub?.cancel();
    try {
      _tenantWsChannel?.sink.close();
    } catch (_) {}
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
            final msg =
                jsonDecode(rawMessage.toString()) as Map<String, dynamic>;
            final type = msg['type']?.toString() ?? '';
            if (type == 'order_deleted') {
              final deletedId = msg['order_id']?.toString() ?? '';
              if (deletedId.isNotEmpty) {
                setState(() {
                  _myOrders
                      .removeWhere((o) => o['id']?.toString() == deletedId);
                  if (_selectedOrder?['id']?.toString() == deletedId) {
                    _selectedOrder =
                        _myOrders.isNotEmpty ? _myOrders.first : null;
                  }
                });
                widget.locationService.updateActiveOrderId(
                  _selectedOrder?['id']?.toString(),
                );
                _recomputeSmartRoute(widget.locationService.currentLatLng);
              }
            } else if (type == 'order_created' ||
                type == 'order_updated' ||
                type == 'order_delivered') {
              _loadAssignedOrders();
            }
          } catch (_) {}
        },
        onError: (_) {},
        onDone: () {},
      );
    } catch (_) {}
  }

  void _onLocationUpdated() {
    if (!mounted) return;
    final currentPos = widget.locationService.currentLatLng;
    if (_myOrders.isNotEmpty &&
        (_lastRoutedDriverPos == null ||
            SmartRoutingService.haversineKm(
                  _lastRoutedDriverPos!,
                  currentPos,
                ) >
                0.15)) {
      _recomputeSmartRoute(currentPos);
    } else {
      setState(() {});
    }
  }

  Future<void> _loadAssignedOrders() async {
    setState(() => _isLoading = true);
    try {
      final driverPos = widget.locationService.currentLatLng;
      final list = await widget.apiClient.getDriverAssignedOrders(
        currentLat: driverPos.latitude,
        currentLng: driverPos.longitude,
      );

      final optimized = SmartRoutingService.optimizeOrdersNearestNeighbor(
        list,
        startPosition: driverPos,
      );

      if (mounted) {
        setState(() {
          _myOrders = optimized;
          _selectedOrder = optimized.isNotEmpty ? optimized.first : null;
          _isLoading = false;
        });
      }

      await _recomputeSmartRoute(driverPos);

      await widget.locationService.startLiveTracking(
        activeOrderId: _selectedOrder?['id']?.toString(),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _recomputeSmartRoute(LatLng driverPos) async {
    if (_myOrders.isEmpty) {
      if (mounted) {
        setState(() {
          _osrmRoutePolyline = [];
          _totalRouteKm = 0.0;
          _totalRouteMinutes = 0.0;
        });
      }
      return;
    }

    _lastRoutedDriverPos = driverPos;
    final sorted = SmartRoutingService.optimizeOrdersNearestNeighbor(
      _myOrders,
      startPosition: driverPos,
    );

    final waypoints = <LatLng>[
      driverPos,
      ...sorted.map(
        (o) => LatLng(
          (o['dest_lat'] as num).toDouble(),
          (o['dest_lng'] as num).toDouble(),
        ),
      ),
    ];

    final osrmResult = await SmartRoutingService.fetchOsrmRoadRoute(waypoints);
    if (mounted) {
      setState(() {
        _myOrders = sorted;
        if (_selectedOrder != null) {
          final selId = _selectedOrder!['id'];
          _selectedOrder = sorted.firstWhere(
            (o) => o['id'] == selId,
            orElse: () => sorted.first,
          );
        } else if (sorted.isNotEmpty) {
          _selectedOrder = sorted.first;
        }
        _osrmRoutePolyline = osrmResult.polylinePoints;
        _totalRouteKm = osrmResult.totalDistanceKm;
        _totalRouteMinutes = osrmResult.totalDurationMinutes;
      });
    }
  }

  Future<void> _launchTurnByTurnNavigation(
    double destLat,
    double destLng,
  ) async {
    final geoUri = Uri.parse(
      'geo:$destLat,$destLng?q=$destLat,$destLng(Teslimat Noktası)',
    );
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
      createSmoothPageRoute(
        PodDeliveryScreen(
          apiClient: widget.apiClient,
          locationService: widget.locationService,
          order: order,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _completedTodayCount += 1;
      });
      await _loadAssignedOrders();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Harika İş! 🎉 Teslimat tamamlandı, fotoğraflı Excel arşivi gönderildi ve sıradaki durağa geçildi.',
            ),
            backgroundColor: Color(0xFF16A34A),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final branding =
        widget.apiClient.currentTenant ?? TenantBranding.defaultTheme();
    final driverPos = widget.locationService.currentLatLng;

    LatLng? firstStopPos;
    if (_myOrders.isNotEmpty) {
      firstStopPos = LatLng(
        (_myOrders.first['dest_lat'] as num).toDouble(),
        (_myOrders.first['dest_lng'] as num).toDouble(),
      );
    }

    final totalTasksToday = _completedTodayCount + _myOrders.length;

    return Scaffold(
      appBar: WhiteLabelAppBar(
        branding: branding,
        subtitle:
            'Kurye: ${widget.apiClient.userFullName} • ${widget.locationService.isStreaming ? "1 sn Canlı GPS Aktif 🟢" : "GPS Bekleniyor"}',
        actions: [
          IconButton(
            tooltip: 'Rotayı ve Siparişleri Yenile',
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
          // ÜST OYUNLAŞTIRMA BARI: GÜNLÜK GÖREV İLERLEME ÇUBUĞU
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: DriverDailyProgressBanner(
              completedCount: _completedTodayCount,
              totalCount: totalTasksToday,
            ),
          ),

          // ÜST HARİTA: RADAR DALGALI KURYE İKONU + ZIPLAYAN DURAK PİNLERİ + OSRM KARAYOLU ROTASI
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: firstStopPos ?? driverPos,
                    initialZoom: 13.2,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.podsystem.kargotakip',
                    ),
                    if (_osrmRoutePolyline.length >= 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _osrmRoutePolyline,
                            strokeWidth: 5.0,
                            color: const Color(0xFF2563EB),
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        // 1) Kuryenin Kendi Canlı GPS Konumu (Radar Dalgalı 3D Araç İkonu)
                        Marker(
                          point: driverPos,
                          width: 140,
                          height: 82,
                          child: PulsingRadarVehiclePin(
                            label: widget.apiClient.userFullName,
                            vehicleType: widget
                                .apiClient.currentUser?['vehicle_type']
                                ?.toString(),
                            primaryColor: branding.primaryColor,
                          ),
                        ),

                        // 2) Optimize Edilmiş Durak Pinleri (Zıplayan `Curves.elasticOut` Animasyonlu)
                        ..._myOrders.map((order) {
                          final oLat = (order['dest_lat'] as num).toDouble();
                          final oLng = (order['dest_lng'] as num).toDouble();
                          final seq = order['stop_sequence'] ?? 1;
                          final stopLabel = order['stop_label']?.toString() ??
                              '$seq. Durak';
                          final isFirstStop = seq == 1;

                          return Marker(
                            point: LatLng(oLat, oLng),
                            width: 150,
                            height: 78,
                            child: BouncingOrderMapPin(
                              key: ValueKey('drv-stop-${order['id']}-$seq'),
                              label: stopLabel,
                              isFirstStop: isFirstStop,
                              onTap: () {
                                setState(() => _selectedOrder = order);
                                widget.locationService.updateActiveOrderId(
                                  order['id']?.toString(),
                                );
                                _mapController.move(LatLng(oLat, oLng), 15.2);
                              },
                            ),
                          );
                        }),
                      ],
                    ),
                  ],
                ),

                // Harita Üzeri Buzlu Cam (Glassmorphic) Akıllı Rota Özeti
                if (_myOrders.isNotEmpty)
                  Positioned(
                    top: 10,
                    left: 12,
                    right: 12,
                    child: GlassmorphicContainer(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      borderRadius: 14,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.route_rounded,
                            color: Color(0xFF1D4ED8),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Akıllı Rota: ${_myOrders.length} Durak • '
                              'Toplam ${_totalRouteKm.toStringAsFixed(1)} km (~${_totalRouteMinutes.toStringAsFixed(0)} dk)',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1E3A8A),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ).animate().fadeIn(duration: 350.ms),
                  ),
              ],
            ),
          ),

          // ALT BÖLÜM: SHIMMER YÜKLEME VEYA STAGGERED ANİMASYONLU SİPARİŞ KARTLARI
          Expanded(
            flex: 5,
            child: _isLoading
                ? const ShimmerOrderLoadingList(
                    title: 'Sana atanan duraklar ve en yakın rota diziliyor...',
                  )
                : _myOrders.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: const GlassmorphicContainer(
                            padding: EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '🎉',
                                  style: TextStyle(fontSize: 40),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Harika! Bekleyen Teslimatın Yok',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Yöneticiniz yeni sipariş atadığında en yakın durak sırasına göre anında burada görünecektir.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Color(0xFF64748B),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ).animate().fadeIn().scale(),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(14),
                        itemCount: _myOrders.length,
                        itemBuilder: (context, index) {
                          final order = _myOrders[index];
                          final isSelected =
                              _selectedOrder?['id'] == order['id'];
                          final dLat = (order['dest_lat'] as num).toDouble();
                          final dLng = (order['dest_lng'] as num).toDouble();
                          final seq = order['stop_sequence'] ?? (index + 1);
                          final stopLabel = order['stop_label']?.toString() ??
                              (seq == 1
                                  ? '1. Durak (En Yakın)'
                                  : '$seq. Durak');
                          final distKm = order['distance_from_prev_km'];

                          return Card(
                            elevation: isSelected ? 6 : 2,
                            margin: const EdgeInsets.only(bottom: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                              side: BorderSide(
                                color: isSelected
                                    ? branding.primaryColor
                                    : const Color(0xFFE2E8F0),
                                width: isSelected ? 2.2 : 1,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () {
                                setState(() => _selectedOrder = order);
                                widget.locationService.updateActiveOrderId(
                                  order['id']?.toString(),
                                );
                                _mapController.move(LatLng(dLat, dLng), 15.2);
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
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              colors: seq == 1
                                                  ? [
                                                      const Color(0xFFDC2626),
                                                      const Color(0xFFEA580C),
                                                    ]
                                                  : [
                                                      const Color(0xFF1D4ED8),
                                                      const Color(0xFF4F46E5),
                                                    ],
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(9),
                                          ),
                                          child: Text(
                                            stopLabel,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: Colors.white,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFDBEAFE),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            '#${order['order_number']}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFF1E40AF),
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        if (distKm != null) ...[
                                          const SizedBox(width: 6),
                                          Text(
                                            '• $distKm km',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF475569),
                                            ),
                                          ),
                                        ],
                                        const Spacer(),
                                        IconButton(
                                          tooltip: 'Müşteriyi Ara',
                                          onPressed: () => _callCustomer(
                                            order['customer_phone'].toString(),
                                          ),
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
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Icon(
                                          Icons.place_outlined,
                                          size: 18,
                                          color: Color(0xFF64748B),
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            order['delivery_address']
                                                .toString(),
                                            style: const TextStyle(
                                              fontSize: 13.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (order['delivery_notes'] != null &&
                                        order['delivery_notes']
                                            .toString()
                                            .trim()
                                            .isNotEmpty) ...[
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
                                                _launchTurnByTurnNavigation(
                                              dLat,
                                              dLng,
                                            ),
                                            icon: const Icon(
                                              Icons.navigation_outlined,
                                              size: 18,
                                            ),
                                            label: const Text('Yol Tarifi Al'),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          flex: 2,
                                          child: ElevatedButton.icon(
                                            onPressed: () =>
                                                _openMandatoryPodScreen(order),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  const Color(0xFF16A34A),
                                            ),
                                            icon: const Icon(
                                              Icons.camera_alt_outlined,
                                              size: 18,
                                            ),
                                            label: const Text(
                                              'Teslim Et (Foto + İmza)',
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                              .animate()
                              .fadeIn(
                                duration: 360.ms,
                                delay: (index * 65).ms,
                              )
                              .slideY(
                                begin: 0.14,
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
