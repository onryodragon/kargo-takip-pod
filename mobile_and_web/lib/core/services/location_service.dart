import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/api_client.dart';

/// Huawei AppGallery (GMS-Free) Uyumlu Saniyelik (1 sn) Canlı Kurye Konum Servisi.
///
/// Kritik Kurallar:
/// 1. Huawei cihazlarda Google Mobile Services (FusedLocationProviderClient) bulunmadığı için
///    `AndroidSettings(forceLocationManager: true)` zorunlu olarak aktif edilmiştir.
/// 2. `accuracy: LocationAccuracy.bestForNavigation`, `distanceFilter: 0` ve
///    `intervalDuration: const Duration(seconds: 1)` ile 1 saniyelik gerçek zamanlı akış sağlar.
/// 3. Konum verilerini `WS /api/v1/tracking/ws/driver-stream` üzerinden saniyede 1 kez sunucuya
///    aktarır; bağlantı koptuğunda otomatik yeniden bağlanır ve HTTP fallback kullanır.
class GmsFreeLocationService extends ChangeNotifier {
  final ApiClient apiClient;

  StreamSubscription<Position>? _positionSubscription;
  Timer? _oneSecondPulseTimer;
  WebSocketChannel? _driverStreamChannel;
  StreamSubscription? _wsSubscription;
  bool _wsConnected = false;

  Position? _lastPosition;
  bool _isStreaming = false;
  String? _lastError;
  String? _activeOrderId;

  GmsFreeLocationService({required this.apiClient});

  Position? get lastPosition => _lastPosition;
  bool get isStreaming => _isStreaming;
  bool get isWsConnected => _wsConnected;
  String? get lastError => _lastError;

  LatLng get currentLatLng => _lastPosition != null
      ? LatLng(_lastPosition!.latitude, _lastPosition!.longitude)
      : const LatLng(40.9923, 29.1244); // Varsayılan: İstanbul Ataşehir

  void updateActiveOrderId(String? orderId) {
    _activeOrderId = orderId;
  }

