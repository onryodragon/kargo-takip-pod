import 'dart:typed_data';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';
import 'package:signature/signature.dart';

import '../../core/api/api_client.dart';
import '../../core/services/location_service.dart';
import '../../core/widgets/animated_saas_widgets.dart';

/// İŞ KURALI #4 & #6: Zorunlu Teslimat Kanıtı (PoD: Fotoğraf + İmza) Ekranı
/// + Kaydırarak Teslim Et (Slide-to-Deliver) + Konfeti Kutlama Animasyonu.
class PodDeliveryScreen extends StatefulWidget {
  final ApiClient apiClient;
  final GmsFreeLocationService locationService;
  final Map<String, dynamic> order;

  const PodDeliveryScreen({
    super.key,
    required this.apiClient,
    required this.locationService,
    required this.order,
  });

  @override
  State<PodDeliveryScreen> createState() => _PodDeliveryScreenState();
}

class _PodDeliveryScreenState extends State<PodDeliveryScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  late final TextEditingController _recipientCtrl;
  late final SignatureController _signatureController;
  late final ConfettiController _confettiController;

  Uint8List? _photoBytes;
  bool _hasSignature = false;
  bool _isSubmitting = false;
  bool _showCelebrationOverlay = false;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(
      duration: const Duration(seconds: 3),
    );
    _recipientCtrl = TextEditingController(
      text: widget.order['customer_name']?.toString() ?? '',
    );
    _recipientCtrl.addListener(_onFormStateChanged);

    _signatureController = SignatureController(
      penStrokeWidth: 3.5,
      penColor: const Color(0xFF0F172A),
      exportBackgroundColor: Colors.white,
    );
    _signatureController.addListener(_onFormStateChanged);
  }

  void _onFormStateChanged() {
    final nonEmptySig = _signatureController.isNotEmpty;
    if (mounted) {
      setState(() {
        _hasSignature = nonEmptySig;
      });
    }
  }

  @override
  void dispose() {
    _confettiController.dispose();
    _recipientCtrl.removeListener(_onFormStateChanged);
    _recipientCtrl.dispose();
    _signatureController.removeListener(_onFormStateChanged);
    _signatureController.dispose();
    super.dispose();
  }

  /// KRİTİK KURAL: Üç zorunlu şart da sağlanmadan teslimat tamamlanamaz!
  bool get _isReadyToComplete =>
      _recipientCtrl.text.trim().length >= 2 &&
      _photoBytes != null &&
      _signatureController.isNotEmpty &&
      _hasSignature &&
      !_isSubmitting;

  Future<void> _captureDeliveryPhoto() async {
    try {
      final XFile? captured = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 82,
        maxWidth: 1280,
      );
      if (captured != null) {
        final bytes = await captured.readAsBytes();
        if (mounted) {
          setState(() {
            _photoBytes = bytes;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Kamera açılamadı: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _submitMandatoryPoD() async {
    if (!_isReadyToComplete) return;

    setState(() => _isSubmitting = true);
    try {
      final sigPngBytes = await _signatureController.toPngBytes();
      if (sigPngBytes == null || sigPngBytes.isEmpty) {
        throw Exception('İmza görüntüsü oluşturulamadı.');
      }

      final currentCoord =
          await widget.locationService.getCurrentCoordinateOrFallback();

      final result = await widget.apiClient.deliverOrderWithPoD(
        orderId: widget.order['id'].toString(),
        recipientName: _recipientCtrl.text.trim(),
        deliveredLat: currentCoord.latitude,
        deliveredLng: currentCoord.longitude,
        photoBytes: _photoBytes!,
        signaturePngBytes: sigPngBytes,
      );

      if (!mounted) return;
      // Konfeti patlat ve kutlama kartını göster!
      setState(() {
        _isSubmitting = false;
        _showCelebrationOverlay = true;
      });
      _confettiController.play();

      await Future.delayed(const Duration(milliseconds: 2100));
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Teslimat tamamlanamadı: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasRecipient = _recipientCtrl.text.trim().length >= 2;
    final hasPhoto = _photoBytes != null;
    final hasSig = _hasSignature && _signatureController.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Zorunlu Teslimat Kanıtı — #${widget.order['order_number']}',
        ),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(18),
            children: [
              // DURUM KONTROL LİSTESİ BANNER'I (Glassmorphic)
              GlassmorphicContainer(
                tintColor: _isReadyToComplete
                    ? const Color(0xFFDCFCE7)
                    : const Color(0xFFFFFBEB),
                borderColor: _isReadyToComplete
                    ? const Color(0xFF4ADE80)
                    : const Color(0xFFFDE047),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _isReadyToComplete
                              ? Icons.verified_rounded
                              : Icons.fact_check_outlined,
                          color: _isReadyToComplete
                              ? const Color(0xFF15803D)
                              : const Color(0xFFB45309),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _isReadyToComplete
                                ? 'Harika! Tüm zorunlu teslimat kanıtları hazır. Aşağıdaki sürgüyü kaydırarak teslimatı tamamlayın.'
                                : 'Teslimatı tamamlamak için aşağıdaki 3 zorunlu adımı eksiksiz doldurun:',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _buildRequirementRow(
                      '1. Teslim Alan Kişinin Adı Soyadı',
                      hasRecipient,
                    ),
                    _buildRequirementRow(
                      '2. Teslimat Fotoğrafı (Kamera)',
                      hasPhoto,
                    ),
                    _buildRequirementRow(
                      '3. Alıcının Ekrana İmzası',
                      hasSig,
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 350.ms).slideY(begin: -0.08, end: 0),
              const SizedBox(height: 18),

              // ADIM 1: TESLİM ALAN KİŞİNİN ADI SOYADI
              TextField(
                controller: _recipientCtrl,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  labelText: '1. Teslim Alan Kişinin Adı Soyadı (Zorunlu) *',
                  prefixIcon: const Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ).animate().fadeIn(delay: 80.ms, duration: 350.ms),
              const SizedBox(height: 20),

              // ADIM 2: ZORUNLU TESLİMAT FOTOĞRAFI (KAMERA)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '2. Teslimat Fotoğrafı (Zorunlu) *',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _isSubmitting ? null : _captureDeliveryPhoto,
                    icon: const Icon(Icons.camera_alt_rounded, size: 18),
                    label: Text(
                      _photoBytes == null ? 'Fotoğraf Çek' : 'Yeniden Çek',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: _isSubmitting ? null : _captureDeliveryPhoto,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  height: 195,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: hasPhoto
                          ? const Color(0xFF16A34A)
                          : const Color(0xFFCBD5E1),
                      width: hasPhoto ? 2.4 : 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: hasPhoto
                            ? const Color(0xFF16A34A).withValues(alpha: 0.16)
                            : Colors.black.withValues(alpha: 0.04),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: _photoBytes != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.memory(
                            _photoBytes!,
                            width: double.infinity,
                            height: 195,
                            fit: BoxFit.cover,
                          ),
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: const BoxDecoration(
                                color: Color(0xFFEFF6FF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.add_a_photo_rounded,
                                size: 36,
                                color: Color(0xFF2563EB),
                              ),
                            )
                                .animate(onPlay: (c) => c.repeat(reverse: true))
                                .scaleXY(
                                  begin: 0.94,
                                  end: 1.06,
                                  duration: 900.ms,
                                ),
                            const SizedBox(height: 10),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 20),
                              child: Text(
                                'Kamerayı açıp paketin/teslimatın fotoğrafını çekmek için dokunun',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF475569),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ).animate().fadeIn(delay: 140.ms, duration: 380.ms),
              const SizedBox(height: 22),

              // ADIM 3: ZORUNLU MÜŞTERİ İMZA PEDİ
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '3. Alıcı İmza Pedi (Zorunlu) *',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  TextButton.icon(
                    onPressed: _isSubmitting
                        ? null
                        : () {
                            _signatureController.clear();
                            setState(() => _hasSignature = false);
                          },
                    icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                    label: const Text('İmzayı Temizle'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                height: 185,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: hasSig
                        ? const Color(0xFF16A34A)
                        : const Color(0xFFCBD5E1),
                    width: hasSig ? 2.4 : 1.2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Signature(
                    controller: _signatureController,
                    height: 185,
                    backgroundColor: Colors.white,
                  ),
                ),
              ).animate().fadeIn(delay: 200.ms, duration: 380.ms),
              const SizedBox(height: 6),
              const Text(
                'Lütfen alıcıdan yukarıdaki beyaz alana parmağıyla imza atmasını isteyin.',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 26),

              // KAYDIRARAK TESLİM ET (SLIDE-TO-DELIVER) SÜRGÜSÜ
              SlideToDeliverButton(
                enabled: _isReadyToComplete,
                isLoading: _isSubmitting,
                onSlideComplete: _submitMandatoryPoD,
                enabledText: 'KAYDIRARAK TESLİMATI TAMAMLA ➔',
                disabledText: 'Önce İsim, Fotoğraf ve İmza Ekleyin',
              ).animate().fadeIn(delay: 260.ms, duration: 400.ms),
              const SizedBox(height: 24),
            ],
          ),

          // ÜST MERKEZ KONFETİ PATLAMASI
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              numberOfParticles: 35,
              maxBlastForce: 28,
              minBlastForce: 10,
              emissionFrequency: 0.06,
              colors: const [
                Color(0xFF16A34A),
                Color(0xFF2563EB),
                Color(0xFFF59E0B),
                Color(0xFFEC4899),
                Color(0xFF8B5CF6),
              ],
            ),
          ),

          // KUTLAMA KARTI OVERLAY ("Harika İş! Teslimat Kanıtı Arşivlendi 🎉")
          if (_showCelebrationOverlay)
            Container(
              color: Colors.black.withValues(alpha: 0.45),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: GlassmorphicContainer(
                padding: const EdgeInsets.all(28),
                borderRadius: 26,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF16A34A), Color(0xFF059669)],
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFF16A34A).withValues(alpha: 0.45),
                            blurRadius: 20,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.verified_rounded,
                        size: 50,
                        color: Colors.white,
                      ),
                    )
                        .animate()
                        .scale(
                          begin: const Offset(0.2, 0.2),
                          end: const Offset(1.0, 1.0),
                          duration: 650.ms,
                          curve: Curves.elasticOut,
                        ),
                    const SizedBox(height: 18),
                    const Text(
                      'Harika İş! 🎉\nTeslimat Kanıtı Arşivlendi',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                      ),
                    ).animate().fadeIn(delay: 180.ms),
                    const SizedBox(height: 8),
                    const Text(
                      'Fotoğraf ve imzalı Excel raporu işletme merkezine gönderildi. Sıradaki durağa geçiliyor...',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w500,
                      ),
                    ).animate().fadeIn(delay: 280.ms),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRequirementRow(String text, bool completed) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        children: [
          Icon(
            completed
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked,
            size: 18,
            color:
                completed ? const Color(0xFF16A34A) : const Color(0xFFD97706),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: completed ? FontWeight.w700 : FontWeight.w500,
                color: completed
                    ? const Color(0xFF15803D)
                    : const Color(0xFF92400E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
