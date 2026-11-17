package com.podsystem.kargo_takip_pod

import android.app.Activity
import android.content.Intent
import android.util.Log
import com.huawei.hms.iap.Iap
import com.huawei.hms.iap.IapApiException
import com.huawei.hms.iap.IapClient
import com.huawei.hms.iap.entity.OrderStatusCode
import com.huawei.hms.iap.entity.OwnedPurchasesReq
import com.huawei.hms.iap.entity.PurchaseIntentReq
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "KargoTakipHuaweiIap"
        private const val CHANNEL = "com.podsystem.kargo_takip_pod/huawei_iap"
        private const val REQ_CODE_BUY = 6601
        private const val REQ_CODE_ENV = 6602
        const val PRO_PRODUCT_ID = "pro_lifetime_10eur"
    }

    private var pendingBuyResult: MethodChannel.Result? = null
    private var pendingEnvResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnvReady" -> {
                    checkIapEnvReady(result)
                }
                "createPurchaseIntent" -> {
                    val productId = call.argument<String>("productId") ?: PRO_PRODUCT_ID
                    val priceType = call.argument<Int>("priceType") ?: IapClient.PriceType.IN_APP_NONCONSUMABLE
                    startPurchaseIntent(productId, priceType, result)
                }
                "obtainOwnedPurchases" -> {
                    val priceType = call.argument<Int>("priceType") ?: IapClient.PriceType.IN_APP_NONCONSUMABLE
                    queryOwnedPurchases(priceType, result)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun checkIapEnvReady(result: MethodChannel.Result) {
        try {
            val iapClient = Iap.getIapClient(this)
            val task = iapClient.isEnvReady
            task.addOnSuccessListener {
                result.success(mapOf("isReady" to true))
            }.addOnFailureListener { e ->
                Log.w(TAG, "isEnvReady failure: ${e.message}")
                if (e is IapApiException) {
                    val status = e.status
                    if (status != null && status.hasResolution()) {
                        try {
                            pendingEnvResult = result
                            status.startResolutionForResult(this, REQ_CODE_ENV)
                            return@addOnFailureListener
                        } catch (resErr: Exception) {
                            Log.e(TAG, "startResolutionForResult failed: ${resErr.message}")
                        }
                    }
                    result.success(mapOf(
                        "isReady" to false,
                        "statusCode" to e.statusCode,
                        "message" to (e.message ?: "HMS Core IAP hazır değil")
                    ))
                } else {
                    result.success(mapOf(
                        "isReady" to false,
                        "message" to (e.message ?: "Bilinmeyen hata")
                    ))
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "checkIapEnvReady catch: ${t.message}", t)
            result.success(mapOf("isReady" to false, "message" to (t.message ?: "IAP başlatılamadı")))
        }
    }

    private fun startPurchaseIntent(productId: String, priceType: Int, result: MethodChannel.Result) {
        try {
            val iapClient = Iap.getIapClient(this)
            val req = PurchaseIntentReq().apply {
                this.productId = productId
                this.priceType = priceType
                this.developerPayload = "kargo_takip_pro_${System.currentTimeMillis()}"
            }

            val task = iapClient.createPurchaseIntent(req)
            task.addOnSuccessListener { purchaseIntentResult ->
                val status = purchaseIntentResult.status
                if (status != null && status.hasResolution()) {
                    try {
                        pendingBuyResult = result
                        status.startResolutionForResult(this, REQ_CODE_BUY)
                    } catch (resErr: Exception) {
                        Log.e(TAG, "startResolutionForResult buy failed", resErr)
                        result.error("RESOLUTION_FAILED", resErr.message, null)
                    }
                } else {
                    Log.w(TAG, "PurchaseIntentResult has no resolution")
                    result.error("NO_RESOLUTION", "Huawei IAP satın alma penceresi açılamadı.", null)
                }
            }.addOnFailureListener { e ->
                Log.e(TAG, "createPurchaseIntent failed: ${e.message}", e)
                if (e is IapApiException) {
                    if (e.statusCode == OrderStatusCode.ORDER_PRODUCT_OWNED) {
                        // Kullanıcı ürüne zaten sahip
                        result.success(mapOf(
                            "success" to true,
                            "alreadyOwned" to true,
                            "productId" to productId
                        ))
                        return@addOnFailureListener
                    }
                    result.success(mapOf(
                        "success" to false,
                        "statusCode" to e.statusCode,
                        "message" to (e.message ?: "IAP satın alma başlatılamadı")
                    ))
                } else {
                    result.success(mapOf(
                        "success" to false,
                        "message" to (e.message ?: "Satın alma başlatılamadı")
                    ))
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "startPurchaseIntent catch: ${t.message}", t)
            result.error("IAP_ERROR", t.message, null)
        }
    }

    private fun queryOwnedPurchases(priceType: Int, result: MethodChannel.Result) {
        try {
            val iapClient = Iap.getIapClient(this)
            val req = OwnedPurchasesReq().apply {
                this.priceType = priceType
            }

            val task = iapClient.obtainOwnedPurchases(req)
            task.addOnSuccessListener { ownedResult ->
                val inAppPurchaseDataList = ownedResult.inAppPurchaseDataList ?: emptyList<String>()
                val itemList = ownedResult.itemList ?: emptyList<String>()
                val hasProOwned = itemList.contains(PRO_PRODUCT_ID) ||
                        inAppPurchaseDataList.any { it.contains(PRO_PRODUCT_ID) }

                Log.i(TAG, "obtainOwnedPurchases success. hasProOwned=$hasProOwned, items=$itemList")
                result.success(mapOf(
                    "hasOwned" to hasProOwned,
                    "itemList" to itemList,
                    "inAppPurchaseDataList" to inAppPurchaseDataList
                ))
            }.addOnFailureListener { e ->
                Log.w(TAG, "obtainOwnedPurchases failed: ${e.message}")
                result.success(mapOf(
                    "hasOwned" to false,
                    "error" to (e.message ?: "Sorgulama başarısız")
                ))
            }
        } catch (t: Throwable) {
            Log.e(TAG, "queryOwnedPurchases catch: ${t.message}", t)
            result.success(mapOf("hasOwned" to false, "error" to (t.message ?: "Hata")))
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {
            REQ_CODE_BUY -> {
                val buyCallback = pendingBuyResult
                pendingBuyResult = null

                if (buyCallback != null) {
                    if (data != null) {
                        try {
                            val purchaseResultInfo = Iap.getIapClient(this).parsePurchaseResultInfoFromIntent(data)
                            Log.i(TAG, "PurchaseResultInfo returnCode: ${purchaseResultInfo.returnCode}")

                            when (purchaseResultInfo.returnCode) {
                                OrderStatusCode.ORDER_STATE_SUCCESS -> {
                                    buyCallback.success(mapOf(
                                        "success" to true,
                                        "productId" to PRO_PRODUCT_ID,
                                        "inAppPurchaseData" to (purchaseResultInfo.inAppPurchaseData ?: ""),
                                        "inAppDataSignature" to (purchaseResultInfo.inAppDataSignature ?: "")
                                    ))
                                }
                                OrderStatusCode.ORDER_STATE_CANCEL -> {
                                    buyCallback.success(mapOf(
                                        "success" to false,
                                        "cancelled" to true,
                                        "returnCode" to purchaseResultInfo.returnCode
                                    ))
                                }
                                OrderStatusCode.ORDER_PRODUCT_OWNED -> {
                                    buyCallback.success(mapOf(
                                        "success" to true,
                                        "alreadyOwned" to true,
                                        "productId" to PRO_PRODUCT_ID
                                    ))
                                }
                                else -> {
                                    buyCallback.success(mapOf(
                                        "success" to false,
                                        "returnCode" to purchaseResultInfo.returnCode,
                                        "errMsg" to (purchaseResultInfo.errMsg ?: "Satın alma başarısız")
                                    ))
                                }
                            }
                        } catch (t: Throwable) {
                            Log.e(TAG, "parsePurchaseResultInfo error", t)
                            buyCallback.success(mapOf("success" to false, "error" to t.message))
                        }
                    } else {
                        buyCallback.success(mapOf("success" to false, "cancelled" to true))
                    }
                }
            }
            REQ_CODE_ENV -> {
                val envCallback = pendingEnvResult
                pendingEnvResult = null
                envCallback?.success(mapOf("isReady" to (resultCode == Activity.RESULT_OK)))
            }
        }
    }
}
