import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import 'driver_invite_register_screen.dart';
import 'forgot_password_screen.dart';
import 'google_auth_sheet.dart';

/// Yönetici / Kurye Giriş, Şifremi Unuttum, Google Hesabı ile Bağlanma,
/// WhatsApp Kurye Davetiyesi Kabul ve Yeni İşletme (Multi-Tenant) Kayıt Ekranı.
class AuthScreen extends StatefulWidget {
  final ApiClient apiClient;
  final VoidCallback onAuthenticated;

  const AuthScreen({
    super.key,
    required this.apiClient,
    required this.onAuthenticated,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isRegisterMode = false;
  bool _isLoading = false;
  String? _errorMessage;

  // Giriş Alanları
  final _loginEmailCtrl = TextEditingController();
  final _loginPasswordCtrl = TextEditingController();

  // Yeni İşletme (Multi-Tenant) Kayıt Alanları
  final _tenantNameCtrl = TextEditingController();
  final _tenantSlugCtrl = TextEditingController();
  final _reportEmailCtrl = TextEditingController();
  final _logoUrlCtrl = TextEditingController();
  final _primaryColorCtrl = TextEditingController(text: '#1E40AF');
  final _adminNameCtrl = TextEditingController();
  final _adminEmailCtrl = TextEditingController();
  final _adminPhoneCtrl = TextEditingController();
  final _adminPasswordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _adminEmailCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _loginEmailCtrl.dispose();
    _loginPasswordCtrl.dispose();
    _tenantNameCtrl.dispose();
    _tenantSlugCtrl.dispose();
    _reportEmailCtrl.dispose();
    _logoUrlCtrl.dispose();
    _primaryColorCtrl.dispose();
    _adminNameCtrl.dispose();
    _adminEmailCtrl.dispose();
    _adminPhoneCtrl.dispose();
    _adminPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_isRegisterMode) {
        final companyName = _tenantNameCtrl.text.trim();
        final adminName = _adminNameCtrl.text.trim();
        final adminEmail = _adminEmailCtrl.text.trim().toLowerCase();
        final adminPhone = _adminPhoneCtrl.text.trim();
        final adminPassword = _adminPasswordCtrl.text;

        if (companyName.isEmpty ||
            adminName.isEmpty ||
            adminEmail.isEmpty ||
            adminPhone.isEmpty ||
            adminPassword.length < 6) {
          throw Exception(
            'Lütfen işletme adını, yönetici bilgilerini, e-posta adresini ve en az 6 karakterli şifrenizi girin.',
          );
        }

        final effectiveReportEmail = _reportEmailCtrl.text.trim().isNotEmpty
            ? _reportEmailCtrl.text.trim().toLowerCase()
            : adminEmail;

        await widget.apiClient.registerTenant(
          name: companyName,
          slug: _tenantSlugCtrl.text.trim().toLowerCase(),
          reportEmail: effectiveReportEmail,
          logoUrl: _logoUrlCtrl.text.trim(),
          primaryColor: _primaryColorCtrl.text.trim(),
          adminFullName: adminName,
          adminEmail: adminEmail,
          adminPhone: adminPhone,
          adminPassword: adminPassword,
        );
      } else {
        final email = _loginEmailCtrl.text.trim().toLowerCase();
        final password = _loginPasswordCtrl.text;
        if (email.isEmpty || password.isEmpty) {
          throw Exception('Lütfen e-posta adresinizi ve şifrenizi girin.');
        }
        await widget.apiClient.login(
          email: email,
          password: password,
        );
      }
      widget.onAuthenticated();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleGoogleSignIn() async {
    final res = await showGmsFreeGoogleAuthDialog(
      context,
      isTenantRegistration: _isRegisterMode,
    );
    if (res == null || !mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await widget.apiClient.authenticateWithGoogle(
        email: res.email,
        fullName: res.fullName,
        idToken: res.googleSub,
        companyName: res.tenantName ??
            (_isRegisterMode && _tenantNameCtrl.text.trim().isNotEmpty
                ? _tenantNameCtrl.text.trim()
                : '${res.fullName} Lojistik'),
        phone: res.phone,
      );
      if (!mounted) return;
      widget.onAuthenticated();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openForgotPassword() async {
    final resetEmail = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ForgotPasswordScreen(
          apiClient: widget.apiClient,
          initialEmail: _loginEmailCtrl.text.trim(),
        ),
      ),
    );
    if (resetEmail != null && resetEmail.isNotEmpty && mounted) {
      setState(() {
        _isRegisterMode = false;
        _loginEmailCtrl.text = resetEmail;
      });
    }
  }

  Future<void> _openDriverInviteScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => DriverInviteRegisterScreen(
          apiClient: widget.apiClient,
          onRegistered: () {
            Navigator.of(ctx).pop();
            widget.onAuthenticated();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final currentAdminEmail = _adminEmailCtrl.text.trim();

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.local_shipping_rounded, size: 52, color: primary),
                    const SizedBox(height: 12),
                    Text(
                      _isRegisterMode
                          ? 'Yeni İşletme Kaydı (Multi-Tenant)'
                          : 'Teslimat & PoD Yönetim Girişi',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isRegisterMode
                          ? 'E-posta adresinizle işletmenize özel %100 izole çalışma alanınızı oluşturun. Fotoğraflı Excel arşivleri otomatik olarak e-postanıza gönderilir.'
                          : 'İşletme Yöneticisi (Admin) veya Saha Kuryesi (Driver) hesabınızla giriş yapın.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 18),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment<bool>(
                          value: false,
                          icon: Icon(Icons.login_rounded, size: 18),
                          label: Text('Giriş Yap'),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          icon: Icon(Icons.add_business_rounded, size: 18),
                          label: Text('Yeni İşletme Kaydı'),
                        ),
                      ],
                      selected: {_isRegisterMode},
                      onSelectionChanged: _isLoading
                          ? null
                          : (selection) {
                              setState(() {
                                _isRegisterMode = selection.first;
                                _errorMessage = null;
                              });
                            },
                    ),
                    const SizedBox(height: 18),
                    if (_errorMessage != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFF87171)),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Color(0xFF991B1B),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    if (!_isRegisterMode) ...[
                      TextField(
                        controller: _loginEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'İşletme veya Kurye E-posta Adresi',
                          prefixIcon: Icon(Icons.email_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _loginPasswordCtrl,
                        obscureText: true,
                        onSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                          labelText: 'Şifre',
                          prefixIcon: Icon(Icons.lock_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _isLoading ? null : _openForgotPassword,
                          icon: const Icon(Icons.lock_reset_rounded, size: 18),
                          label: const Text(
                            'Şifremi Unuttum',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ] else ...[
                      const Text(
                        '1. İşletme & Yönetici Hesap Bilgileri',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _tenantNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'İşletme / Şirket Adı *',
                          hintText: 'Örn: Kuzey Dağıtım Lojistik',
                          prefixIcon: Icon(Icons.storefront_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _adminNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'İşletme Sahibi / Yönetici Adı Soyadı *',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _adminEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText:
                              'İşletme E-posta Adresi (Giriş & Excel Arşivi) *',
                          helperText:
                              'Bu e-posta işletmenizin özel çalışma alanını ve rapor adresini oluşturur.',
                          prefixIcon: Icon(Icons.alternate_email),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _adminPhoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Yönetici WhatsApp Telefon Numarası *',
                          hintText: '05xx xxx xx xx',
                          prefixIcon: Icon(Icons.phone_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _adminPasswordCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Yönetici Şifresi (En az 6 karakter) *',
                          prefixIcon: Icon(Icons.lock_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const Divider(height: 28),
                      const Text(
                        '2. Opsiyonel White-Label & Rapor Ayarları',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _reportEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: 'Farklı Excel Rapor E-postası (Opsiyonel)',
                          hintText: currentAdminEmail.isNotEmpty
                              ? 'Varsayılan: $currentAdminEmail'
                              : 'Boş bırakılırsa giriş e-postanız kullanılır',
                          prefixIcon: const Icon(Icons.table_view_outlined),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _logoUrlCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Logo URL (Opsiyonel)',
                                prefixIcon: Icon(Icons.image_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _primaryColorCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Tema HEX',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                    ],
                    ElevatedButton(
                      onPressed: _isLoading ? null : _submit,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _isRegisterMode
                                  ? 'İŞLETMEYİ OLUŞTUR VE YÖNETİM PANELİNİ AÇ'
                                  : 'GİRİŞ YAP',
                            ),
                    ),
                    const SizedBox(height: 10),

                    // Google Hesabı ile Bağlan (Huawei / GMS-Free Uyumlu)
                    OutlinedButton.icon(
                      onPressed: _isLoading ? null : _handleGoogleSignIn,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        side: const BorderSide(color: Color(0xFFCBD5E1)),
                      ),
                      icon: Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEA4335).withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Text(
                          'G',
                          style: TextStyle(
                            color: Color(0xFFEA4335),
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      label: const Text(
                        'Google Hesabı ile Bağlan',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // WhatsApp Davet Kodu ile Kurye Kaydı
                    OutlinedButton.icon(
                      onPressed: _isLoading ? null : _openDriverInviteScreen,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        foregroundColor: const Color(0xFF15803D),
                        side: const BorderSide(color: Color(0xFF86EFAC)),
                      ),
                      icon: const Icon(Icons.delivery_dining_rounded, size: 20),
                      label: const Text(
                        'WhatsApp Davet Kodu ile Kurye Ol',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _isLoading
                          ? null
                          : () {
                              setState(() {
                                _isRegisterMode = !_isRegisterMode;
                                _errorMessage = null;
                              });
                            },
                      child: Text(
                        _isRegisterMode
                            ? 'Zaten işletme veya kurye hesabınız var mı? Giriş Yapın'
                            : 'Yeni bir şirket misiniz? Yeni İşletme Kaydı Oluşturun',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
