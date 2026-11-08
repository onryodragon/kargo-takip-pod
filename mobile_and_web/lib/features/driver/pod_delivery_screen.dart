import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:signature/signature.dart';

import '../../core/api/api_client.dart';
import '../../core/services/location_service.dart';

/// İŞ KURALI #4 & #6: Zorunlu Teslimat Kanıtı (PoD: Fotoğraf + İmza) Ekranı.
///
/// Kritik Kural:
/// Kurye;
/// 1) Teslim alan kişinin adını yazmadan,
/// 2) Kamera ile teslimat fotoğrafını çekmeden (`_photoBytes == null`),
/// 3) Ekrandaki imza pedine alıcının imzasını almadan (`_signatureController.isEmpty`)
/// "TESLİMATI TAMAMLA" butonu kesinlikle pasiftir (`onPressed: null`).
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

  Uint8List? _photoBytes;
  bool _hasSignature = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
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

      final currentCoord = await widget.locationService.getCurrentCoordinateOrFallback();

      final result = await widget.apiClient.deliverOrderWithPoD(
        orderId: widget.order['id'].toString(),
        recipientName: _recipientCtrl.text.trim(),
        deliveredLat: currentCoord.latitude,
        deliveredLng: currentCoord.longitude,
        photoBytes: _photoBytes!,
        signaturePngBytes: sigPngBytes,
      );

      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Teslimat tamamlanamadı: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
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
        title: Text('Zorunlu Teslimat Kanıtı — #${widget.order['order_number']}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          // DURUM KONTROL LİSTESİ BANNER'I
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _isReadyToComplete
                  ? const Color(0xFFF0FDF4)
                  : const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isReadyToComplete
                    ? const Color(0xFF86EFAC)
                    : const Color(0xFFFDE68A),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isReadyToComplete
                      ? 'Tüm zorunlu teslimat kanıtları hazır! Teslimatı tamamlayabilirsiniz.'
                      : 'Teslimatı tamamlamak için aşağıdaki 3 zorunlu adımı eksiksiz doldurun:',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 8),
                _buildRequirementRow('1. Teslim Alan Kişinin Adı Soyadı', hasRecipient),
                _buildRequirementRow('2. Teslimat Fotoğrafı (Kamera)', hasPhoto),
                _buildRequirementRow('3. Alıcının Ekrana İmzası', hasSig),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ADIM 1: TESLİM ALAN KİŞİNİN ADI SOYADI
          TextField(
            controller: _recipientCtrl,
            decoration: const InputDecoration(
              labelText: '1. Teslim Alan Kişinin Adı Soyadı (Zorunlu) *',
              prefixIcon: Icon(Icons.badge_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),

          // ADIM 2: ZORUNLU TESLİMAT FOTOĞRAFI (KAMERA)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '2. Teslimat Fotoğrafı (Zorunlu) *',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              TextButton.icon(
                onPressed: _isSubmitting ? null : _captureDeliveryPhoto,
                icon: const Icon(Icons.camera_alt_rounded),
                label: Text(_photoBytes == null ? 'Fotoğraf Çek' : 'Yeniden Çek'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: _isSubmitting ? null : _captureDeliveryPhoto,
            child: Container(
              height: 190,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hasPhoto ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1),
                  width: hasPhoto ? 2 : 1,
                ),
              ),
              child: _photoBytes != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _photoBytes!,
                        width: double.infinity,
                        height: 190,
                        fit: BoxFit.cover,
                      ),
                    )
                  : const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_a_photo_rounded,
                          size: 46,
                          color: Color(0xFF64748B),
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Kamerayı açıp paketin/teslimatın fotoğrafını çekmek için dokunun',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 22),

          // ADIM 3: ZORUNLU MÜŞTERİ İMZA PEDİ
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '3. Alıcı İmza Pedi (Zorunlu) *',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
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
          Container(
            height: 185,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: hasSig ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1),
                width: hasSig ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Signature(
                controller: _signatureController,
                height: 185,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Lütfen alıcıdan yukarıdaki beyaz alana parmağıyla imza atmasını isteyin.',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 26),

          // KRİTİK BUTON: Fotoğraf VE İmza tamamlanmadan kesinlikle PASİF (onPressed: null)
          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _isReadyToComplete ? _submitMandatoryPoD : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A),
                disabledBackgroundColor: const Color(0xFFCBD5E1),
                disabledForegroundColor: const Color(0xFF64748B),
              ),
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.verified_rounded),
              label: Text(
                _isSubmitting
                    ? 'KAYDEDİLİYOR VE EXCEL RAPORLANIYOR...'
                    : (_isReadyToComplete
                        ? 'TESLİMATI TAMAMLA (FOTOĞRAF + İMZA ONAYLI)'
                        : 'TESLİMATI TAMAMLA (FOTOĞRAF VE İMZA ZORUNLU)'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequirementRow(String text, bool completed) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(
            completed ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            size: 18,
            color: completed ? const Color(0xFF16A34A) : const Color(0xFFD97706),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: completed ? FontWeight.w600 : FontWeight.normal,
              color: completed ? const Color(0xFF15803D) : const Color(0xFF92400E),
            ),
          ),
        ],
      ),
    );
  }
}
