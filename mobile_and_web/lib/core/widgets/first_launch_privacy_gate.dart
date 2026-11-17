import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../l10n/app_localizations.dart';
import '../l10n/language_provider.dart';
import '../l10n/language_selector_button.dart';

/// Huawei AppGallery Zorunlu: İlk Açılış Gizlilik Politikası ve KVKK Onay Kapısı.
///
/// Uygulama ilk kez açıldığında, hiçbir hassas izin (Konum, Kamera vb.) istenmeden
/// ve hiçbir izleme/veri toplama başlamadan önce kullanıcıya sunulur.
/// Kullanıcı "Kabul Et ve Devam Et" butonuna basana kadar uygulama ana ekranlarına geçilemez.
class FirstLaunchPrivacyGate extends StatefulWidget {
  final Widget child;
  final LanguageProvider? languageProvider;

  const FirstLaunchPrivacyGate({
    super.key,
    required this.child,
    this.languageProvider,
  });

  @override
  State<FirstLaunchPrivacyGate> createState() => _FirstLaunchPrivacyGateState();
}

class _FirstLaunchPrivacyGateState extends State<FirstLaunchPrivacyGate> {
  static const String _privacyKey = 'app_privacy_policy_accepted_v1';
  bool _isChecking = true;
  bool _isAccepted = false;

  @override
  void initState() {
    super.initState();
    _checkPrivacyStatus();
  }

  Future<void> _checkPrivacyStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted = prefs.getBool(_privacyKey) ?? false;
    if (mounted) {
      setState(() {
        _isAccepted = accepted;
        _isChecking = false;
      });
    }
  }

  Future<void> _acceptPrivacyPolicy() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_privacyKey, true);
    if (mounted) {
      setState(() {
        _isAccepted = true;
      });
    }
  }

  Future<void> _openWebPrivacyPolicy() async {
    final base = ApiClient.baseUrl.replaceAll(RegExp(r'/api/v1/?$'), '');
    final langCode = widget.languageProvider?.currentCode ?? 'tr';
    final uri = Uri.parse('$base/privacy?lang=$langCode');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Bağlantı açılamadı: $uri')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return const Scaffold(
        backgroundColor: Color(0xFF0F172A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF0077FF)),
        ),
      );
    }

    if (_isAccepted) {
      return widget.child;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A192F),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 560),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Başlık Alanı
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF0A192F), Color(0xFF0077FF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(24),
                        topRight: Radius.circular(24),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            LanguageSelectorButton(
                              languageProvider: widget.languageProvider,
                              color: Colors.white,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.shield_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Kargo Takip PoD',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppLocalizations.of(context).privacySubtitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // İçerik Alanı
                  Padding(
                    padding: const EdgeInsets.all(22),
                    child: Builder(
                      builder: (ctx) {
                        final l10n = AppLocalizations.of(ctx);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Geliştirici & Veri Sorumlusu Rozeti
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.privacyDeveloperInfo,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF475569),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.privacyDeveloperDetails,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      height: 1.45,
                                      color: Color(0xFF1E293B),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            Text(
                              l10n.privacyLegitimatePurpose,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF334155),
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 12),

                            // İzinler Listesi
                            _buildPermRow(
                              icon: Icons.location_on_rounded,
                              color: const Color(0xFF2563EB),
                              title: l10n.privacyPermLocationTitle,
                              desc: l10n.privacyPermLocationDesc,
                            ),
                            const SizedBox(height: 10),
                            _buildPermRow(
                              icon: Icons.camera_alt_rounded,
                              color: const Color(0xFF059669),
                              title: l10n.privacyPermCameraTitle,
                              desc: l10n.privacyPermCameraDesc,
                            ),
                            const SizedBox(height: 10),
                            _buildPermRow(
                              icon: Icons.draw_rounded,
                              color: const Color(0xFFD97706),
                              title: l10n.privacyPermSignTitle,
                              desc: l10n.privacyPermSignDesc,
                            ),
                            const SizedBox(height: 10),
                            _buildPermRow(
                              icon: Icons.phone_android_rounded,
                              color: const Color(0xFF7C3AED),
                              title: l10n.privacyPermPhoneTitle,
                              desc: l10n.privacyPermPhoneDesc,
                            ),
                            const SizedBox(height: 16),

                            // Web Linki
                            Center(
                              child: InkWell(
                                onTap: _openWebPrivacyPolicy,
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.open_in_new_rounded,
                                        size: 14,
                                        color: Color(0xFF0077FF),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        l10n.privacyWebLink,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF0077FF),
                                          fontWeight: FontWeight.bold,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),

                            // Butonlar
                            Row(
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: OutlinedButton(
                                    onPressed: () => SystemNavigator.pop(),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      side: const BorderSide(
                                        color: Color(0xFFCBD5E1),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: Text(
                                      l10n.privacyRejectBtn,
                                      style: const TextStyle(
                                        color: Color(0xFF64748B),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 3,
                                  child: ElevatedButton(
                                    onPressed: _acceptPrivacyPolicy,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF0077FF),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      elevation: 2,
                                    ),
                                    child: Text(
                                      l10n.privacyAcceptBtn,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPermRow({
    required IconData icon,
    required Color color,
    required String title,
    required String desc,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12.5,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFF64748B),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
