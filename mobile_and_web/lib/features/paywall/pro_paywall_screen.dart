import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/language_provider.dart';
import '../../core/l10n/language_selector_button.dart';
import '../../core/services/huawei_iap_service.dart';

/// Demosuz, Zorunlu PRO Satın Alma Ekranı (Huawei IAP Paywall):
/// - Yönetici (Admin) girişi yapıldığında veya yeni kayıt olunduğunda gösterilir.
/// - Geri çıkılamaz (PopScope canPop: false).
/// - Demo veya ücretsiz deneme seçeneği YOKTUR.
/// - "Ömür Boyu Satın Al (10 €)" ve "Satın Alımı Geri Yükle (Restore Purchase)" butonları içerir.
/// - Kurye (driver) ve test hesabı (appgallery_admin@kargotakip.com) buraya hiç uğramaz.
class ProPaywallScreen extends StatefulWidget {
  final ApiClient apiClient;
  final VoidCallback onProActivated;
  final VoidCallback onLogout;
  final LanguageProvider? languageProvider;

  const ProPaywallScreen({
    super.key,
    required this.apiClient,
    required this.onProActivated,
    required this.onLogout,
    this.languageProvider,
  });

  @override
  State<ProPaywallScreen> createState() => _ProPaywallScreenState();
}

class _ProPaywallScreenState extends State<ProPaywallScreen> {
  bool _isLoading = false;
  String? _loadingMessage;

  Future<void> _handleBuy() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _isLoading = true;
      _loadingMessage = l10n.proProcessing;
    });

    try {
      final result = await HuaweiIapService.buyProLifetime(
        apiClient: widget.apiClient,
      );

      if (!mounted) return;

      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF059669),
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.proSuccess,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
        widget.onProActivated();
      } else {
        final isCancelled = result['cancelled'] == true;
        if (!isCancelled) {
          final errMsg = result['errMsg']?.toString() ?? l10n.proError;
          _showErrorDialog(errMsg);
        }
      }
    } catch (e) {
      if (!mounted) return;
      _showErrorDialog(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingMessage = null;
        });
      }
    }
  }

  Future<void> _handleRestore() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _isLoading = true;
      _loadingMessage = l10n.proRestoreBtn;
    });

    try {
      final result = await HuaweiIapService.restorePurchases(
        apiClient: widget.apiClient,
      );

      if (!mounted) return;

      if (result['hasOwned'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF059669),
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.proSuccess,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
        widget.onProActivated();
      } else {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.proRestoreBtn),
            content: Text(l10n.proNotFound),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l10n.ok),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showErrorDialog(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingMessage = null;
        });
      }
    }
  }

  void _showErrorDialog(String message) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.error),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    // Geri çıkılamaz (PopScope canPop: false)
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0A192F),
        body: Stack(
          children: [
            // Arka Plan Işık Efekti
            Positioned(
              top: -80,
              right: -80,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0077FF).withValues(alpha: 0.18),
                ),
              ),
            ),
            Positioned(
              bottom: -100,
              left: -100,
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                ),
              ),
            ),

            SafeArea(
              child: Column(
                children: [
                  // Üst Çubuk: Dil Seçici ve Çıkış Butonu
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        LanguageSelectorButton(
                          languageProvider: widget.languageProvider,
                          color: Colors.white,
                        ),
                        TextButton.icon(
                          onPressed: _isLoading ? null : widget.onLogout,
                          icon: const Icon(Icons.logout_rounded, size: 18, color: Color(0xFF94A3B8)),
                          label: Text(
                            l10n.proLogoutBtn,
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Ana İçerik
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      child: Center(
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Rozet
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.workspace_premium_rounded, size: 16, color: Colors.white),
                                    const SizedBox(width: 6),
                                    Text(
                                      l10n.proBadge,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),

                              // Başlık
                              Text(
                                l10n.proTitle,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 8),

                              // Alt Başlık
                              Text(
                                l10n.proSubtitle,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 13.5,
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 22),

                              // Fiyatlandırma Kartı
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
                                    width: 1.5,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          l10n.proPriceVal,
                                          style: const TextStyle(
                                            color: Color(0xFFFEF08A),
                                            fontSize: 42,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: -1.0,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      l10n.proPriceDesc,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Color(0xFFE2E8F0),
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),

                              // Özellikler Listesi
                              _buildFeatureRow(l10n.proFeat1, Icons.groups_rounded),
                              _buildFeatureRow(l10n.proFeat2, Icons.map_rounded),
                              _buildFeatureRow(l10n.proFeat3, Icons.camera_alt_rounded),
                              _buildFeatureRow(l10n.proFeat4, Icons.table_chart_rounded),
                              _buildFeatureRow(l10n.proFeat5, Icons.devices_rounded),
                              _buildFeatureRow(l10n.proFeat6, Icons.cloud_done_rounded),

                              const SizedBox(height: 28),

                              // Satın Al Butonu
                              SizedBox(
                                width: double.infinity,
                                height: 54,
                                child: ElevatedButton(
                                  onPressed: _isLoading ? null : _handleBuy,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFF59E0B),
                                    foregroundColor: const Color(0xFF0F172A),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    elevation: 4,
                                    shadowColor: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                                  ),
                                  child: _isLoading && _loadingMessage == l10n.proProcessing
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            color: Color(0xFF0F172A),
                                          ),
                                        )
                                      : Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            const Icon(Icons.flash_on_rounded, size: 20),
                                            const SizedBox(width: 8),
                                            Text(
                                              l10n.proBuyBtn,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: 0.2,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Satın Alımı Geri Yükle Butonu (Restore)
                              TextButton.icon(
                                onPressed: _isLoading ? null : _handleRestore,
                                icon: const Icon(
                                  Icons.restore_rounded,
                                  size: 16,
                                  color: Color(0xFFCBD5E1),
                                ),
                                label: Text(
                                  l10n.proRestoreBtn,
                                  style: const TextStyle(
                                    color: Color(0xFFCBD5E1),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureRow(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 16,
              color: Color(0xFF10B981),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
