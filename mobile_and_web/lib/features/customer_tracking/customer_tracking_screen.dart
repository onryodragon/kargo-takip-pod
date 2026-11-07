import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/api/api_client.dart';
import '../../core/theme/tenant_theme.dart';

/// İŞ KURALI #1 & #3: Uygulamasız Müşteri Geçici White-Label Canlı Takip Ekranı.
///
/// Özellikler:
/// - Müşteri linke tıkladığında giriş yapmadan veya uygulama indirmeden açılır.
/// - Üst barda siparişi getiren işletmenin kendi Adı (`tenant_name`), Logosu ve Rengi yer alır.
/// - `GET /api/v1/tracking/public/{tracking_token}` ve `WS /api/v1/tracking/ws/{tracking_token}`
///   ile kuryenin canlı yaklaşmasını haritada gösterir.
/// - Kurye fotoğraf ve imzayı alıp siparişi tamamladığı anda harita otomatik kapanır ve
///   "Siparişiniz Teslim Edilmiştir. Güvenlik nedeniyle geçici canlı takip bağlantısı sonlandırılmıştır."
///   kartı gösterilir.
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
      final info = await widget.apiClient.getPublicTrackingInfo(widget.trackingToken);
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
    if (driverMap != null && driverMap['lat'] != null && driverMap['lng'] != null) {
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
        _deliveryAddress = (data['delivery_address'] ?? _deliveryAddress).toString();
        _statusMessage = (data['message'] ?? '').toString();
        _destinationLatLng = destPos;
        _driverLatLng = drvPos;
        _isLoading = false;
      });
    }
  }

  void _connectWebSocket() {
    try {
      final wsUrl = widget.apiClient.buildTrackingWebSocketUrl(widget.trackingToken);
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
          ? const Center(child: CircularProgressIndicator())
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
          constraints: const BoxConstraints(maxWidth: 460),
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      color: Color(0xFFDCFCE7),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.verified_rounded,
                      size: 44,
                      color: Color(0xFF16A34A),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    _branding.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
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
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'Siparişiniz Teslim Edilmiştir.\nGüvenlik nedeniyle geçici canlı takip bağlantısı sonlandırılmıştır.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Bizi tercih ettiğiniz için teşekkür ederiz.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13.5, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link_off_rounded, size: 48, color: Colors.red),
                const SizedBox(height: 12),
                Text(
                  _errorMessage ?? 'Takip bağlantısı bulunamadı.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveTrackingMap() {
    final mapCenter = _driverLatLng ?? _destinationLatLng ?? const LatLng(40.9923, 29.1244);

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
                    width: 90,
                    height: 68,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Teslimat Noktanız',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.home_work_rounded,
                          size: 38,
                          color: Color(0xFFDC2626),
                        ),
                      ],
                    ),
                  ),
                if (_driverLatLng != null)
                  Marker(
                    point: _driverLatLng!,
                    width: 110,
                    height: 68,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: _branding.primaryColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Kuryeniz Yolda',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: _branding.primaryColor,
                          child: const Icon(
                            Icons.two_wheeler_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),

        // ALT BİLGİ KARTI: SİPARİŞ VE KURYE CANLI DURUMU
        Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                elevation: 6,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Color(0xFF16A34A),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _statusMessage.isNotEmpty
                                  ? _statusMessage
                                  : 'Kuryeniz teslimat adresinize doğru yaklaşıyor.',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      if (_driverName != null)
                        Text(
                          'Kurye: $_driverName ${_vehiclePlate != null ? "($_vehiclePlate)" : ""}',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                        ),
                      if (_deliveryAddress.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Teslimat Adresi: $_deliveryAddress',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
