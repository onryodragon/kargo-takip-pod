import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/tenant_theme.dart';

/// FastAPI Backend ile haberleşen, JWT oturumunu yöneten ve
/// MultipartRequest ile Fotoğraf + İmza yükleyen merkezi istemci.
class ApiClient {
  static const String _prefTokenKey = 'pod_access_token';
  static const String _prefUserKey = 'pod_current_user';
  static const String _prefTenantKey = 'pod_current_tenant';
  static const String _prefBaseUrlKey = 'pod_custom_api_base_url';

  /// Canlı Render Bulut Sunucu Adresleri (4.5G Mobil & Web)
  static const String defaultApiBaseUrl = 'https://kargo-takip-pod.onrender.com';
  static const String defaultWsBaseUrl = 'wss://kargo-takip-pod.onrender.com';
  static const String baseWebUrl = 'https://kargo-takip-pod.onrender.com';

  static String? _customBaseUrl;

  /// Varsayılan olarak canlı Render sunucusunu (`https://kargo-takip-pod.onrender.com`) kullanır.
  static String get baseUrl {
    if (_customBaseUrl != null && _customBaseUrl!.trim().isNotEmpty) {
      return _customBaseUrl!.trim().replaceAll(RegExp(r'/+$'), '');
    }
    const envUrl = String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: defaultApiBaseUrl,
    );
    return envUrl.replaceAll(RegExp(r'/+$'), '');
  }

  static Future<void> setCustomBaseUrl(String url) async {
    final cleaned = url.trim().replaceAll(RegExp(r'/+$'), '');
    _customBaseUrl = cleaned.isEmpty ? null : cleaned;
    final prefs = await SharedPreferences.getInstance();
    if (_customBaseUrl == null) {
      await prefs.remove(_prefBaseUrlKey);
    } else {
      await prefs.setString(_prefBaseUrlKey, _customBaseUrl!);
    }
  }

  final TenantThemeController themeController;

  String? _accessToken;
  Map<String, dynamic>? _currentUser;
  TenantBranding? _currentTenant;

  ApiClient({required this.themeController});

  String? get accessToken => _accessToken;
  Map<String, dynamic>? get currentUser => _currentUser;
  TenantBranding? get currentTenant => _currentTenant;
  bool get isAuthenticated => _accessToken != null && _accessToken!.isNotEmpty;
  String? get userRole => _currentUser?['role']?.toString();
  String get userFullName => (_currentUser?['full_name'] ?? '').toString();

  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  // ---------------------------------------------------------------------------
  // OTURUM YÜKLEME VE KAYDETME (SHARED PREFERENCES)
  // ---------------------------------------------------------------------------
  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _customBaseUrl = prefs.getString(_prefBaseUrlKey);
    _accessToken = prefs.getString(_prefTokenKey);
    final userRaw = prefs.getString(_prefUserKey);
    final tenantRaw = prefs.getString(_prefTenantKey);

    if (userRaw != null && userRaw.isNotEmpty) {
      _currentUser = jsonDecode(userRaw) as Map<String, dynamic>;
    }
    if (tenantRaw != null && tenantRaw.isNotEmpty) {
      final map = jsonDecode(tenantRaw) as Map<String, dynamic>;
      _currentTenant = TenantBranding.fromJson(map);
      themeController.applyTenantBranding(_currentTenant!);
    }
  }

  Future<void> _persistSession({
    required String token,
    required Map<String, dynamic> user,
    required Map<String, dynamic> tenant,
  }) async {
    _accessToken = token;
    _currentUser = user;
    _currentTenant = TenantBranding.fromJson(tenant);
    themeController.applyTenantBranding(_currentTenant!);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTokenKey, token);
    await prefs.setString(_prefUserKey, jsonEncode(user));
    await prefs.setString(_prefTenantKey, jsonEncode(tenant));
  }

  Future<void> logout() async {
    _accessToken = null;
    _currentUser = null;
    _currentTenant = null;
    themeController.resetToDefault();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefTokenKey);
    await prefs.remove(_prefUserKey);
    await prefs.remove(_prefTenantKey);
  }

  // ---------------------------------------------------------------------------
  // 1. İŞLETME (TENANTS) VE KULLANICI GİRİŞ UÇ NOKTALARI
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> registerTenant({
    required String name,
    required String slug,
    required String reportEmail,
    String? logoUrl,
    String primaryColor = '#1E40AF',
    String? phone,
    required String adminFullName,
    required String adminEmail,
    required String adminPhone,
    required String adminPassword,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/tenants/register');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'slug': slug,
        'report_email': reportEmail,
        'logo_url': (logoUrl != null && logoUrl.trim().isNotEmpty) ? logoUrl.trim() : null,
        'primary_color': primaryColor,
        'phone': phone,
        'admin_full_name': adminFullName,
        'admin_email': adminEmail,
        'admin_phone': adminPhone,
        'admin_password': adminPassword,
      }),
    );

    final body = _decodeResponse(response);
    await _persistSession(
      token: body['access_token'] as String,
      user: body['user'] as Map<String, dynamic>,
      tenant: body['tenant'] as Map<String, dynamic>,
    );
    return body;
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/tenants/login');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
      }),
    );

    final body = _decodeResponse(response);
    await _persistSession(
      token: body['access_token'] as String,
      user: body['user'] as Map<String, dynamic>,
      tenant: body['tenant'] as Map<String, dynamic>,
    );
    return body;
  }

  Future<TenantBranding> updateMyTenant({
    String? name,
    String? logoUrl,
    String? reportEmail,
    String? primaryColor,
    String? phone,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/tenants/me');
    final payload = <String, dynamic>{
      if (name != null) 'name': name,
      if (logoUrl != null) 'logo_url': logoUrl,
      if (reportEmail != null) 'report_email': reportEmail,
      if (primaryColor != null) 'primary_color': primaryColor,
      if (phone != null) 'phone': phone,
    };

    final response = await http.patch(
      uri,
      headers: _authHeaders,
      body: jsonEncode(payload),
    );
    final updatedMap = _decodeResponse(response);
    _currentTenant = TenantBranding.fromJson(updatedMap);
    themeController.applyTenantBranding(_currentTenant!);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTenantKey, jsonEncode(updatedMap));
    return _currentTenant!;
  }

  Future<Map<String, dynamic>> createDriver({
    required String fullName,
    required String email,
    required String phone,
    required String password,
    required String vehiclePlate,
    String vehicleType = 'Motosiklet',
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/tenants/drivers');
    final response = await http.post(
      uri,
      headers: _authHeaders,
      body: jsonEncode({
        'full_name': fullName,
        'email': email,
        'phone': phone,
        'password': password,
        'vehicle_plate': vehiclePlate,
        'vehicle_type': vehicleType,
      }),
    );
    return _decodeResponse(response);
  }

  Future<List<Map<String, dynamic>>> listDrivers() async {
    final uri = Uri.parse('$baseUrl/api/v1/tenants/drivers');
    final response = await http.get(uri, headers: _authHeaders);
    final list = _decodeListResponse(response);
    return list.cast<Map<String, dynamic>>();
  }

  // ---------------------------------------------------------------------------
  // 2. SİPARİŞLER, ATAMA, 24 SAATLİK HARİTA VE ZORUNLU PoD
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> createOrder({
    String? orderNumber,
    required String customerName,
    required String customerPhone,
    required String deliveryAddress,
    String? deliveryNotes,
    required double destLat,
    required double destLng,
    String? assignedDriverId,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/orders');
    final response = await http.post(
      uri,
      headers: _authHeaders,
      body: jsonEncode({
        if (orderNumber != null && orderNumber.trim().isNotEmpty)
          'order_number': orderNumber.trim(),
        'customer_name': customerName,
        'customer_phone': customerPhone,
        'delivery_address': deliveryAddress,
        'delivery_notes': deliveryNotes,
        'dest_lat': destLat,
        'dest_lng': destLng,
        'assigned_driver_id': assignedDriverId,
      }),
    );
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> updateOrderAssignment({
    required String orderId,
    String? assignedDriverId,
    String? deliveryAddress,
    double? destLat,
    double? destLng,
    String? status,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/orders/$orderId/assign');
    final response = await http.patch(
      uri,
      headers: _authHeaders,
      body: jsonEncode({
        if (assignedDriverId != null) 'assigned_driver_id': assignedDriverId,
        if (deliveryAddress != null) 'delivery_address': deliveryAddress,
        if (destLat != null) 'dest_lat': destLat,
        if (destLng != null) 'dest_lng': destLng,
        if (status != null) 'status': status,
      }),
    );
    return _decodeResponse(response);
  }

  /// Yönetici 24 Saatlik Canlı Harita verisi (`vw_admin_map_orders`)
  Future<List<Map<String, dynamic>>> getAdminMapOrders() async {
    final uri = Uri.parse('$baseUrl/api/v1/orders/admin-map');
    final response = await http.get(uri, headers: _authHeaders);
    final list = _decodeListResponse(response);
    return list.cast<Map<String, dynamic>>();
  }

  /// Kurye Salt-Okunur Sipariş Listesi
  Future<List<Map<String, dynamic>>> getDriverAssignedOrders() async {
    final uri = Uri.parse('$baseUrl/api/v1/orders/driver/my-orders');
    final response = await http.get(uri, headers: _authHeaders);
    final list = _decodeListResponse(response);
    return list.cast<Map<String, dynamic>>();
  }

  /// Zorunlu Fotoğraf + İmza ile Teslimat Tamamlama (`MultipartRequest` + Base64 yedekli)
  Future<Map<String, dynamic>> deliverOrderWithPoD({
    required String orderId,
    required String recipientName,
    required double deliveredLat,
    required double deliveredLng,
    required Uint8List photoBytes,
    required Uint8List signaturePngBytes,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/orders/$orderId/deliver');

    // MultipartRequest ile hem fotoğraf hem imzayı binary dosya olarak gönder
    final request = http.MultipartRequest('POST', uri);
    if (_accessToken != null) {
      request.headers['Authorization'] = 'Bearer $_accessToken';
    }

    request.fields['recipient_name'] = recipientName.trim();
    request.fields['delivered_lat'] = deliveredLat.toString();
    request.fields['delivered_lng'] = deliveredLng.toString();

    request.files.add(
      http.MultipartFile.fromBytes(
        'pod_photo',
        photoBytes,
        filename: 'pod_photo_${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );
    request.files.add(
      http.MultipartFile.fromBytes(
        'pod_signature',
        signaturePngBytes,
        filename: 'pod_signature_${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    // Eğer sunucuda python-multipart yoksa otomatik olarak JSON Base64 ile gönder
    if (response.statusCode == 500 || response.statusCode == 400) {
      final jsonResponse = await http.post(
        uri,
        headers: _authHeaders,
        body: jsonEncode({
          'recipient_name': recipientName.trim(),
          'delivered_lat': deliveredLat,
          'delivered_lng': deliveredLng,
          'pod_photo': 'data:image/png;base64,${base64Encode(photoBytes)}',
          'pod_signature': 'data:image/png;base64,${base64Encode(signaturePngBytes)}',
        }),
      );
      return _decodeResponse(jsonResponse);
    }

    return _decodeResponse(response);
  }

  // ---------------------------------------------------------------------------
  // 3. CANLI KONUM VE MÜŞTERİ WHITE-LABEL TAKİP LİNKİ
  // ---------------------------------------------------------------------------
  Future<void> sendDriverLiveLocation({
    required double lat,
    required double lng,
    double speed = 0.0,
    double heading = 0.0,
    double? accuracy,
    int? batteryLevel,
    String? orderId,
  }) async {
    if (!isAuthenticated) return;
    final uri = Uri.parse('$baseUrl/api/v1/tracking/location');
    await http.post(
      uri,
      headers: _authHeaders,
      body: jsonEncode({
        'lat': lat,
        'lng': lng,
        'speed': speed,
        'heading': heading,
        if (accuracy != null) 'accuracy': accuracy,
        if (batteryLevel != null) 'battery_level': batteryLevel,
        if (orderId != null) 'order_id': orderId,
      }),
    );
  }

  Future<Map<String, dynamic>> getPublicTrackingInfo(String trackingToken) async {
    final uri = Uri.parse('$baseUrl/api/v1/tracking/public/$trackingToken');
    final response = await http.get(uri);
    return _decodeResponse(response);
  }

  String buildTrackingWebSocketUrl(String trackingToken) {
    if (_customBaseUrl != null && _customBaseUrl!.trim().isNotEmpty) {
      final wsCustom = _customBaseUrl!
          .trim()
          .replaceAll(RegExp(r'/+$'), '')
          .replaceFirst('https://', 'wss://')
          .replaceFirst('http://', 'ws://');
      return '$wsCustom/api/v1/tracking/ws/$trackingToken';
    }
    return '$defaultWsBaseUrl/api/v1/tracking/ws/$trackingToken';
  }

  /// Yönetici ve Kurye ekranından müşteriye WhatsApp/SMS ile gönderilecek White-Label takip linki
  String buildCustomerShareableTrackingUrl(String trackingToken) {
    return '$baseWebUrl/#/track/$trackingToken';
  }

  // ---------------------------------------------------------------------------
  // YARDIMCI CEVAP ÇÖZÜMLEYİCİLER
  // ---------------------------------------------------------------------------
  Map<String, dynamic> _decodeResponse(http.Response response) {
    final text = utf8.decode(response.bodyBytes);
    final dynamic decoded = text.isNotEmpty ? jsonDecode(text) : <String, dynamic>{};

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
    }

    final detail = (decoded is Map && decoded['detail'] != null)
        ? decoded['detail'].toString()
        : 'Sunucu hatası (${response.statusCode})';
    throw ApiException(statusCode: response.statusCode, message: detail);
  }

  List<dynamic> _decodeListResponse(http.Response response) {
    final text = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return text.isNotEmpty ? (jsonDecode(text) as List<dynamic>) : <dynamic>[];
    }
    final dynamic decoded = text.isNotEmpty ? jsonDecode(text) : {};
    final detail = (decoded is Map && decoded['detail'] != null)
        ? decoded['detail'].toString()
        : 'Sunucu hatası (${response.statusCode})';
    throw ApiException(statusCode: response.statusCode, message: detail);
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException({required this.statusCode, required this.message});

  @override
  String toString() => message;
}
