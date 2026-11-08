import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// İşletmeye (Tenant) özel White-Label marka ve raporlama modeli.
class TenantBranding {
  final String id;
  final String name;
  final String slug;
  final String? logoUrl;
  final String primaryColorHex;
  final String reportEmail;
  final String? phone;

  const TenantBranding({
    required this.id,
    required this.name,
    required this.slug,
    this.logoUrl,
    this.primaryColorHex = '#1E40AF',
    this.reportEmail = '',
    this.phone,
  });

  factory TenantBranding.defaultTheme() {
    return const TenantBranding(
      id: '',
      name: 'Teslimat & PoD Yönetim Sistemi',
      slug: 'default',
      primaryColorHex: '#1E40AF',
      reportEmail: '',
    );
  }

  factory TenantBranding.fromJson(Map<String, dynamic> json) {
    return TenantBranding(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? json['tenant_name'] ?? 'Teslimat Sistemi')
          .toString(),
      slug: (json['slug'] ?? '').toString(),
      logoUrl: json['logo_url']?.toString(),
      primaryColorHex: (json['primary_color'] ?? '#1E40AF').toString(),
      reportEmail: (json['report_email'] ?? '').toString(),
      phone: json['phone']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'slug': slug,
        'logo_url': logoUrl,
        'primary_color': primaryColorHex,
        'report_email': reportEmail,
        'phone': phone,
      };

  Color get primaryColor => parseHexColor(primaryColorHex);

  static Color parseHexColor(
    String hexString, {
    Color fallback = const Color(0xFF1E40AF),
  }) {
    final cleaned = hexString.trim().replaceAll('#', '');
    if (cleaned.length == 6) {
      final val = int.tryParse('FF$cleaned', radix: 16);
      if (val != null) return Color(val);
    } else if (cleaned.length == 8) {
      final val = int.tryParse(cleaned, radix: 16);
      if (val != null) return Color(val);
    }
    return fallback;
  }
}

/// Giriş yapan işletmenin veya müşteri takip bağlantısındaki işletmenin
/// adını, logosunu ve ana rengini tüm uygulamada dinamik değiştiren denetleyici.
class TenantThemeController extends ChangeNotifier {
  TenantBranding _branding = TenantBranding.defaultTheme();

  TenantBranding get branding => _branding;
  Color get primaryColor => _branding.primaryColor;

  void applyTenantBranding(TenantBranding newBranding) {
    _branding = newBranding;
    notifyListeners();
  }

  void applyFromMap(Map<String, dynamic> json) {
    _branding = TenantBranding.fromJson(json);
    notifyListeners();
  }

  void resetToDefault() {
    _branding = TenantBranding.defaultTheme();
    notifyListeners();
  }

  ThemeData buildThemeData() {
    final seed = _branding.primaryColor;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      primary: seed,
      brightness: Brightness.light,
    );

    final baseTextTheme = GoogleFonts.poppinsTextTheme();

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: baseTextTheme,
      scaffoldBackgroundColor: const Color(0xFFF1F5F9),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: ZoomPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.macOS: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: seed,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 17.5,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: seed,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFCBD5E1),
          disabledForegroundColor: const Color(0xFF64748B),
          elevation: 3,
          shadowColor: seed.withValues(alpha: 0.35),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: GoogleFonts.poppins(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 3,
        shadowColor: const Color(0xFF0F172A).withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
    );
  }
}

/// Yönetici, Kurye ve Müşteri Geçici Takip ekranlarının üst kısmında
/// işletmenin kendi logosunu ve adını modern SaaS gradyanıyla gösteren White-Label AppBar bileşeni.
class WhiteLabelAppBar extends StatelessWidget implements PreferredSizeWidget {
  final TenantBranding branding;
  final String? subtitle;
  final List<Widget>? actions;

  const WhiteLabelAppBar({
    super.key,
    required this.branding,
    this.subtitle,
    this.actions,
  });

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final hasLogo =
        branding.logoUrl != null && branding.logoUrl!.trim().isNotEmpty;
    final darkShade = Color.lerp(branding.primaryColor, Colors.black, 0.28)!;
    final accentShade =
        Color.lerp(branding.primaryColor, const Color(0xFF4F46E5), 0.35)!;

    return AppBar(
      flexibleSpace: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              darkShade,
              branding.primaryColor,
              accentShade,
            ],
          ),
        ),
      ),
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      title: Row(
        children: [
          if (hasLogo)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  branding.logoUrl!,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildFallbackAvatar(),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _buildFallbackAvatar(),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  branding.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.2,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: actions,
    );
  }

  Widget _buildFallbackAvatar() {
    final initial = branding.name.trim().isNotEmpty
        ? branding.name.trim().substring(0, 1).toUpperCase()
        : 'T';
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.28),
            Colors.white.withValues(alpha: 0.12),
          ],
        ),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.white38, width: 1.2),
      ),
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 18,
        ),
      ),
    );
  }
}
