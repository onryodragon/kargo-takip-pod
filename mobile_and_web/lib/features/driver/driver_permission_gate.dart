import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// Kurye Ana Ekranı (`DriverHomeScreen`) açılmadan önce çalışan Zorunlu İzin Kapısı:
/// 1. Konum İzni (Her Zaman / Uygulama Kullanılırken)
/// 2. Pil Optimizasyonunu Yoksayma İzni (`Permission.ignoreBatteryOptimizations`)
///
/// Bu izinler onaylanmadan kurye görev ekranı açılmaz; böylece ekran kapansa bile
/// saniyelik (1 sn) GPS akışı işletme haritasında kesintisiz devam eder.
class DriverPermissionGate extends StatefulWidget {
  final Widget child;

  const DriverPermissionGate({
    super.key,
    required this.child,
  });

  @override
  State<DriverPermissionGate> createState() => _DriverPermissionGateState();
}

class _DriverPermissionGateState extends State<DriverPermissionGate>
    with WidgetsBindingObserver {
  bool _checking = true;
  bool _locationGranted = false;
  bool _batteryOptimizationIgnored = false;
  String? _errorText;

  bool get _isAndroidNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _allGranted =>
      _locationGranted && (!_isAndroidNative || _batteryOptimizationIgnored);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkCurrentPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkCurrentPermissions();
    }
  }

  Future<void> _checkCurrentPermissions() async {
    if (kIsWeb) {
      setState(() {
        _locationGranted = true;
        _batteryOptimizationIgnored = true;
        _checking = false;
      });
      return;
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      final locPerm = await Geolocator.checkPermission();
      final hasLoc = serviceEnabled &&
          (locPerm == LocationPermission.always ||
              locPerm == LocationPermission.whileInUse);

      bool hasBattery = true;
      if (_isAndroidNative) {
        hasBattery = await Permission.ignoreBatteryOptimizations.isGranted;
      }

      if (!mounted) return;
      setState(() {
        _locationGranted = hasLoc;
        _batteryOptimizationIgnored = hasBattery;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _errorText = 'İzin durumu kontrol edilemedi: $e';
      });
    }
  }

  Future<void> _requestLocationPermission() async {
    setState(() => _errorText = null);
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await Geolocator.openLocationSettings();
        setState(() {
          _errorText = 'Lütfen cihazınızın GPS / Konum servisini açın.';
        });
        return;
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        await openAppSettings();
        return;
      }

      // Arka plan konum iznini de iste ("Her Zaman İzin Ver")
      if (_isAndroidNative && perm == LocationPermission.whileInUse) {
        try {
          await Permission.locationAlways.request();
        } catch (_) {}
      }

      await _checkCurrentPermissions();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = 'Konum izni alınamadı: $e');
    }
  }

  Future<void> _requestBatteryExemption() async {
    setState(() => _errorText = null);
    try {
      if (_isAndroidNative) {
        final status = await Permission.ignoreBatteryOptimizations.request();
        if (!status.isGranted) {
          await openAppSettings();
        }
      }
      await _checkCurrentPermissions();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = 'Pil izni alınamadı: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_allGranted) {
      return widget.child;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
        title: const Text('Zorunlu Kurye Cihaz İzinleri'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.gps_fixed_rounded,
                      size: 54,
                      color: Color(0xFF2563EB),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Saniyelik Canlı Konum & Arka Plan İzni',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Kurye görev ekranına geçebilmek ve telefonunuzun ekranı kapandığında bile haritada saniyelik (1 sn) kesintisiz görünebilmek için aşağıdaki 2 izni onaylamanız zorunludur:',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 1. Konum İzni Kartı
                    _PermissionStepTile(
                      stepNumber: '1',
                      title: 'Canlı GPS Konum İzni (Her Zaman)',
                      subtitle: _locationGranted
                          ? 'Onaylandı — GPS sinyaliniz aktif'
                          : 'Konum izni vermeniz gerekiyor',
                      isGranted: _locationGranted,
                      buttonText: 'Konum İznini Onayla',
                      onPressed: _requestLocationPermission,
                    ),
                    const SizedBox(height: 12),

                    // 2. Pil Optimizasyonu Kartı
                    if (_isAndroidNative)
                      _PermissionStepTile(
                        stepNumber: '2',
                        title: 'Arka Plan Pil Kısıtlamasını Kaldır',
                        subtitle: _batteryOptimizationIgnored
                            ? 'Onaylandı — Ekran kapandığında GPS kesilmez'
                            : 'Pil tasarrufunu yoksayma izni gerekiyor',
                        isGranted: _batteryOptimizationIgnored,
                        buttonText: 'Pil İznini Onayla',
                        onPressed: _requestBatteryExemption,
                      ),

                    if (_errorText != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _errorText!,
                          style: TextStyle(
                            color: Colors.red.shade800,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: _checkCurrentPermissions,
                      icon: const Icon(Icons.refresh),
                      label: const Text('İzin Durumunu Yeniden Kontrol Et'),
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

class _PermissionStepTile extends StatelessWidget {
  final String stepNumber;
  final String title;
  final String subtitle;
  final bool isGranted;
  final String buttonText;
  final VoidCallback onPressed;

  const _PermissionStepTile({
    required this.stepNumber,
    required this.title,
    required this.subtitle,
    required this.isGranted,
    required this.buttonText,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isGranted ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isGranted ? const Color(0xFF86EFAC) : Colors.grey.shade300,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: isGranted
                    ? const Color(0xFF16A34A)
                    : const Color(0xFF1E3A8A),
                child: isGranted
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : Text(
                        stepNumber,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isGranted
                            ? const Color(0xFF166534)
                            : Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!isGranted) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.security_rounded, size: 18),
              label: Text(buttonText),
            ),
          ],
        ],
      ),
    );
  }
}
