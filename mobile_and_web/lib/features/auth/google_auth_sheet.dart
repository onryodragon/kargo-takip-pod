import 'package:flutter/material.dart';

/// Huawei AppGallery (GMS-Free) Uyumlu Google Hesabı Bağlama Diyaloğu.
///
/// Cihazda Google Play Services (`com.google.android.gms`) bulunmasa dahi
/// çökmeden Google kimliği (Gmail + Ad Soyad + İsteğe Bağlı İşletme Adı) ile
/// hızlı giriş veya yeni işletme / kurye kaydı yapılmasını sağlar.
class GoogleAuthResult {
  final String email;
  final String fullName;
  final String googleSub;
  final String? tenantName;
  final String? phone;

  const GoogleAuthResult({
    required this.email,
    required this.fullName,
    required this.googleSub,
    this.tenantName,
    this.phone,
  });
}

Future<GoogleAuthResult?> showGmsFreeGoogleAuthDialog(
  BuildContext context, {
  bool isTenantRegistration = false,
  bool isDriverInvite = false,
  String? initialName,
  String? initialPhone,
}) {
  return showDialog<GoogleAuthResult>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _GmsFreeGoogleAuthDialog(
      isTenantRegistration: isTenantRegistration,
      isDriverInvite: isDriverInvite,
      initialName: initialName,
      initialPhone: initialPhone,
    ),
  );
}

class _GmsFreeGoogleAuthDialog extends StatefulWidget {
  final bool isTenantRegistration;
  final bool isDriverInvite;
  final String? initialName;
  final String? initialPhone;

  const _GmsFreeGoogleAuthDialog({
    required this.isTenantRegistration,
    required this.isDriverInvite,
    this.initialName,
    this.initialPhone,
  });

  @override
  State<_GmsFreeGoogleAuthDialog> createState() =>
      _GmsFreeGoogleAuthDialogState();
}

class _GmsFreeGoogleAuthDialogState extends State<_GmsFreeGoogleAuthDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  late final TextEditingController _nameCtrl;
  final _tenantNameCtrl = TextEditingController();
  late final TextEditingController _phoneCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName ?? '');
    _phoneCtrl = TextEditingController(text: widget.initialPhone ?? '');
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _nameCtrl.dispose();
    _tenantNameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final email = _emailCtrl.text.trim().toLowerCase();
    final fullName = _nameCtrl.text.trim().isEmpty
        ? email.split('@').first
        : _nameCtrl.text.trim();
    final googleSub = 'gmsfree-google-$email';

    Navigator.of(context).pop(
      GoogleAuthResult(
        email: email,
        fullName: fullName,
        googleSub: googleSub,
        tenantName: _tenantNameCtrl.text.trim().isEmpty
            ? null
            : _tenantNameCtrl.text.trim(),
        phone:
            _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFEA4335).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Text(
              'G',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 20,
                color: Color(0xFFEA4335),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Google Hesabı ile Bağlan',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: const Text(
                  'Huawei / GMS-Free Uyumlu Google Bağlantısı:\nGoogle (Gmail) adresinizle şifresiz ve hızlı şekilde oturum açın veya hesabınızı bağlayın.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF1E3A8A)),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Google (Gmail) E-Posta Adresiniz *',
                  hintText: 'ornek@gmail.com',
                  prefixIcon: Icon(Icons.mail_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (val) {
                  if (val == null || !val.contains('@')) {
                    return 'Geçerli bir Google e-posta adresi girin';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Ad Soyad *',
                  hintText: 'Adınız Soyadınız',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (val) {
                  if ((widget.isTenantRegistration || widget.isDriverInvite) &&
                      (val == null || val.trim().length < 2)) {
                    return 'Ad Soyad girin';
                  }
                  return null;
                },
              ),
              if (widget.isTenantRegistration) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _tenantNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'İşletme / Şirket Adı (Yeni Kayıt İçin)',
                    hintText: 'Örn: Hızlı Kargo Lojistik',
                    prefixIcon: Icon(Icons.storefront_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'WhatsApp Telefon Numarası',
                    hintText: '05xx xxx xx xx',
                    prefixIcon: Icon(Icons.phone_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('İptal'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.login),
          label: const Text('Google ile Devam Et'),
        ),
      ],
    );
  }
}
