import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import 'google_auth_sheet.dart';

/// Kuryenin WhatsApp Davet Linkine (`/#/driver-invite/{invite_token}`) tıkladığında
/// veya uygulama içinden "Davet Kodu ile Kurye Ol" butonuna bastığında açılan
/// Kendi Bilgilerini Girerek Kurye Kaydını Tamamlama Ekranı.
class DriverInviteRegisterScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String? initialInviteToken;
  final VoidCallback onRegistered;

  const DriverInviteRegisterScreen({
    super.key,
    required this.apiClient,
    this.initialInviteToken,
    required this.onRegistered,
  });

  @override
  State<DriverInviteRegisterScreen> createState() =>
      _DriverInviteRegisterScreenState();
}

class _DriverInviteRegisterScreenState
    extends State<DriverInviteRegisterScreen> {
  static const List<String> _vehiclePresets = [
    'Motosiklet',
    'Binek Araç',
    'Panelvan',
    'Kamyonet',
    'Kamyon',
    'Bisiklet',
  ];

  late final TextEditingController _tokenCtrl;
  final _fullNameCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();
  final _vehicleTypeCtrl = TextEditingController(text: 'Motosiklet');
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  String? _googleSub;
  bool _loadingInvite = false;
  bool _submitting = false;
  String? _tenantName;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tokenCtrl = TextEditingController(text: widget.initialInviteToken ?? '');
    if (_tokenCtrl.text.trim().isNotEmpty) {
      _loadInviteDetails(_tokenCtrl.text.trim());
    }
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _fullNameCtrl.dispose();
    _plateCtrl.dispose();
    _vehicleTypeCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  String _extractCleanToken(String raw) {
    final trimmed = raw.trim();
    if (trimmed.contains('/driver-invite/')) {
      return trimmed.split('/driver-invite/').last.split('?').first.trim();
    }
    return trimmed;
  }

  Future<void> _loadInviteDetails(String rawToken) async {
    final token = _extractCleanToken(rawToken);
    if (token.isEmpty) return;

    setState(() {
      _loadingInvite = true;
      _errorMessage = null;
    });

    try {
      final info = await widget.apiClient.getDriverInviteInfo(token);
      if (!mounted) return;
      setState(() {
        _tokenCtrl.text = token;
        _tenantName = info['tenant_name']?.toString();
        final invitedPhone = info['phone']?.toString() ?? '';
        if (_phoneCtrl.text.trim().isEmpty && invitedPhone.isNotEmpty) {
          _phoneCtrl.text = invitedPhone;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _loadingInvite = false);
    }
  }

  Future<void> _connectWithGoogle() async {
    final res = await showGmsFreeGoogleAuthDialog(
      context,
      isDriverInvite: true,
      initialName: _fullNameCtrl.text.trim(),
      initialPhone: _phoneCtrl.text.trim(),
    );
    if (res == null || !mounted) return;

    setState(() {
      _emailCtrl.text = res.email;
      if (_fullNameCtrl.text.trim().isEmpty) {
        _fullNameCtrl.text = res.fullName;
      }
      _googleSub = res.googleSub;
      if (_passwordCtrl.text.isEmpty) {
        _passwordCtrl.text = 'GoogleAuth-${res.googleSub}';
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Google hesabı bağlandı: ${res.email}'),
        backgroundColor: const Color(0xFF16A34A),
      ),
    );
  }

  Future<void> _completeRegistration() async {
    final token = _extractCleanToken(_tokenCtrl.text);
    final fullName = _fullNameCtrl.text.trim();
    final plate = _plateCtrl.text.trim().toUpperCase();
    final vehicleType = _vehicleTypeCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (token.isEmpty) {
      setState(
          () => _errorMessage = 'Lütfen WhatsApp davet kodunuzu / linkinizi girin.');
      return;
    }
    if (fullName.length < 2) {
      setState(() => _errorMessage = 'Lütfen Ad Soyad bilginizi girin.');
      return;
    }
    if (plate.length < 3) {
      setState(() => _errorMessage = 'Lütfen Araç Plakanızı girin (Örn: 34 ABC 123).');
      return;
    }
    if (vehicleType.length < 2) {
      setState(() => _errorMessage = 'Lütfen Araç Cinsini seçin veya yazın.');
      return;
    }
    if (!email.contains('@')) {
      setState(() => _errorMessage = 'Lütfen geçerli bir e-posta adresi girin.');
      return;
    }
    if (password.length < 6 && _googleSub == null) {
      setState(
          () => _errorMessage = 'Şifreniz en az 6 karakter olmalıdır.');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await widget.apiClient.acceptDriverInvite(
        inviteToken: token,
        fullName: fullName,
        vehiclePlate: plate,
        vehicleType: vehicleType,
        email: email,
        password: password.length >= 6 ? password : 'GoogleAuth123!',
        phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
        googleSub: _googleSub,
      );
      if (!mounted) return;
      widget.onRegistered();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
        title: const Text('Kurye Davetiye Kaydı'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Card(
              elevation: 5,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF1E3A8A).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.delivery_dining_rounded,
                            size: 32,
                            color: Color(0xFF1E3A8A),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _tenantName != null
                                    ? '$_tenantName — Kurye Kaydı'
                                    : 'Kurye Bilgilerinizi Girin',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Bilgilerinizi doldurup kaydı tamamladığınızda işletmenin aktif kuryesi olarak hemen göreve başlayabilirsiniz.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // Davet Kodu Alanı (Linkten gelmemişse yapıştırabilir)
                    if (widget.initialInviteToken == null ||
                        widget.initialInviteToken!.isEmpty) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _tokenCtrl,
                              decoration: const InputDecoration(
                                labelText: 'WhatsApp Davet Kodu veya Linki *',
                                hintText: 'Davet kodunu buraya yapıştırın',
                                prefixIcon: Icon(Icons.vpn_key_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            onPressed: _loadingInvite
                                ? null
                                : () => _loadInviteDetails(_tokenCtrl.text),
                            icon: _loadingInvite
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.search),
                            tooltip: 'Davetiyeyi Doğrula',
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],

                    // 1. Ad Soyad
                    TextField(
                      controller: _fullNameCtrl,
                      decoration: const InputDecoration(
                        labelText: '1. Ad Soyad *',
                        hintText: 'Örn: Ahmet Yılmaz',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 2. Araç Plakası
                    TextField(
                      controller: _plateCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: '2. Araç Plakası *',
                        hintText: 'Örn: 34 ABC 123',
                        prefixIcon: Icon(Icons.confirmation_number_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 3. Araç Cinsi (Seçilebilir ve Yazılabilir)
                    TextField(
                      controller: _vehicleTypeCtrl,
                      decoration: const InputDecoration(
                        labelText: '3. Araç Cinsi (Seçin veya Yazın) *',
                        hintText: 'Motosiklet, Panelvan, Kamyonet vb.',
                        prefixIcon: Icon(Icons.local_shipping_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _vehiclePresets.map((preset) {
                        final selected =
                            _vehicleTypeCtrl.text.trim().toLowerCase() ==
                                preset.toLowerCase();
                        return ChoiceChip(
                          label: Text(
                            preset,
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: selected,
                          onSelected: (_) {
                            setState(() {
                              _vehicleTypeCtrl.text = preset;
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),

                    // Google ile Hızlı Bağlanma
                    OutlinedButton.icon(
                      onPressed: _submitting ? null : _connectWithGoogle,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(
                        Icons.g_mobiledata_rounded,
                        size: 26,
                        color: Color(0xFFEA4335),
                      ),
                      label: Text(
                        _googleSub != null
                            ? 'Google Hesabı Bağlandı (${_emailCtrl.text})'
                            : 'Google Hesabı ile Bağlan (İsteğe Bağlı)',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 4. E-posta ve Şifre
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: '4. E-Posta Adresiniz *',
                        hintText: 'kurye@ornek.com',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Belirleyeceğiniz Giriş Şifresi *',
                        hintText: 'En az 6 karakter',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'WhatsApp Telefon Numaranız',
                        hintText: '05xx xxx xx xx',
                        prefixIcon: Icon(Icons.phone_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),

                    if (_errorMessage != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color: Colors.red.shade800,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _submitting ? null : _completeRegistration,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_circle_rounded),
                      label: const Text(
                        'Kaydı Tamamla ve Göreve Başla',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
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
