import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';

/// Yönetici / Kurye Giriş ve Yeni İşletme (Multi-Tenant White-Label) Kayıt Ekranı.
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
        await widget.apiClient.registerTenant(
          name: _tenantNameCtrl.text.trim(),
          slug: _tenantSlugCtrl.text.trim().toLowerCase(),
          reportEmail: _reportEmailCtrl.text.trim(),
          logoUrl: _logoUrlCtrl.text.trim(),
          primaryColor: _primaryColorCtrl.text.trim(),
          adminFullName: _adminNameCtrl.text.trim(),
          adminEmail: _adminEmailCtrl.text.trim(),
          adminPhone: _adminPhoneCtrl.text.trim(),
          adminPassword: _adminPasswordCtrl.text,
        );
      } else {
        await widget.apiClient.login(
          email: _loginEmailCtrl.text.trim(),
          password: _loginPasswordCtrl.text,
        );
      }
      widget.onAuthenticated();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
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
                          ? 'Yeni İşletme (White-Label) Kaydı'
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
                          ? 'İşletme adınızı, logonuzu ve fotoğraflı Excel arşivlerinin gideceği e-posta adresini belirleyin.'
                          : 'İşletme Yöneticisi (Admin) veya Saha Kuryesi (Driver) hesabınızla giriş yapın.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 20),
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
                          style: const TextStyle(color: Color(0xFF991B1B), fontSize: 13),
                        ),
                      ),
                    if (!_isRegisterMode) ...[
                      TextField(
                        controller: _loginEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'E-posta Adresi',
                          prefixIcon: Icon(Icons.email_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _loginPasswordCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Şifre',
                          prefixIcon: Icon(Icons.lock_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          ActionChip(
                            avatar: const Icon(Icons.admin_panel_settings_outlined, size: 16),
                            label: const Text('Demo Yönetici (admin@demo.com)', style: TextStyle(fontSize: 12)),
                            onPressed: () {
                              setState(() {
                                _loginEmailCtrl.text = 'admin@demo.com';
                                _loginPasswordCtrl.text = '123456';
                              });
                            },
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.two_wheeler_rounded, size: 16),
                            label: const Text('Demo Kurye (kurye@demo.com)', style: TextStyle(fontSize: 12)),
                            onPressed: () {
                              setState(() {
                                _loginEmailCtrl.text = 'kurye@demo.com';
                                _loginPasswordCtrl.text = '123456';
                              });
                            },
                          ),
                        ],
                      ),
                    ] else ...[
                      const Text(
                        '1. İşletme & White-Label Ayarları',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _tenantNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'İşletme Adı (Örn: Yıldız Ekspres Kargo) *',
                          prefixIcon: Icon(Icons.storefront_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _tenantSlugCtrl,
                        decoration: const InputDecoration(
                          labelText: 'İşletme Kısa Kodu / Slug (Örn: yildiz-kargo) *',
                          prefixIcon: Icon(Icons.link),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _reportEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Fotoğraflı Excel Rapor E-posta Adresi *',
                          helperText: 'Tamamlanan teslimatların gömülü Excel arşivi bu adrese gönderilir.',
                          prefixIcon: Icon(Icons.table_view_outlined),
                          border: OutlineInputBorder(),
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
                                labelText: 'Renk (HEX)',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 28),
                      const Text(
                        '2. İşletme Sahibi (Admin) Hesabı',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _adminNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Yönetici Adı Soyadı *',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _adminEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Yönetici Giriş E-postası *',
                          prefixIcon: Icon(Icons.alternate_email),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _adminPhoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Yönetici Telefonu *',
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
                    ],
                    const SizedBox(height: 22),
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
                          : Text(_isRegisterMode ? 'İŞLETMEYİ OLUŞTUR VE BAŞLA' : 'GİRİŞ YAP'),
                    ),
                    const SizedBox(height: 12),
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
                            ? 'Zaten hesabınız var mı? Giriş Yapın'
                            : 'Yeni bir işletme misiniz? White-Label İşletme Kaydı Oluşturun',
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
