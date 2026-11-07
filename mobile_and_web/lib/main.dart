import 'package:flutter/material.dart';

import 'core/api/api_client.dart';
import 'core/services/location_service.dart';
import 'core/theme/tenant_theme.dart';
import 'features/admin/admin_dashboard_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/customer_tracking/customer_tracking_screen.dart';
import 'features/driver/driver_home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themeController = TenantThemeController();
  final apiClient = ApiClient(themeController: themeController);
  final locationService = GmsFreeLocationService(apiClient: apiClient);

  await apiClient.restoreSession();

  // URL üzerinden geçici müşteri takip token'ı (/track/:token veya ?track=TOKEN) kontrolü
  final initialTrackingToken = _extractTrackingTokenFromUri(Uri.base);

  runApp(
    MultiTenantDeliveryApp(
      themeController: themeController,
      apiClient: apiClient,
      locationService: locationService,
      initialTrackingToken: initialTrackingToken,
    ),
  );
}

/// Web URL'sinden (`/track/TOKEN`, `#/track/TOKEN` veya `?track=TOKEN`)
/// geçici müşteri takip anahtarını yakalar.
String? _extractTrackingTokenFromUri(Uri uri) {
  // 1) Query parametresi: ?track=TOKEN
  final queryToken = uri.queryParameters['track'] ?? uri.queryParameters['token'];
  if (queryToken != null && queryToken.trim().isNotEmpty) {
    return queryToken.trim();
  }

  // 2) Path segmenti: /track/TOKEN
  final segments = uri.pathSegments;
  final trackIdx = segments.indexOf('track');
  if (trackIdx != -1 && trackIdx + 1 < segments.length) {
    final token = segments[trackIdx + 1].trim();
    if (token.isNotEmpty) return token;
  }

  // 3) Hash fragment: #/track/TOKEN
  if (uri.fragment.isNotEmpty) {
    final fragUri = Uri.tryParse(uri.fragment);
    if (fragUri != null) {
      final fragQuery = fragUri.queryParameters['track'];
      if (fragQuery != null && fragQuery.trim().isNotEmpty) {
        return fragQuery.trim();
      }
      final fragSegments = fragUri.pathSegments;
      final fragIdx = fragSegments.indexOf('track');
      if (fragIdx != -1 && fragIdx + 1 < fragSegments.length) {
        final token = fragSegments[fragIdx + 1].trim();
        if (token.isNotEmpty) return token;
      }
    }
  }

  return null;
}

class MultiTenantDeliveryApp extends StatefulWidget {
  final TenantThemeController themeController;
  final ApiClient apiClient;
  final GmsFreeLocationService locationService;
  final String? initialTrackingToken;

  const MultiTenantDeliveryApp({
    super.key,
    required this.themeController,
    required this.apiClient,
    required this.locationService,
    this.initialTrackingToken,
  });

  @override
  State<MultiTenantDeliveryApp> createState() => _MultiTenantDeliveryAppState();
}

class _MultiTenantDeliveryAppState extends State<MultiTenantDeliveryApp> {
  void _refreshAuthState() {
    if (mounted) setState(() {});
  }

  Future<void> _handleLogout() async {
    await widget.locationService.stopLiveTracking();
    await widget.apiClient.logout();
    _refreshAuthState();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.themeController,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: widget.themeController.branding.name,
          theme: widget.themeController.buildThemeData(),
          onGenerateRoute: (RouteSettings routeSettings) {
            final routeName = routeSettings.name ?? '';
            if (routeName.isNotEmpty) {
              final parsed = Uri.tryParse(routeName);
              if (parsed != null) {
                final token = _extractTrackingTokenFromUri(parsed);
                if (token != null) {
                  return MaterialPageRoute(
                    settings: routeSettings,
                    builder: (_) => CustomerTrackingScreen(
                      apiClient: widget.apiClient,
                      trackingToken: token,
                    ),
                  );
                }
              }
            }
            return MaterialPageRoute(
              settings: routeSettings,
              builder: (_) => _buildHomeScreen(),
            );
          },
          home: _buildHomeScreen(),
        );
      },
    );
  }

  Widget _buildHomeScreen() {
    // 1. KURAL: Eğer URL'de `/track/:token` varsa GİRİŞ EKRANI SORMADAN doğrudan müşteri takip ekranını aç!
    if (widget.initialTrackingToken != null && widget.initialTrackingToken!.isNotEmpty) {
      return CustomerTrackingScreen(
        apiClient: widget.apiClient,
        trackingToken: widget.initialTrackingToken!,
      );
    }

    // 2. KURAL: Oturum açık değilse Giriş / Yeni İşletme Kayıt ekranını göster
    if (!widget.apiClient.isAuthenticated) {
      return AuthScreen(
        apiClient: widget.apiClient,
        onAuthenticated: _refreshAuthState,
      );
    }

    // 3. KURAL: Rol 'admin' ise Yönetici 24 Saatlik Operasyon Paneli, 'driver' ise Kurye Ekranı
    if (widget.apiClient.userRole == 'admin') {
      return AdminDashboardScreen(
        apiClient: widget.apiClient,
        onLogout: _handleLogout,
      );
    }

    return DriverHomeScreen(
      apiClient: widget.apiClient,
      locationService: widget.locationService,
      onLogout: _handleLogout,
    );
  }
}
