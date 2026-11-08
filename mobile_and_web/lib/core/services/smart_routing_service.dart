import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Adres Arama Öneri Modeli (OpenStreetMap Nominatim / Komoot Photon)
class AddressSuggestion {
  final String displayName;
  final double lat;
  final double lng;
  final String source;

  const AddressSuggestion({
    required this.displayName,
    required this.lat,
    required this.lng,
    this.source = 'nominatim',
  });

  LatLng get latLng => LatLng(lat, lng);

  factory AddressSuggestion.fromJson(Map<String, dynamic> json) {
    return AddressSuggestion(
      displayName: (json['display_name'] ?? '').toString().trim(),
      lat: double.tryParse((json['lat'] ?? '0').toString()) ?? 0.0,
      lng: double.tryParse((json['lng'] ?? json['lon'] ?? '0').toString()) ?? 0.0,
      source: (json['source'] ?? 'nominatim').toString(),
    );
  }
}

/// OSRM Karayolu Rota Sonucu (`overview=full&geometries=geojson`)
class OsrmRouteResult {
  final List<LatLng> polylinePoints;
  final double totalDistanceKm;
  final double totalDurationMinutes;
  final bool isOsrmRoadGeometry;

  const OsrmRouteResult({
    required this.polylinePoints,
    required this.totalDistanceKm,
    required this.totalDurationMinutes,
    this.isOsrmRoadGeometry = true,
  });
}

/// Ücretsiz Adres Otomatik Öneri (Nominatim / Photon) ve
/// Akıllı Çoklu Durak Rota Optimizasyon Motoru (Nearest-Neighbor TSP + OSRM API).
class SmartRoutingService {
  static const String _userAgent =
      'KargoTakipPoD-MultiTenant/2.0 (https://kargo-takip-pod.onrender.com)';

  /// İki koordinat arasındaki Haversine mesafesini (km) hesaplar.
  static double haversineKm(LatLng a, LatLng b) {
    const double r = 6371.0;
    final double dLat = _degToRad(b.latitude - a.latitude);
    final double dLon = _degToRad(b.longitude - a.longitude);
    final double lat1 = _degToRad(a.latitude);
    final double lat2 = _degToRad(b.latitude);

    final double h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    final double c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return r * c;
  }

  static double _degToRad(double deg) => deg * (math.pi / 180.0);

