import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../api/api_client.dart';

/// Huawei AppGallery (GMS-Free) Uyumlu Canlı Kurye Konum Servisi.
///
/// Kritik Kural:
/// Huawei cihazlarda Google Mobile Services (FusedLocationProviderClient) bulunmadığı için
/// `AndroidSettings(forceLocationManager: true)` zorunlu olarak aktif edilmiştir.
class GmsFreeLocationService extends ChangeNotifier {
  final ApiClient apiClient;

  StreamSubscription<Position>? _positionSubscription;
  Position? _lastPosition;
  bool _isStreaming = false;
  String? _lastError;

  GmsFreeLocationService({required this.apiClient});

  Position? get lastPosition => _lastPosition;
  bool get isStreaming => _isStreaming;
  String? get lastError => _lastError;

  LatLng get currentLatLng => _lastPosition != null
      ? LatLng(_lastPosition!.latitude, _lastPosition!.longitude)
      : const LatLng(40.9923, 29.1244); // Varsayılan: İstanbul Ataşehir

  /// Huawei (GMS-Free) için `forceLocationManager: true` ayarlı LocationSettings üretir.
  LocationSettings _buildGmsFreeLocationSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        forceLocationManager: true, // HUAWEI AppGallery (GMS-Free) için ZORUNLU!
        intervalDuration: const Duration(seconds: 6),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Kurye Canlı Konum Paylaşımı Aktif',
          notificationText: 'Teslimat rotanız işletme merkezi ve müşteriye iletiliyor.',
          enableWakeLock: true,
        ),
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
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
        _lastError = 'Konum izni kalıcı olarak engellenmiş. Uygulama ayarlarından izin verin.';
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

  /// Tek seferlik güncel GPS koordinatını okur (`forceAndroidLocationManager: true` ile).
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

  /// Kurye vardiyadayken sürekli GPS akışını başlatır ve `POST /api/v1/tracking/location` uç noktasına gönderir.
  Future<void> startLiveTracking({String? activeOrderId}) async {
    if (_isStreaming) return;
    final hasPermission = await ensurePermissions();
    if (!hasPermission) return;

    _isStreaming = true;
    notifyListeners();

    // İlk konumu hemen al ve gönder
    try {
      final initialPos = await Geolocator.getCurrentPosition(
        locationSettings: _buildGmsFreeLocationSettings(),
      );
      await _handleNewPosition(initialPos, activeOrderId: activeOrderId);
    } catch (_) {}

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: _buildGmsFreeLocationSettings(),
    ).listen(
      (Position position) {
        _handleNewPosition(position, activeOrderId: activeOrderId);
      },
      onError: (Object error) {
        _lastError = 'GPS sinyal hatası: $error';
        notifyListeners();
      },
    );
  }

  Future<void> _handleNewPosition(Position pos, {String? activeOrderId}) async {
    _lastPosition = pos;
    _lastError = null;
    notifyListeners();

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
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _isStreaming = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }
}
