import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shimmer/shimmer.dart';

/// 1. YUMUŞAK SAYFA GEÇİŞİ (Fade + Slide + Scale Kombinasyonu)
PageRouteBuilder<T> createSmoothPageRoute<T>(
  Widget page, {
  RouteSettings? settings,
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.0, 0.045),
            end: Offset.zero,
          ).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.965, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

/// 2. GLASSMORPHISM (BUZLU CAM) KART BİLEŞENİ
class GlassmorphicContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final double blurSigma;
  final Color? tintColor;
  final Color? borderColor;
  final List<BoxShadow>? boxShadow;

  const GlassmorphicContainer({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.borderRadius = 18,
    this.blurSigma = 14,
    this.tintColor,
    this.borderColor,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    final baseTint = tintColor ?? Colors.white;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: boxShadow ??
            [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.10),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  baseTint.withValues(alpha: 0.90),
                  baseTint.withValues(alpha: 0.78),
                ],
              ),
              border: Border.all(
                color: borderColor ?? Colors.white.withValues(alpha: 0.65),
                width: 1.2,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 3. MODERN SHIMMER İSKELET YÜKLEME EKRANI + ANİMASYONLU TESLİMAT İKONU
class ShimmerOrderLoadingList extends StatelessWidget {
  final String title;
  final int itemCount;

  const ShimmerOrderLoadingList({
    super.key,
    this.title = 'Canlı operasyon verileri ve akıllı rota hazırlanıyor...',
    this.itemCount = 3,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2563EB), Color(0xFF7C3AED)],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.35),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: const Icon(
                Icons.local_shipping_rounded,
                color: Colors.white,
                size: 24,
              ),
            )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .moveX(begin: -6, end: 6, duration: 700.ms)
                .scaleXY(begin: 0.95, end: 1.06, duration: 700.ms),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: Color(0xFF334155),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...List.generate(itemCount, (index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Shimmer.fromColors(
              baseColor: const Color(0xFFE2E8F0),
              highlightColor: const Color(0xFFF8FAFC),
              child: Container(
                height: 98,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            height: 14,
                            width: 180,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            height: 11,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            height: 11,
                            width: 130,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

/// 4. RADAR DALGALI (PULSE) KURYE ARAÇ İKONU (3D Görünümlü Rozet + Araç Emoji/İkonu)
class PulsingRadarVehiclePin extends StatefulWidget {
  final String label;
  final String? vehicleType;
  final Color primaryColor;

  const PulsingRadarVehiclePin({
    super.key,
    required this.label,
    this.vehicleType,
    this.primaryColor = const Color(0xFF2563EB),
  });

  @override
  State<PulsingRadarVehiclePin> createState() => _PulsingRadarVehiclePinState();
}

class _PulsingRadarVehiclePinState extends State<PulsingRadarVehiclePin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _radarCtrl;

  @override
  void initState() {
    super.initState();
    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _radarCtrl.dispose();
    super.dispose();
  }

  String _vehicleEmoji(String? rawType) {
    final t = (rawType ?? '').toLowerCase();
    if (t.contains('panelvan') || t.contains('van')) return '🚐';
    if (t.contains('kamyon')) return '🚚';
    if (t.contains('binek') || t.contains('otomobil') || t.contains('araba')) {
      return '🚗';
    }
    if (t.contains('bisiklet')) return '🚲';
    return '🛵';
  }

  IconData _vehicleIcon(String? rawType) {
    final t = (rawType ?? '').toLowerCase();
    if (t.contains('panelvan') || t.contains('van')) {
      return Icons.airport_shuttle_rounded;
    }
    if (t.contains('kamyon')) return Icons.local_shipping_rounded;
    if (t.contains('binek') || t.contains('otomobil') || t.contains('araba')) {
      return Icons.directions_car_filled_rounded;
    }
    if (t.contains('bisiklet')) return Icons.pedal_bike_rounded;
    return Icons.two_wheeler_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final emoji = _vehicleEmoji(widget.vehicleType);
    final iconData = _vehicleIcon(widget.vehicleType);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFF0F172A),
                widget.primaryColor,
              ],
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white, width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            '$emoji ${widget.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 48,
          height: 48,
          child: AnimatedBuilder(
            animation: _radarCtrl,
            builder: (context, child) {
              final value = _radarCtrl.value;
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Dış Radar Dalga Halkası 1
                  Transform.scale(
                    scale: 0.7 + (value * 0.9),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.primaryColor
                            .withValues(alpha: (1.0 - value) * 0.42),
                        border: Border.all(
                          color: widget.primaryColor
                              .withValues(alpha: (1.0 - value) * 0.75),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                  // 3D Görünümlü Araç Küresi
                  child!,
                ],
              );
            },
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.3, -0.3),
                  radius: 0.9,
                  colors: [
                    Color.lerp(widget.primaryColor, Colors.white, 0.35)!,
                    widget.primaryColor,
                    Color.lerp(widget.primaryColor, Colors.black, 0.35)!,
                  ],
                ),
                border: Border.all(color: Colors.white, width: 2.2),
                boxShadow: [
                  BoxShadow(
                    color: widget.primaryColor.withValues(alpha: 0.55),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Icon(
                iconData,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 5. ZIPLAYAN HEDEF PİNLERİ (`Curves.elasticOut`) & 24s PARLAYAN YEŞİL TESLİMAT PİNİ
class BouncingOrderMapPin extends StatelessWidget {
  final String label;
  final bool isDelivered;
  final bool isFirstStop;
  final bool isSelectedAddress;
  final VoidCallback? onTap;

  const BouncingOrderMapPin({
    super.key,
    required this.label,
    this.isDelivered = false,
    this.isFirstStop = false,
    this.isSelectedAddress = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color badgeColor = isDelivered
        ? const Color(0xFF15803D)
        : (isSelectedAddress || isFirstStop
            ? const Color(0xFFDC2626)
            : const Color(0xFF1D4ED8));

    final Color iconColor = isDelivered
        ? const Color(0xFF16A34A)
        : (isSelectedAddress || isFirstStop
            ? const Color(0xFFEF4444)
            : const Color(0xFF2563EB));

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 900),
      curve: Curves.elasticOut,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, -24 * (1 - value)),
          child: Transform.scale(
            scale: 0.4 + (0.6 * value),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    badgeColor,
                    Color.lerp(badgeColor, Colors.black, 0.22)!,
                  ],
                ),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: isDelivered
                      ? const Color(0xFF86EFAC)
                      : Colors.white.withValues(alpha: 0.8),
                  width: 1.1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: badgeColor.withValues(alpha: 0.45),
                    blurRadius: isDelivered ? 10 : 6,
                    spreadRadius: isDelivered ? 1 : 0,
                  ),
                ],
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Container(
              decoration: isDelivered
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF22C55E).withValues(alpha: 0.65),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    )
                  : null,
              child: Icon(
                isDelivered
                    ? Icons.check_circle_rounded
                    : (isSelectedAddress
                        ? Icons.add_location_alt_rounded
                        : Icons.location_on_rounded),
                size: 38,
                color: iconColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 6. KURYE GÜNLÜK GÖREV İLERLEME ÇUBUĞU (GAMIFICATION)
class DriverDailyProgressBanner extends StatelessWidget {
  final int completedCount;
  final int totalCount;

  const DriverDailyProgressBanner({
    super.key,
    required this.completedCount,
    required this.totalCount,
  });

  @override
  Widget build(BuildContext context) {
    final safeTotal = totalCount <= 0 ? 1 : totalCount;
    final progress = (completedCount / safeTotal).clamp(0.0, 1.0);
    final isAllDone = totalCount > 0 && completedCount >= totalCount;

    return GlassmorphicContainer(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      borderRadius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                isAllDone ? '🏆' : '🔥',
                style: const TextStyle(fontSize: 18),
              )
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .scaleXY(begin: 0.92, end: 1.15, duration: 650.ms),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Bugünkü Performansın: $completedCount / $totalCount Teslimat Tamamlandı 🔥',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isAllDone
                        ? [const Color(0xFF16A34A), const Color(0xFF059669)]
                        : [const Color(0xFFEA580C), const Color(0xFFD97706)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '%${(progress * 100).round()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.0, end: progress),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, animVal, _) {
                return LinearProgressIndicator(
                  value: animVal,
                  minHeight: 8,
                  backgroundColor: const Color(0xFFE2E8F0),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Color.lerp(
                      const Color(0xFFF97316),
                      const Color(0xFF16A34A),
                      animVal,
                    )!,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 7. KAYDIRARAK TESLİM ET (SLIDE-TO-DELIVER) EĞLENCELİ SÜRGÜ BİLEŞENİ
class SlideToDeliverButton extends StatefulWidget {
  final bool enabled;
  final bool isLoading;
  final VoidCallback onSlideComplete;
  final String enabledText;
  final String disabledText;

  const SlideToDeliverButton({
    super.key,
    required this.enabled,
    required this.isLoading,
    required this.onSlideComplete,
    this.enabledText = 'KAYDIRARAK TESLİMATI TAMAMLA ➔',
    this.disabledText = 'Önce İsim, Fotoğraf ve İmza Ekleyin',
  });

  @override
  State<SlideToDeliverButton> createState() => _SlideToDeliverButtonState();
}

class _SlideToDeliverButtonState extends State<SlideToDeliverButton> {
  double _dragPercent = 0.0;

  void _onHorizontalDragUpdate(DragUpdateDetails details, double maxWidth) {
    if (!widget.enabled || widget.isLoading) return;
    final usable = (maxWidth - 64).clamp(1.0, double.infinity);
    setState(() {
      _dragPercent = (_dragPercent + (details.delta.dx / usable)).clamp(0.0, 1.0);
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!widget.enabled || widget.isLoading) return;
    if (_dragPercent >= 0.78) {
      setState(() => _dragPercent = 1.0);
      widget.onSlideComplete();
    } else {
      setState(() => _dragPercent = 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && !widget.isLoading;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final knobOffset = _dragPercent * (maxWidth - 64);

        return GestureDetector(
          onTap: active ? widget.onSlideComplete : null,
          onHorizontalDragUpdate: (d) => _onHorizontalDragUpdate(d, maxWidth),
          onHorizontalDragEnd: _onHorizontalDragEnd,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              gradient: active
                  ? const LinearGradient(
                      colors: [
                        Color(0xFF16A34A),
                        Color(0xFF059669),
                        Color(0xFF0D9488),
                      ],
                    )
                  : const LinearGradient(
                      colors: [Color(0xFFCBD5E1), Color(0xFF94A3B8)],
                    ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: const Color(0xFF16A34A).withValues(alpha: 0.40),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Arka Plan Parlayan Metin
                Padding(
                  padding: const EdgeInsets.only(left: 56, right: 16),
                  child: widget.isLoading
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                'TESLİMAT KANITI VE EXCEL KAYDEDİLİYOR...',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        )
                      : active
                          ? Shimmer.fromColors(
                              baseColor: Colors.white,
                              highlightColor: const Color(0xFFFEF08A),
                              child: Text(
                                widget.enabledText,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 13.5,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            )
                          : Text(
                              widget.disabledText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFF475569),
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                ),

                // Kaydırılabilir Yuvarlak Sürgü Topuzu
                Positioned(
                  left: 5 + knobOffset,
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      active
                          ? Icons.double_arrow_rounded
                          : Icons.lock_outline_rounded,
                      color: active
                          ? const Color(0xFF16A34A)
                          : const Color(0xFF64748B),
                      size: 26,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 8. MÜŞTERİ CANLI TAKİP EKRANI: "CANLI YAYIN 🟢" ROZETİ VE 4 ADIMLI ZAMAN ÇİZELGESİ
class AnimatedDeliveryTimeline extends StatelessWidget {
  final int currentStepIndex; // 0: Hazırlandı, 1: Kurye Yolda, 2: Yaklaştı, 3: Teslim Edildi
  final Color activeColor;

  const AnimatedDeliveryTimeline({
    super.key,
    required this.currentStepIndex,
    this.activeColor = const Color(0xFF16A34A),
  });

  static const List<Map<String, dynamic>> _steps = [
    {'label': 'Hazırlandı', 'icon': Icons.inventory_2_rounded},
    {'label': 'Kurye Yolda', 'icon': Icons.two_wheeler_rounded},
    {'label': 'Adresinize Yaklaştı', 'icon': Icons.near_me_rounded},
    {'label': 'Teslim Edildi', 'icon': Icons.verified_rounded},
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(_steps.length * 2 - 1, (idx) {
        if (idx.isOdd) {
          final stepBefore = idx ~/ 2;
          final completed = currentStepIndex > stepBefore;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 450),
              height: 3.5,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: completed ? activeColor : const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        }

        final stepIdx = idx ~/ 2;
        final step = _steps[stepIdx];
        final isCompleted = currentStepIndex >= stepIdx;
        final isCurrent = currentStepIndex == stepIdx;

        Widget circle = AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: isCurrent ? 36 : 30,
          height: isCurrent ? 36 : 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isCompleted ? activeColor : const Color(0xFFE2E8F0),
            boxShadow: isCurrent
                ? [
                    BoxShadow(
                      color: activeColor.withValues(alpha: 0.45),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            step['icon'] as IconData,
            size: isCurrent ? 19 : 16,
            color: isCompleted ? Colors.white : const Color(0xFF64748B),
          ),
        );

        if (isCurrent) {
          circle = circle
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .scaleXY(begin: 0.94, end: 1.08, duration: 750.ms);
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            circle,
            const SizedBox(height: 5),
            Text(
              step['label'] as String,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isCompleted ? FontWeight.w800 : FontWeight.w500,
                color: isCompleted
                    ? const Color(0xFF0F172A)
                    : const Color(0xFF64748B),
              ),
            ),
          ],
        );
      }),
    );
  }
}
