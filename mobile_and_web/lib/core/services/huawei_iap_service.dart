import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

/// Huawei In-App Purchases (IAP) Servisi:
/// Tek seferlik, ömür boyu "pro_lifetime_10eur" satın alma ve satın alımı geri yükleme (Restore) akışını yönetir.
class HuaweiIapService {
  static const String channelName = 'com.podsystem.kargo_takip_pod/huawei_iap';
  static const MethodChannel _channel = MethodChannel(channelName);

  static const String proProductId = 'pro_lifetime_10eur';
  static const int priceTypeNonConsumable = 2; // IapClient.PriceType.IN_APP_NONCONSUMABLE
  static const String prefProActiveKey = 'pod_is_pro_lifetime_active';

  /// Cihazda yerel olarak Pro lisansının aktif olup olmadığını kontrol eder.
  static Future<bool> isProLocallyActive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefProActiveKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Cihazda Pro durumunu yerel olarak kaydeder.
  static Future<void> setProLocallyActive(bool active) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefProActiveKey, active);
    } catch (_) {}
  }

  /// HMS Core IAP ortamının hazır olup olmadığını kontrol eder.
  static Future<bool> isEnvReady() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('isEnvReady');
      return result?['isReady'] == true;
    } catch (e) {
      debugPrint('HuaweiIapService isEnvReady error: $e');
      return false;
    }
  }

  /// "Ömür Boyu Satın Al (10 €)" akışını başlatır.
  /// Satın alma başarılı olduğunda:
  /// 1. Durumu yerel cihaza kaydeder (SharedPreferences)
  /// 2. Backend'e `activatePro` isteği atarak hem tenant hem kullanıcı kaydında `is_pro = true` yapar.
  static Future<Map<String, dynamic>> buyProLifetime({
    required ApiClient apiClient,
  }) async {
    // Web veya test ortamında doğrudan backend aktivasyonu
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      final activated = await apiClient.activatePro();
      if (activated) {
        await setProLocallyActive(true);
        return {'success': true, 'message': 'Pro aktif edildi.'};
      }
      return {'success': false, 'message': 'Aktivasyon başarısız oldu.'};
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'createPurchaseIntent',
        {
          'productId': proProductId,
          'priceType': priceTypeNonConsumable,
        },
      );

      final success = result?['success'] == true;
      if (success) {
        // 1. Cihazda kalıcı olarak kaydet
        await setProLocallyActive(true);

        // 2. Backend (Supabase / SQLite) tenant kaydında is_pro = true yap
        await apiClient.activatePro();

        return {
          'success': true,
          'alreadyOwned': result?['alreadyOwned'] == true,
          'data': result,
        };
      }

      final isCancelled = result?['cancelled'] == true;
      return {
        'success': false,
        'cancelled': isCancelled,
        'errMsg': result?['errMsg'] ?? result?['message'] ?? 'Satın alma iptal edildi veya tamamlanamadı.',
      };
    } catch (e) {
      debugPrint('HuaweiIapService buyProLifetime exception: $e');
      return {
        'success': false,
        'errMsg': e.toString(),
      };
    }
  }

  /// "Satın Alımı Geri Yükle (Restore Purchase)" akışı:
  /// Huawei IAP `obtainOwnedPurchases` ile daha önce satın alınmışsa kilidi hemen açar.
  static Future<Map<String, dynamic>> restorePurchases({
    required ApiClient apiClient,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      // Web üzerinde sunucu Pro durumunu kontrol et
      final status = await apiClient.checkProStatus();
      if (status) {
        await setProLocallyActive(true);
        return {'hasOwned': true};
      }
      return {'hasOwned': false};
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'obtainOwnedPurchases',
        {
          'priceType': priceTypeNonConsumable,
        },
      );

      final hasOwned = result?['hasOwned'] == true;
      if (hasOwned) {
        // Cihazda ve backend'de lisansı etkinleştir
        await setProLocallyActive(true);
        await apiClient.activatePro();
        return {'hasOwned': true, 'data': result};
      }

      // Sunucuda daha önceden pro yapılmış mı kontrol et
      final isServerPro = await apiClient.checkProStatus();
      if (isServerPro) {
        await setProLocallyActive(true);
        return {'hasOwned': true};
      }

      return {'hasOwned': false};
    } catch (e) {
      debugPrint('HuaweiIapService restorePurchases exception: $e');
      return {'hasOwned': false, 'error': e.toString()};
    }
  }
}
