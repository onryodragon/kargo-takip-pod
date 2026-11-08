import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/api/api_client.dart';
import '../../core/services/smart_routing_service.dart';
import '../../core/theme/tenant_theme.dart';
import '../../core/widgets/animated_saas_widgets.dart';

/// İŞ KURALI #1 & #3 & #5: Uygulamasız Müşteri Geçici White-Label Canlı Takip Ekranı.
///
/// Modern SaaS Özellikleri:
/// - Yanıp sönen canlı "CANLI YAYIN 🟢" rozeti
/// - Hareketli 4 adımlı teslimat zaman çizelgesi (Hazırlandı ➔ Kurye Yolda ➔ Adresinize Yaklaştı ➔ Teslim Edildi)
/// - Harita üzerinde Radar Dalgalı (Pulse) Kurye Aracı İkonu ve Zıplayan Teslimat Pini
/// - Glassmorphism (Buzlu Cam) bilgi kartları ve Shimmer yükleme ekranı
class CustomerTrackingScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String trackingToken;

  const CustomerTrackingScreen({
    super.key,
    required this.apiClient,
    required this.trackingToken,
  });

  @override
  State<CustomerTrackingScreen> createState() => _CustomerTrackingScreenState();
}

class _CustomerTrackingScreenState extends State<CustomerTrackingScreen> {
  final MapController _mapController = MapController();

  WebSocketChannel? _wsChannel;
  StreamSubscription<dynamic>? _wsSubscription;

