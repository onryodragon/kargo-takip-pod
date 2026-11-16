import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/api/api_client.dart';
import 'core/l10n/app_localizations.dart';
import 'core/l10n/language_provider.dart';
import 'core/services/location_service.dart';
import 'core/theme/tenant_theme.dart';
import 'core/widgets/animated_saas_widgets.dart';
import 'core/widgets/first_launch_privacy_gate.dart';
import 'features/admin/admin_dashboard_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/auth/driver_invite_register_screen.dart';
import 'features/auth/whatsapp_link_gate_screen.dart';
import 'features/customer_tracking/customer_tracking_screen.dart';
import 'features/driver/driver_home_screen.dart';
import 'features/driver/driver_permission_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // URL üzerinden gelen özel işletme sunucu adresi (?api=https://... veya ?server=https://...)
  final initialApiUrl = _extractApiUrlFromUri(Uri.base);
  if (initialApiUrl != null &&
      (initialApiUrl.startsWith('http://') || initialApiUrl.startsWith('https://'))) {
    await ApiClient.setCustomBaseUrl(initialApiUrl);
  } else if (kIsWeb) {
    // Web ortamında işletmenin kendi Render/özel sunucusundan açılıyorsa origin'i otomatik eşle
    final origin = Uri.base.origin;
    if (origin.startsWith('http://') || origin.startsWith('https://')) {
      if (!origin.contains('localhost') && !origin.contains('127.0.0.1')) {
        final prefs = await SharedPreferences.getInstance();
        final savedUrl = prefs.getString('custom_api_base_url');
        if (savedUrl == null || savedUrl.isEmpty) {
          await ApiClient.setCustomBaseUrl(origin);
        }
      }
    }
  }

  final themeController = TenantThemeController();
  final apiClient = ApiClient(themeController: themeController);
  final locationService = GmsFreeLocationService(apiClient: apiClient);
  final languageProvider = LanguageProvider();

  await apiClient.restoreSession();
  await languageProvider.initialize();

  // URL üzerinden geçici müşteri takip token'ı (/track/:token) veya kurye davet token'ı (/driver-invite/:token) kontrolü
  final initialTrackingToken = _extractTrackingTokenFromUri(Uri.base);
  final initialDriverInviteToken = _extractDriverInviteTokenFromUri(Uri.base);

  runApp(
    MultiTenantDeliveryApp(
      themeController: themeController,
      apiClient: apiClient,
      locationService: locationService,
      languageProvider: languageProvider,
      initialTrackingToken: initialTrackingToken,
      initialDriverInviteToken: initialDriverInviteToken,
    ),
  );
}

/// Web URL'sinden (`?api=https://...` veya `?server=https://...`)
/// işletmenin özel sunucu adresini yakalar.
String? _extractApiUrlFromUri(Uri uri) {
  final queryApi = uri.queryParameters['api'] ?? uri.queryParameters['server'];
  if (queryApi != null && queryApi.trim().isNotEmpty) {
    return queryApi.trim();
  }
  if (uri.fragment.isNotEmpty) {
    final fragUri = Uri.tryParse(uri.fragment);
    if (fragUri != null) {
      final fragApi = fragUri.queryParameters['api'] ?? fragUri.queryParameters['server'];
      if (fragApi != null && fragApi.trim().isNotEmpty) {
        return fragApi.trim();
      }
    }
  }
  return null;
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
  final LanguageProvider languageProvider;
  final String? initialTrackingToken;
  final String? initialDriverInviteToken;

  const MultiTenantDeliveryApp({
    super.key,
    required this.themeController,
    required this.apiClient,
    required this.locationService,
    required this.languageProvider,
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
    return LanguageScope(
      provider: widget.languageProvider,
      child: AnimatedBuilder(
        animation: Listenable.merge([widget.themeController, widget.languageProvider]),
        builder: (context, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: widget.themeController.branding.name,
            theme: widget.themeController.buildThemeData(),
            locale: widget.languageProvider.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
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
                        languageProvider: widget.languageProvider,
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
            home: FirstLaunchPrivacyGate(
              languageProvider: widget.languageProvider,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _buildHomeScreen(),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHomeScreen() {
    // 1. KURAL: Eğer URL'de `/track/:token` varsa GİRİŞ EKRANI SORMADAN doğrudan müşteri takip ekranını aç!
    if (widget.initialTrackingToken != null &&
        widget.initialTrackingToken!.isNotEmpty) {
      return CustomerTrackingScreen(
        apiClient: widget.apiClient,
        trackingToken: widget.initialTrackingToken!,
        languageProvider: widget.languageProvider,
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
        languageProvider: widget.languageProvider,
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
        languageProvider: widget.languageProvider,
      );
    }

    // 6. KURAL: Rol 'driver' ise Zorunlu Konum + Pil Optimizasyonu İzin Kapısı ardından Kurye Ekranı
    return DriverPermissionGate(
      child: DriverHomeScreen(
        apiClient: widget.apiClient,
        locationService: widget.locationService,
        onLogout: _handleLogout,
        languageProvider: widget.languageProvider,
      ),
    );
  }
}
