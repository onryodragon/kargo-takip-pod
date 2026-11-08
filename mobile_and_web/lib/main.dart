import 'package:flutter/material.dart';

import 'core/api/api_client.dart';
import 'core/services/location_service.dart';
import 'core/theme/tenant_theme.dart';
import 'core/widgets/animated_saas_widgets.dart';
import 'features/admin/admin_dashboard_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/auth/driver_invite_register_screen.dart';
import 'features/auth/whatsapp_link_gate_screen.dart';
import 'features/customer_tracking/customer_tracking_screen.dart';
import 'features/driver/driver_home_screen.dart';
import 'features/driver/driver_permission_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themeController = TenantThemeController();
  final apiClient = ApiClient(themeController: themeController);
  final locationService = GmsFreeLocationService(apiClient: apiClient);

  await apiClient.restoreSession();

  // URL üzerinden geçici müşteri takip token'ı (/track/:token) veya kurye davet token'ı (/driver-invite/:token) kontrolü
  final initialTrackingToken = _extractTrackingTokenFromUri(Uri.base);
  final initialDriverInviteToken = _extractDriverInviteTokenFromUri(Uri.base);

  runApp(
    MultiTenantDeliveryApp(
      themeController: themeController,
      apiClient: apiClient,
      locationService: locationService,
      initialTrackingToken: initialTrackingToken,
      initialDriverInviteToken: initialDriverInviteToken,
    ),
  );
}

/// Web URL'sinden (`/track/TOKEN`, `#/track/TOKEN` veya `?track=TOKEN`)
/// geçici müşteri takip anahtarını yakalar.
String? _extractTrackingTokenFromUri(Uri uri) {
  final queryToken =
      uri.queryParameters['track'] ?? uri.queryParameters['token'];
  if (queryToken != null && queryToken.trim().isNotEmpty) {
    return queryToken.trim();
  }

  final segments = uri.pathSegments;
  final trackIdx = segments.indexOf('track');
  if (trackIdx != -1 && trackIdx + 1 < segments.length) {
    final token = segments[trackIdx + 1].trim();
    if (token.isNotEmpty) return token;
  }

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

/// Web URL'sinden (`/driver-invite/TOKEN`, `#/driver-invite/TOKEN` veya `?driver_invite=TOKEN`)
/// WhatsApp kurye davetiye anahtarını yakalar.
String? _extractDriverInviteTokenFromUri(Uri uri) {
  final queryInvite = uri.queryParameters['driver_invite'] ??
      uri.queryParameters['invite_token'];
  if (queryInvite != null && queryInvite.trim().isNotEmpty) {
    return queryInvite.trim();
  }

  final segments = uri.pathSegments;
  final invIdx = segments.indexOf('driver-invite');
  if (invIdx != -1 && invIdx + 1 < segments.length) {
    final token = segments[invIdx + 1].trim();
    if (token.isNotEmpty) return token;
  }

  if (uri.fragment.isNotEmpty) {
    final fragUri = Uri.tryParse(uri.fragment);
    if (fragUri != null) {
      final fragQuery = fragUri.queryParameters['driver_invite'];
      if (fragQuery != null && fragQuery.trim().isNotEmpty) {
        return fragQuery.trim();
      }
      final fragSegments = fragUri.pathSegments;
      final fragIdx = fragSegments.indexOf('driver-invite');
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
  final String? initialDriverInviteToken;

  const MultiTenantDeliveryApp({
    super.key,
    required this.themeController,
    required this.apiClient,
    required this.locationService,
    this.initialTrackingToken,
    this.initialDriverInviteToken,
  });

  @override
  State<MultiTenantDeliveryApp> createState() => _MultiTenantDeliveryAppState();
}

class _MultiTenantDeliveryAppState extends State<MultiTenantDeliveryApp> {
  String? _pendingInviteToken;

  @override
  void initState() {
    super.initState();
    _pendingInviteToken = widget.initialDriverInviteToken;
  }

  void _refreshAuthState() {
    if (mounted) {
      setState(() {
        if (widget.apiClient.isAuthenticated) {
          _pendingInviteToken = null;
        }
      });
    }
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
                final trackToken = _extractTrackingTokenFromUri(parsed);
                if (trackToken != null) {
                  return createSmoothPageRoute(
                    CustomerTrackingScreen(
                      apiClient: widget.apiClient,
                      trackingToken: trackToken,
                    ),
                    settings: routeSettings,
                  );
                }

                final inviteToken = _extractDriverInviteTokenFromUri(parsed);
                if (inviteToken != null && !widget.apiClient.isAuthenticated) {
                  return createSmoothPageRoute(
                    DriverInviteRegisterScreen(
                      apiClient: widget.apiClient,
                      initialInviteToken: inviteToken,
                      onRegistered: _refreshAuthState,
                    ),
                    settings: routeSettings,
                  );
                }
              }
            }
            return createSmoothPageRoute(
              _buildHomeScreen(),
              settings: routeSettings,
            );
          },
          home: AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: _buildHomeScreen(),
          ),
        );
      },
    );
  }

  Widget _buildHomeScreen() {
    // 1. KURAL: Eğer URL'de `/track/:token` varsa GİRİŞ EKRANI SORMADAN doğrudan müşteri takip ekranını aç!
    if (widget.initialTrackingToken != null &&
        widget.initialTrackingToken!.isNotEmpty) {
      return CustomerTrackingScreen(
        apiClient: widget.apiClient,
        trackingToken: widget.initialTrackingToken!,
      );
    }

    // 2. KURAL: Eğer URL'de `/driver-invite/:token` varsa ve oturum açık değilse doğrudan Kurye Davetiye Kayıt ekranını aç!
    if (!widget.apiClient.isAuthenticated &&
        _pendingInviteToken != null &&
        _pendingInviteToken!.isNotEmpty) {
      return DriverInviteRegisterScreen(
        apiClient: widget.apiClient,
        initialInviteToken: _pendingInviteToken,
        onRegistered: _refreshAuthState,
      );
    }

    // 3. KURAL: Oturum açık değilse Giriş / Yeni İşletme Kayıt ekranını göster
    if (!widget.apiClient.isAuthenticated) {
      return AuthScreen(
        apiClient: widget.apiClient,
        onAuthenticated: _refreshAuthState,
      );
    }

    // 4. KURAL: Hem Yönetici hem Kurye için Zorunlu WhatsApp Bağlama ve Doğrulama Kapısı
    if (!widget.apiClient.isWhatsappVerified) {
      return WhatsAppLinkGateScreen(
        apiClient: widget.apiClient,
        onVerified: _refreshAuthState,
      );
    }

    // 5. KURAL: Rol 'admin' ise Yönetici 24 Saatlik Operasyon Paneli
    if (widget.apiClient.userRole == 'admin') {
      return AdminDashboardScreen(
        apiClient: widget.apiClient,
        onLogout: _handleLogout,
      );
    }

    // 6. KURAL: Rol 'driver' ise Zorunlu Konum + Pil Optimizasyonu İzin Kapısı ardından Kurye Ekranı
    return DriverPermissionGate(
      child: DriverHomeScreen(
        apiClient: widget.apiClient,
        locationService: widget.locationService,
        onLogout: _handleLogout,
      ),
    );
  }
}
