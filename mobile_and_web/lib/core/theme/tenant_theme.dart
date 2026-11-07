import 'package:flutter/material.dart';

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
      name: (json['name'] ?? json['tenant_name'] ?? 'Teslimat Sistemi').toString(),
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

  static Color parseHexColor(String hexString, {Color fallback = const Color(0xFF1E40AF)}) {
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

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      appBarTheme: AppBarTheme(
        backgroundColor: seed,
        foregroundColor: Colors.white,
        elevation: 2,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          fontSize: 18,
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
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

/// Yönetici, Kurye ve Müşteri Geçici Takip ekranlarının üst kısmında
/// işletmenin kendi logosunu ve adını gösteren White-Label AppBar bileşeni.
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
  Size get preferredSize => const Size.fromHeight(62);

  @override
  Widget build(BuildContext context) {
    final hasLogo = branding.logoUrl != null && branding.logoUrl!.trim().isNotEmpty;

    return AppBar(
      backgroundColor: branding.primaryColor,
      foregroundColor: Colors.white,
      title: Row(
        children: [
          if (hasLogo)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  branding.logoUrl!,
                  width: 38,
                  height: 38,
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
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                      fontWeight: FontWeight.w400,
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
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white38),
      ),
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    );
  }
}