  /// Huawei (GMS-Free) için `forceLocationManager: true` ve 1 saniyelik hassas LocationSettings üretir.
  LocationSettings _buildGmsFreeLocationSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        forceLocationManager: true, // HUAWEI AppGallery (GMS-Free) için ZORUNLU!
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Canlı Kurye GPS Takibi Aktif (1 sn)',
          notificationText:
              'Konumunuz saniyelik olarak işletme haritasına ve müşteriye aktarılıyor.',
          enableWakeLock: true,
        ),
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  /// Konum izinlerini kontrol eder ve ister.
  Future<bool> ensurePermissions() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _lastError = 'Cihazınızın GPS / Konum servisi kapalı. Lütfen açın.';
        notifyListeners();
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _lastError = 'Konum izni reddedildi.';
          notifyListeners();
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _lastError =
            'Konum izni kalıcı olarak engellenmiş. Uygulama ayarlarından izin verin.';
        notifyListeners();
        return false;
      }

      _lastError = null;
      return true;
    } catch (e) {
      _lastError = 'Konum izni kontrol edilemedi: $e';
      notifyListeners();
      return false;
    }
  }

  /// Tek seferlik güncel GPS koordinatını okur (`forceLocationManager: true` ile).
  Future<LatLng> getCurrentCoordinateOrFallback() async {
    final hasPermission = await ensurePermissions();
    if (!hasPermission) return currentLatLng;

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: _buildGmsFreeLocationSettings(),
      );
      _lastPosition = pos;
      notifyListeners();
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return currentLatLng;
    }
  }

  /// WebSocket (`WS /api/v1/tracking/ws/driver-stream`) bağlantısını başlatır.
  void _connectDriverWebSocket() {
    try {
      _wsSubscription?.cancel();
      _driverStreamChannel?.sink.close();
    } catch (_) {}

    try {
      final wsUrl = apiClient.buildDriverStreamWebSocketUrl();
      _driverStreamChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _wsConnected = true;
      _wsSubscription = _driverStreamChannel!.stream.listen(
        (_) {},
        onError: (_) {
          _wsConnected = false;
        },
        onDone: () {
          _wsConnected = false;
        },
      );
    } catch (_) {
      _wsConnected = false;
    }
  }

  /// Kurye vardiyadayken saniyelik (1 sn) GPS akışını başlatır ve WebSocket üzerinden sunucuya iletir.
  Future<void> startLiveTracking({String? activeOrderId}) async {
    _activeOrderId = activeOrderId ?? _activeOrderId;
    if (_isStreaming) return;
    final hasPermission = await ensurePermissions();
    if (!hasPermission) return;

    _isStreaming = true;
    notifyListeners();

    _connectDriverWebSocket();

    // İlk konumu hemen al ve gönder
    try {
      final initialPos = await Geolocator.getCurrentPosition(
        locationSettings: _buildGmsFreeLocationSettings(),
      );
      await _handleNewPosition(initialPos, activeOrderId: _activeOrderId);
    } catch (_) {}

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: _buildGmsFreeLocationSettings(),
    ).listen(
      (Position position) {
        _handleNewPosition(position, activeOrderId: _activeOrderId);
      },
      onError: (Object error) {
        _lastError = 'GPS sinyal hatası: $error';
        notifyListeners();
      },
    );

    // Saniyede 1 kez canlı kalp atışı / konum yayını (WebSocket kopmuşsa yeniden bağlar)
    _oneSecondPulseTimer?.cancel();
    _oneSecondPulseTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isStreaming) return;
      if (!_wsConnected) {
        _connectDriverWebSocket();
      }
      if (_lastPosition != null) {
        _pushPositionOverSocket(_lastPosition!, activeOrderId: _activeOrderId);
      }
    });
  }

  void _pushPositionOverSocket(Position pos, {String? activeOrderId}) {
    if (_driverStreamChannel != null && _wsConnected) {
      try {
        _driverStreamChannel!.sink.add(
          jsonEncode({
            'lat': pos.latitude,
            'lng': pos.longitude,
            'speed': pos.speed < 0 ? 0.0 : pos.speed * 3.6,
            'heading': pos.heading < 0 ? 0.0 : pos.heading,
            'accuracy': pos.accuracy,
            if (activeOrderId != null) 'order_id': activeOrderId,
          }),
        );
        return;
      } catch (_) {
        _wsConnected = false;
      }
    }
  }

  Future<void> _handleNewPosition(Position pos, {String? activeOrderId}) async {
    _lastPosition = pos;
    _lastError = null;
    notifyListeners();

    if (_wsConnected && _driverStreamChannel != null) {
      _pushPositionOverSocket(pos, activeOrderId: activeOrderId);
      return;
    }

    try {
      await apiClient.sendDriverLiveLocation(
        lat: pos.latitude,
        lng: pos.longitude,
        speed: pos.speed < 0 ? 0.0 : pos.speed * 3.6, // m/s -> km/s
        heading: pos.heading < 0 ? 0.0 : pos.heading,
        accuracy: pos.accuracy,
        orderId: activeOrderId,
      );
    } catch (_) {
      // Ağ kesintisinde uygulama çökmesin, sonraki sinyalde tekrar dener
    }
  }

  Future<void> stopLiveTracking() async {
    _oneSecondPulseTimer?.cancel();
    _oneSecondPulseTimer = null;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _wsSubscription?.cancel();
    _wsSubscription = null;
    try {
      await _driverStreamChannel?.sink.close();
    } catch (_) {}
    _driverStreamChannel = null;
    _wsConnected = false;
    _isStreaming = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _oneSecondPulseTimer?.cancel();
    _positionSubscription?.cancel();
    _wsSubscription?.cancel();
    try {
      _driverStreamChannel?.sink.close();
    } catch (_) {}
    super.dispose();
  }
}