  TenantBranding _branding = TenantBranding.defaultTheme();
  bool _isLoading = true;
  bool _isActive = false;
  String _orderNumber = '';
  String _orderStatus = '';
  String _deliveryAddress = '';
  String _statusMessage = '';
  String? _driverName;
  String? _vehiclePlate;
  LatLng? _destinationLatLng;
  LatLng? _driverLatLng;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeTracking();
  }

  @override
  void dispose() {
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
    super.dispose();
  }

  Future<void> _initializeTracking() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final info =
          await widget.apiClient.getPublicTrackingInfo(widget.trackingToken);
      _applyTrackingPayload(info);

      if (_isActive) {
        _connectWebSocket();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _applyTrackingPayload(Map<String, dynamic> data) {
    final wl = data['white_label'] as Map<String, dynamic>?;
    if (wl != null) {
      final parsedBranding = TenantBranding.fromJson(wl);
      _branding = parsedBranding;
      widget.apiClient.themeController.applyTenantBranding(parsedBranding);
    }

    final active = data['is_active'] == true;
    final destMap = data['destination'] as Map<String, dynamic>?;
    final driverMap = data['driver_location'] as Map<String, dynamic>?;

    LatLng? destPos = _destinationLatLng;
    if (destMap != null && destMap['lat'] != null && destMap['lng'] != null) {
      destPos = LatLng(
        (destMap['lat'] as num).toDouble(),
        (destMap['lng'] as num).toDouble(),
      );
    }

    LatLng? drvPos = active ? _driverLatLng : null;
    if (driverMap != null &&
        driverMap['lat'] != null &&
        driverMap['lng'] != null) {
      drvPos = LatLng(
        (driverMap['lat'] as num).toDouble(),
        (driverMap['lng'] as num).toDouble(),
      );
      _driverName = driverMap['driver_name']?.toString() ?? _driverName;
      _vehiclePlate = driverMap['vehicle_plate']?.toString() ?? _vehiclePlate;
    }

    if (mounted) {
      setState(() {
        _isActive = active;
        _orderNumber = (data['order_number'] ?? _orderNumber).toString();
        _orderStatus = (data['status'] ?? _orderStatus).toString();
        _deliveryAddress =
            (data['delivery_address'] ?? _deliveryAddress).toString();
        _statusMessage = (data['message'] ?? '').toString();
        _destinationLatLng = destPos;
        _driverLatLng = drvPos;
        _isLoading = false;
      });
    }
  }

  void _connectWebSocket() {
    try {
      final wsUrl =
          widget.apiClient.buildTrackingWebSocketUrl(widget.trackingToken);
      _wsChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _wsSubscription = _wsChannel!.stream.listen(
        (dynamic rawMessage) {
          if (rawMessage is String) {
            final decoded = jsonDecode(rawMessage) as Map<String, dynamic>;
            final event = decoded['event']?.toString();

            if (event == 'tracking_expired' || decoded['is_active'] == false) {
              if (mounted) {
                setState(() {
                  _isActive = false;
                  _orderStatus = 'delivered';
                  _driverLatLng = null;
                  _statusMessage =
                      'Siparişiniz Teslim Edilmiştir. Güvenlik nedeniyle geçici canlı takip bağlantısı sonlandırılmıştır.';
                });
              }
              _wsChannel?.sink.close();
              return;
            }

            if (event == 'location_update' || event == 'initial_state') {
              _applyTrackingPayload(decoded);
              if (_driverLatLng != null) {
                try {
                  _mapController.move(_driverLatLng!, 15.0);
                } catch (_) {}
              }
            }
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  /// Kurye ile teslimat adresi arasındaki mesafeye ve sipariş durumuna göre
  /// 4 adımlı zaman çizelgesi indeksini hesaplar:
  /// 0: Hazırlandı, 1: Kurye Yolda, 2: Adresinize Yaklaştı (< 1.2 km), 3: Teslim Edildi
  int _computeTimelineStepIndex() {
    if (!_isActive || _orderStatus == 'delivered') return 3;
    if (_driverLatLng != null && _destinationLatLng != null) {
      final distKm = SmartRoutingService.haversineKm(
        _driverLatLng!,
        _destinationLatLng!,
      );
      if (distKm <= 1.2) return 2;
      return 1;
    }
    if (_orderStatus == 'in_transit' || _orderStatus == 'assigned') {
      return 1;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: WhiteLabelAppBar(
        branding: _branding,
        subtitle: _orderNumber.isNotEmpty
            ? 'Sipariş Canlı Takip • #$_orderNumber'
            : 'Müşteri Canlı Teslimat Takip Ekranı',
      ),
      body: _isLoading
          ? const ShimmerOrderLoadingList(
              title: 'Canlı kurye konumu ve sipariş durumunuz yükleniyor...',
              itemCount: 2,
            )
          : _errorMessage != null
              ? _buildErrorCard()
              : !_isActive
                  ? _buildDeliveredExpiredCard()
                  : _buildLiveTrackingMap(),
    );
  }

  /// İŞ KURALI #3: Sipariş teslim edildiğinde harita kapanır ve bu güvenlik kartı gösterilir.
  Widget _buildDeliveredExpiredCard() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: GlassmorphicContainer(
            padding: const EdgeInsets.all(28),
            borderRadius: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF16A34A), Color(0xFF059669)],
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF16A34A).withValues(alpha: 0.35),
                        blurRadius: 18,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.verified_rounded,
                    size: 46,
                    color: Colors.white,
                  ),
                )
                    .animate()
                    .scale(duration: 600.ms, curve: Curves.elasticOut),
                const SizedBox(height: 18),
                Text(
                  _branding.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _branding.primaryColor,
                  ),
                ),
                if (_orderNumber.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Sipariş No: #$_orderNumber',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                const AnimatedDeliveryTimeline(
                  currentStepIndex: 3,
                  activeColor: Color(0xFF16A34A),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Siparişiniz Teslim Edilmiştir.\nGüvenlik nedeniyle geçici canlı takip bağlantısı sonlandırılmıştır.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Bizi tercih ettiğiniz için teşekkür ederiz.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ).animate().fadeIn(duration: 420.ms).slideY(begin: 0.08, end: 0),
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassmorphicContainer(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off_rounded, size: 52, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                _errorMessage ?? 'Takip bağlantısı bulunamadı.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveTrackingMap() {
    final mapCenter = _driverLatLng ??
        _destinationLatLng ??
        const LatLng(40.9923, 29.1244);
    final stepIdx = _computeTimelineStepIndex();

    double? remainingKm;
    if (_driverLatLng != null && _destinationLatLng != null) {
      remainingKm = SmartRoutingService.haversineKm(
        _driverLatLng!,
        _destinationLatLng!,
      );
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: mapCenter,
            initialZoom: 14.5,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.podsystem.kargotakip',
            ),
            if (_driverLatLng != null && _destinationLatLng != null)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [_driverLatLng!, _destinationLatLng!],
                    strokeWidth: 4.5,
                    color: _branding.primaryColor,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                if (_destinationLatLng != null)
                  Marker(
                    point: _destinationLatLng!,
                    width: 135,
                    height: 76,
                    child: const BouncingOrderMapPin(
                      label: 'Teslimat Noktanız',
                      isFirstStop: true,
                    ),
                  ),
                if (_driverLatLng != null)
                  Marker(
                    point: _driverLatLng!,
                    width: 145,
                    height: 80,
                    child: PulsingRadarVehiclePin(
                      label: 'Kuryeniz Yolda',
                      primaryColor: _branding.primaryColor,
                    ),
                  ),
              ],
            ),
          ],
        ),

        // ÜST BUZLU CAM BAR: CANLI YAYIN 🟢 ROZETİ VE MESAFE ÖZETİ
        Positioned(
          top: 14,
          left: 16,
          right: 16,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: GlassmorphicContainer(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                borderRadius: 16,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF4ADE80)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: const BoxDecoration(
                              color: Color(0xFF16A34A),
                              shape: BoxShape.circle,
                            ),
                          )
                              .animate(onPlay: (c) => c.repeat(reverse: true))
                              .scaleXY(
                                begin: 0.75,
                                end: 1.35,
                                duration: 650.ms,
                              ),
                          const SizedBox(width: 6),
                          const Text(
                            'CANLI YAYIN 🟢',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF15803D),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        remainingKm != null
                            ? 'Kurye adresinize ${remainingKm.toStringAsFixed(1)} km mesafede'
                            : 'GPS sinyali saniyelik aktarılıyor',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 380.ms).slideY(begin: -0.15, end: 0),
            ),
          ),
        ),

        // ALT BUZLU CAM PANEL: ANİMASYONLU ZAMAN ÇİZELGESİ VE KURYE BİLGİSİ
        Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: GlassmorphicContainer(
                padding: const EdgeInsets.all(18),
                borderRadius: 22,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 4 ADIMLI HAREKETLİ TESLİMAT ZAMAN ÇİZELGESİ
                    AnimatedDeliveryTimeline(
                      currentStepIndex: stepIdx,
                      activeColor: _branding.primaryColor,
                    ),
                    const Divider(height: 22),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _branding.primaryColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.two_wheeler_rounded,
                            color: _branding.primaryColor,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _statusMessage.isNotEmpty
                                    ? _statusMessage
                                    : (stepIdx == 2
                                        ? 'Kuryeniz adresinize çok yaklaştı!'
                                        : 'Kuryeniz teslimat adresinize doğru yolda.'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              if (_driverName != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Kurye: $_driverName ${_vehiclePlate != null ? "• Plaka: $_vehiclePlate" : ""}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12.5,
                                    color: Color(0xFF334155),
                                  ),
                                ),
                              ],
                              if (_deliveryAddress.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Adres: $_deliveryAddress',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 420.ms).slideY(begin: 0.15, end: 0),
            ),
          ),
        ),
      ],
    );
  }
}