  /// Ücretsiz OpenStreetMap Nominatim + Komoot Photon üzerinden adres önerileri getirir.
  static Future<List<AddressSuggestion>> searchAddressAutocomplete(
    String query, {
    String? backendBaseUrl,
    String? authToken,
    int limit = 6,
  }) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) return [];

    // 1. Öncelik: Doğrudan OpenStreetMap Nominatim API (Türkiye öncelikli)
    try {
      final nominatimUri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?format=json&q=${Uri.encodeQueryComponent(cleaned)}'
        '&countrycodes=tr&addressdetails=1&limit=$limit',
      );
      final headers = <String, String>{
        'Accept': 'application/json',
        'Accept-Language': 'tr,en;q=0.8',
        if (!kIsWeb) 'User-Agent': _userAgent,
      };
      final response = await http
          .get(nominatimUri, headers: headers)
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is List && decoded.isNotEmpty) {
          final results = decoded
              .whereType<Map<String, dynamic>>()
              .map(AddressSuggestion.fromJson)
              .where((s) => s.displayName.isNotEmpty && s.lat != 0.0)
              .toList();
          if (results.isNotEmpty) return results;
        }
      }
    } catch (_) {}

    // 2. Öncelik: Backend Proxy (/api/v1/orders/geocode/search)
    if (backendBaseUrl != null && backendBaseUrl.isNotEmpty && authToken != null) {
      try {
        final proxyUri = Uri.parse(
          '$backendBaseUrl/api/v1/orders/geocode/search'
          '?q=${Uri.encodeQueryComponent(cleaned)}&limit=$limit',
        );
        final resp = await http.get(
          proxyUri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $authToken',
          },
        ).timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final list = jsonDecode(utf8.decode(resp.bodyBytes));
          if (list is List && list.isNotEmpty) {
            return list
                .whereType<Map<String, dynamic>>()
                .map(AddressSuggestion.fromJson)
                .where((s) => s.displayName.isNotEmpty)
                .toList();
          }
        }
      } catch (_) {}
    }

    // 3. Yedek: Ücretsiz Komoot Photon API (OSM tabanlı)
    try {
      final photonUri = Uri.parse(
        'https://photon.komoot.io/api/?q=${Uri.encodeQueryComponent(cleaned)}&limit=$limit',
      );
      final resp = await http.get(photonUri).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final features = (data['features'] as List?) ?? [];
        final out = <AddressSuggestion>[];
        for (final f in features) {
          if (f is! Map<String, dynamic>) continue;
          final geom = f['geometry'] as Map<String, dynamic>?;
          final coords = (geom?['coordinates'] as List?) ?? [];
          final props = (f['properties'] as Map<String, dynamic>?) ?? {};
          if (coords.length >= 2) {
            final parts = [
              props['name'],
              props['street'],
              props['housenumber'],
              props['district'],
              props['city'] ?? props['state'],
              props['country'],
            ].where((e) => e != null && e.toString().trim().isNotEmpty).join(', ');
            if (parts.isNotEmpty) {
              out.add(
                AddressSuggestion(
                  displayName: parts,
                  lat: (coords[1] as num).toDouble(),
                  lng: (coords[0] as num).toDouble(),
                  source: 'photon',
                ),
              );
            }
          }
        }
        return out;
      }
    } catch (_) {}

    return [];
  }

  /// Kuryenin aktif siparişlerini, kuryenin anlık GPS konumunu (veya ilk durağı)
  /// başlangıç alarak En Yakın Komşu (Nearest-Neighbor / TSP) algoritmasıyla
  /// en verimli teslimat sırasına dizer.
  ///
  /// Her siparişe şu alanları yazar:
  /// - `stop_sequence`: 1, 2, 3...
  /// - `stop_label`: "1. Durak (En Yakın)", "2. Durak", "3. Durak"...
  /// - `distance_from_prev_km`: Önceki duraktan/kuryeden mesafe (km)
  static List<Map<String, dynamic>> optimizeOrdersNearestNeighbor(
    List<Map<String, dynamic>> orders, {
    LatLng? startPosition,
  }) {
    if (orders.isEmpty) return [];

    final remaining = orders.map((o) => Map<String, dynamic>.from(o)).toList();
    final optimized = <Map<String, dynamic>>[];

    LatLng currentPos;
    if (startPosition != null) {
      currentPos = startPosition;
    } else {
      final first = remaining.removeAt(0);
      final fLat = (first['dest_lat'] as num).toDouble();
      final fLng = (first['dest_lng'] as num).toDouble();
      currentPos = LatLng(fLat, fLng);
      first['stop_sequence'] = 1;
      first['stop_label'] = '1. Durak (En Yakın)';
      first['distance_from_prev_km'] = 0.0;
      optimized.add(first);
    }

    while (remaining.isNotEmpty) {
      int nearestIdx = 0;
      double nearestDist = double.infinity;

      for (int i = 0; i < remaining.length; i++) {
        final item = remaining[i];
        final lat = (item['dest_lat'] as num).toDouble();
        final lng = (item['dest_lng'] as num).toDouble();
        final dist = haversineKm(currentPos, LatLng(lat, lng));
        if (dist < nearestDist) {
          nearestDist = dist;
          nearestIdx = i;
        }
      }

      final chosen = remaining.removeAt(nearestIdx);
      final seq = optimized.length + 1;
      chosen['stop_sequence'] = seq;
      chosen['stop_label'] = seq == 1 ? '1. Durak (En Yakın)' : '$seq. Durak';
      chosen['distance_from_prev_km'] = double.parse(nearestDist.toStringAsFixed(2));
      optimized.add(chosen);

      currentPos = LatLng(
        (chosen['dest_lat'] as num).toDouble(),
        (chosen['dest_lng'] as num).toDouble(),
      );
    }

    return optimized;
  }

  /// Ücretsiz OSRM API (`https://router.project-osrm.org/route/v1/driving/...?overview=full&geometries=geojson`)
  /// kullanarak sıralanmış duraklar arasındaki gerçek karayolu rotasını (`Polyline`) getirir.
  static Future<OsrmRouteResult> fetchOsrmRoadRoute(List<LatLng> waypoints) async {
    if (waypoints.length < 2) {
      return OsrmRouteResult(
        polylinePoints: waypoints,
        totalDistanceKm: 0.0,
        totalDurationMinutes: 0.0,
        isOsrmRoadGeometry: false,
      );
    }

    final coordString = waypoints
        .map((pt) => '${pt.longitude.toStringAsFixed(6)},${pt.latitude.toStringAsFixed(6)}')
        .join(';');

    final osrmUri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/$coordString'
      '?overview=full&geometries=geojson',
    );

    try {
      final response = await http
          .get(
            osrmUri,
            headers: {
              'Accept': 'application/json',
              if (!kIsWeb) 'User-Agent': _userAgent,
            },
          )
          .timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final routes = (data['routes'] as List?) ?? [];
        if (routes.isNotEmpty) {
          final best = routes.first as Map<String, dynamic>;
          final geometry = best['geometry'] as Map<String, dynamic>?;
          final coords = (geometry?['coordinates'] as List?) ?? [];

          final points = <LatLng>[];
          for (final c in coords) {
            if (c is List && c.length >= 2) {
              final lng = (c[0] as num).toDouble();
              final lat = (c[1] as num).toDouble();
              points.add(LatLng(lat, lng));
            }
          }

          if (points.isNotEmpty) {
            final distKm = ((best['distance'] as num?)?.toDouble() ?? 0.0) / 1000.0;
            final durMin = ((best['duration'] as num?)?.toDouble() ?? 0.0) / 60.0;
            return OsrmRouteResult(
              polylinePoints: points,
              totalDistanceKm: double.parse(distKm.toStringAsFixed(2)),
              totalDurationMinutes: double.parse(durMin.toStringAsFixed(1)),
              isOsrmRoadGeometry: true,
            );
          }
        }
      }
    } catch (_) {}

    // Yedek: Kuş uçuşu durak bağlantısı
    double fallbackKm = 0.0;
    for (int i = 0; i < waypoints.length - 1; i++) {
      fallbackKm += haversineKm(waypoints[i], waypoints[i + 1]);
    }
    return OsrmRouteResult(
      polylinePoints: waypoints,
      totalDistanceKm: double.parse(fallbackKm.toStringAsFixed(2)),
      totalDurationMinutes: double.parse(((fallbackKm / 35.0) * 60.0).toStringAsFixed(1)),
      isOsrmRoadGeometry: false,
    );
  }
}
