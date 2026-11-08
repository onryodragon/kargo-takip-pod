import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';

/// Şifremi Unuttum ve 6 Haneli E-posta Doğrulama Kodu ile Şifre Sıfırlama Ekranı.
class ForgotPasswordScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String? initialEmail;

  const ForgotPasswordScreen({
    super.key,
    required this.apiClient,
    this.initialEmail,
  });

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final TextEditingController _emailCtrl;
  final _codeCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();

  bool _codeSent = false;
  bool _isLoading = false;
  String? _statusMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(text: widget.initialEmail ?? '');
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _newPassCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendResetCode() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorMessage = 'Lütfen geçerli bir e-posta adresi girin.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      final res = await widget.apiClient.forgotPassword(email);
      if (!mounted) return;
      final fallbackOtp = res['fallback_otp_code']?.toString();
      final msg = res['message']?.toString() ??
          '6 haneli doğrulama kodu e-posta adresinize gönderildi.';
      setState(() {
        _codeSent = true;
        _statusMessage = fallbackOtp != null && fallbackOtp.isNotEmpty
            ? '$msg\n(SMTP henüz tanımlanmadığı için tek kullanımlık kodunuz: $fallbackOtp)'
            : msg;
        if (fallbackOtp != null && fallbackOtp.isNotEmpty) {
          _codeCtrl.text = fallbackOtp;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final newPass = _newPassCtrl.text;
    final confirmPass = _confirmPassCtrl.text;

    if (code.length != 6) {
      setState(() => _errorMessage = 'Lütfen 6 haneli doğrulama kodunu girin.');
      return;
    }
    if (newPass.length < 6) {
      setState(
          () => _errorMessage = 'Yeni şifreniz en az 6 karakter olmalıdır.');
      return;
    }
    if (newPass != confirmPass) {
      setState(() => _errorMessage = 'Girdiğiniz yeni şifreler eşleşmiyor.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await widget.apiClient.resetPassword(
        email: email,
        code: code,
        newPassword: newPass,
      );
      if (!mounted) return;
      final msg = res['message']?.toString() ??
          'Şifreniz başarıyla güncellendi. Giriş yapabilirsiniz.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: const Color(0xFF16A34A),
        ),
      );
      Navigator.of(context).pop(email);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        title: const Text('Şifremi Unuttum'),
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.lock_reset_rounded,
                      size: 54,
                      color: Color(0xFF1E3A8A),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _codeSent
                          ? '6 Haneli Kodu ve Yeni Şifrenizi Girin'
                          : 'E-Posta ile Şifre Sıfırlama',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _codeSent
                          ? 'E-posta adresinize gönderilen 6 haneli doğrulama kodunu ve yeni şifrenizi aşağıya girin.'
                          : 'Kayıtlı e-posta adresinizi girin. Size 6 haneli tek kullanımlık şifre sıfırlama kodu göndereceğiz.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Kayıtlı E-Posta Adresiniz',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_codeSent) ...[
                      const SizedBox(height: 14),
                      TextField(
                        controller: _codeCtrl,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: '6 Haneli Doğrulama Kodu',
                          hintText: '123456',
                          prefixIcon: Icon(Icons.pin_outlined),
                          border: OutlineInputBorder(),
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _newPassCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Yeni Şifre (En az 6 karakter)',
                          prefixIcon: Icon(Icons.lock_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _confirmPassCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Yeni Şifre (Tekrar)',
                          prefixIcon: Icon(Icons.lock_person_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (_statusMessage != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF86EFAC)),
                        ),
                        child: Text(
                          _statusMessage!,
                          style: const TextStyle(
                            color: Color(0xFF166534),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
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
                    if (!_codeSent)
                      FilledButton.icon(
                        onPressed: _isLoading ? null : _sendResetCode,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          backgroundColor: const Color(0xFF1E3A8A),
                        ),
                        icon: _isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.send_rounded),
                        label: const Text(
                          '6 Haneli Doğrulama Kodu Gönder',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      )
                    else ...[
                      FilledButton.icon(
                        onPressed: _isLoading ? null : _resetPassword,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          backgroundColor: const Color(0xFF16A34A),
                        ),
                        icon: _isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: const Text(
                          'Şifremi Güncelle ve Giriş Yap',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _isLoading ? null : _sendResetCode,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Kodu Tekrar Gönder'),
                      ),
                    ],
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
