import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api/api_client.dart';
import '../../core/services/smart_routing_service.dart';

/// Sadece İşletme Sahibi (Admin) tarafından kullanılabilen;
/// - En üstte Ücretsiz Adres Arama ve Otomatik Öneri Çubuğu (Nominatim / Photon, 400ms debounce)
/// - Haritadan (`flutter_map` OpenStreetMap) dokunarak ince ayarlı pin seçimi
/// - Tekli veya Çoklu Görev (Sınırsız Durak) Atama ve OSRM Akıllı Rota Önizleme Ekranı.
class CreateOrderScreen extends StatefulWidget {
  final ApiClient apiClient;
  final List<Map<String, dynamic>> availableDrivers;
  final LatLng initialCenter;
  final String? initialAddress;

  const CreateOrderScreen({
    super.key,
    required this.apiClient,
    required this.availableDrivers,
    this.initialCenter = const LatLng(40.9923, 29.1244),
    this.initialAddress,
  });

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

class _CreateOrderScreenState extends State<CreateOrderScreen> {
  final MapController _mapController = MapController();

  // Üstteki Adres Arama (Autocomplete) Kontrolleri
  final _searchCtrl = TextEditingController();
  Timer? _debounceTimer;
  List<AddressSuggestion> _suggestions = [];
  bool _isSearchingAddress = false;

  // Sipariş Formu Kontrolleri
  final _orderNumberCtrl = TextEditingController();
  final _customerNameCtrl = TextEditingController();
  final _customerPhoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  late LatLng _selectedDest;
  String? _selectedDriverId;
  bool _isSubmitting = false;

  // Çoklu Görev / Çoklu Durak Kuyruğu (Bir kuryeye tek seferde sınırsız durak atayabilme)
  final List<Map<String, dynamic>> _queuedStops = [];
  List<Map<String, dynamic>> _optimizedPreviewStops = [];
  List<LatLng> _previewPolyline = [];

  @override
  void initState() {
    super.initState();
    _selectedDest = widget.initialCenter;
    if (widget.initialAddress != null && widget.initialAddress!.trim().isNotEmpty) {
      _addressCtrl.text = widget.initialAddress!.trim();
      _searchCtrl.text = widget.initialAddress!.trim();
    }
    if (widget.availableDrivers.isNotEmpty) {
      _selectedDriverId = widget.availableDrivers.first['id']?.toString();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchCtrl.dispose();
    _orderNumberCtrl.dispose();
    _customerNameCtrl.dispose();
    _customerPhoneCtrl.dispose();
    _addressCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  /// 400ms Debounce ile OpenStreetMap Nominatim / Photon Otomatik Adres Önerisi
  void _onSearchQueryChanged(String query) {
    _debounceTimer?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _suggestions = [];
        _isSearchingAddress = false;
      });
      return;
    }

    setState(() => _isSearchingAddress = true);
    _debounceTimer = Timer(const Duration(milliseconds: 400), () async {
      final results = await SmartRoutingService.searchAddressAutocomplete(
        query,
        backendBaseUrl: ApiClient.baseUrl,
        authToken: widget.apiClient.accessToken,
        limit: 6,
      );
      if (mounted) {
        setState(() {
          _suggestions = results;
          _isSearchingAddress = false;
        });
      }
    });
  }

  /// Öneri listesinden bir adrese tıklandığında:
  /// 1. Harita kamerası otomatik olarak o koordinata (`dest_lat`, `dest_lng`) odaklanır ve pini oraya koyar.
  /// 2. Açık adres kutusu otomatik dolar.
  void _selectAddressSuggestion(AddressSuggestion item) {
    FocusScope.of(context).unfocus();
    setState(() {
      _selectedDest = item.latLng;
      _addressCtrl.text = item.displayName;
      _searchCtrl.text = item.displayName;
      _suggestions = [];
    });
    _mapController.move(item.latLng, 16.5);
  }

  LatLng? _getSelectedDriverLivePosition() {
    if (_selectedDriverId == null) return null;
    for (final d in widget.availableDrivers) {
      if (d['id']?.toString() == _selectedDriverId) {
        if (d['last_lat'] != null && d['last_lng'] != null) {
          return LatLng(
            (d['last_lat'] as num).toDouble(),
            (d['last_lng'] as num).toDouble(),
          );
        }
      }
    }
    return null;
  }

  Future<void> _recalculateQueuedRoute() async {
    if (_queuedStops.isEmpty) {
      setState(() {
        _optimizedPreviewStops = [];
        _previewPolyline = [];
      });
      return;
    }

    final driverStart = _getSelectedDriverLivePosition();
    final optimized = SmartRoutingService.optimizeOrdersNearestNeighbor(
      _queuedStops,
      startPosition: driverStart,
    );

    final waypoints = <LatLng>[
      if (driverStart != null) driverStart,
      ...optimized.map(
        (s) => LatLng(
          (s['dest_lat'] as num).toDouble(),
          (s['dest_lng'] as num).toDouble(),
        ),
      ),
    ];

    setState(() {
      _optimizedPreviewStops = optimized;
    });

    if (waypoints.length >= 2) {
      final osrm = await SmartRoutingService.fetchOsrmRoadRoute(waypoints);
      if (mounted) {
        setState(() {
          _previewPolyline = osrm.polylinePoints;
        });
      }
    } else {
      setState(() {
        _previewPolyline = [];
      });
    }
  }

  void _addCurrentFormToStopQueue() {
    if (_customerNameCtrl.text.trim().isEmpty ||
        _customerPhoneCtrl.text.trim().isEmpty ||
        _addressCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Durak eklemek için müşteri adı, telefonu ve teslimat adresi zorunludur.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _queuedStops.add({
        if (_orderNumberCtrl.text.trim().isNotEmpty)
          'order_number': _orderNumberCtrl.text.trim(),
        'customer_name': _customerNameCtrl.text.trim(),
        'customer_phone': _customerPhoneCtrl.text.trim(),
        'delivery_address': _addressCtrl.text.trim(),
        'delivery_notes':
            _notesCtrl.text.trim().isNotEmpty ? _notesCtrl.text.trim() : null,
        'dest_lat': _selectedDest.latitude,
        'dest_lng': _selectedDest.longitude,
        'assigned_driver_id': _selectedDriverId,
      });

      _orderNumberCtrl.clear();
      _customerNameCtrl.clear();
      _customerPhoneCtrl.clear();
      _addressCtrl.clear();
      _notesCtrl.clear();
      _searchCtrl.clear();
      _suggestions = [];
    });

    _recalculateQueuedRoute();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Durak #${_queuedStops.length} listeye eklendi! Yeni adres arayıp başka duraklar ekleyebilir veya tümünü kaydedebilirsiniz.',
        ),
        backgroundColor: const Color(0xFF2563EB),
      ),
    );
  }

  Future<void> _submitOrder() async {
    // Eğer çoklu durak listesinde bekleyen siparişler varsa ve form da doluysa onu da ekle
    final hasCurrentFormInput = _customerNameCtrl.text.trim().isNotEmpty &&
        _customerPhoneCtrl.text.trim().isNotEmpty &&
        _addressCtrl.text.trim().isNotEmpty;

    if (_queuedStops.isEmpty && !hasCurrentFormInput) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Müşteri adı, telefonu ve teslimat adresi zorunludur.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      if (_queuedStops.isNotEmpty) {
        final batchList = List<Map<String, dynamic>>.from(_queuedStops);
        if (hasCurrentFormInput) {
          batchList.add({
            if (_orderNumberCtrl.text.trim().isNotEmpty)
              'order_number': _orderNumberCtrl.text.trim(),
            'customer_name': _customerNameCtrl.text.trim(),
            'customer_phone': _customerPhoneCtrl.text.trim(),
            'delivery_address': _addressCtrl.text.trim(),
            'delivery_notes':
                _notesCtrl.text.trim().isNotEmpty ? _notesCtrl.text.trim() : null,
            'dest_lat': _selectedDest.latitude,
            'dest_lng': _selectedDest.longitude,
            'assigned_driver_id': _selectedDriverId,
          });
        }

        final res = await widget.apiClient.createMultipleOrders(
          assignedDriverId: _selectedDriverId,
          orders: batchList,
        );
        if (mounted) {
          Navigator.of(context).pop(res);
        }
        return;
      }

      // Tekli Sipariş Oluşturma
      final created = await widget.apiClient.createOrder(
        orderNumber: _orderNumberCtrl.text.trim(),
        customerName: _customerNameCtrl.text.trim(),
        customerPhone: _customerPhoneCtrl.text.trim(),
        deliveryAddress: _addressCtrl.text.trim(),
        deliveryNotes: _notesCtrl.text.trim().isNotEmpty ? _notesCtrl.text.trim() : null,
        destLat: _selectedDest.latitude,
        destLng: _selectedDest.longitude,
        assignedDriverId: _selectedDriverId,
      );

      if (mounted) {
        Navigator.of(context).pop(created);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sipariş oluşturulamadı: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sipariş Oluştur, Adres Ara & Çoklu Durak Ata'),
      ),
      body: Column(
        children: [
          // 1. EN ÜST BÖLÜM: ÜCRETSİZ ADRES ARAMA VE OTOMATİK ÖNERİ ÇUBUĞU (NOMINATIM / PHOTON)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchQueryChanged,
                  decoration: InputDecoration(
                    hintText: 'Adres, cadde, sokak veya bina ara (Örn: Atatürk Mah. Ataşehir)...',
                    prefixIcon: Icon(Icons.search_rounded, color: primary),
                    suffixIcon: _isSearchingAddress
                        ? const Padding(
                            padding: EdgeInsets.all(12.0),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : (_searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () {
                                  setState(() {
                                    _searchCtrl.clear();
                                    _suggestions = [];
                                  });
                                },
                              )
                            : null),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                  ),
                ),
                if (_suggestions.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(maxHeight: 210),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFCBD5E1)),
                      boxShadow: const [
                        BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 4)),
                      ],
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _suggestions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final item = _suggestions[idx];
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.location_on_outlined, color: primary),
                          title: Text(
                            item.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            'Koordinat: ${item.lat.toStringAsFixed(5)}, ${item.lng.toStringAsFixed(5)}',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                          ),
                          onTap: () => _selectAddressSuggestion(item),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // 2. ORTA BÖLÜM: OPENSTREETMAP HEDEF SEÇİM VE AKILLI ROTA HARİTASI
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _selectedDest,
                    initialZoom: 14.5,
                    onTap: (tapPosition, latLng) {
                      setState(() {
                        _selectedDest = latLng;
                      });
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.podsystem.kargotakip',
                    ),
                    if (_previewPolyline.length >= 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _previewPolyline,
                            strokeWidth: 4.5,
                            color: const Color(0xFF2563EB),
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        // Çoklu Durak Kuyruğundaki Numaralandırılmış Pinler
                        ..._optimizedPreviewStops.map((stop) {
                          final sLat = (stop['dest_lat'] as num).toDouble();
                          final sLng = (stop['dest_lng'] as num).toDouble();
                          final stopLabel =
                              stop['stop_label']?.toString() ?? 'Durak';
                          return Marker(
                            point: LatLng(sLat, sLng),
                            width: 120,
                            height: 64,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1D4ED8),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    stopLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.location_on_rounded,
                                  size: 34,
                                  color: Color(0xFF2563EB),
                                ),
                              ],
                            ),
                          );
                        }),

                        // Aktif Seçilen Pin (İnce Ayar Yapılabilir)
                        Marker(
                          point: _selectedDest,
                          width: 60,
                          height: 60,
                          child: const Icon(
                            Icons.location_on_rounded,
                            size: 48,
                            color: Color(0xFFDC2626),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  bottom: 10,
                  left: 12,
                  right: 12,
                  child: Card(
                    color: Colors.white.withValues(alpha: 0.94),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.touch_app_rounded, color: primary, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Üstten adres arayabilir veya haritaya dokunarak pini kaydırabilirsiniz.\n'
                              'Seçilen Pin: ${_selectedDest.latitude.toStringAsFixed(6)}, ${_selectedDest.longitude.toStringAsFixed(6)}',
                              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 3. ALT BÖLÜM: SİPARİŞ VE SINIRSIZ ÇOKLU DURAK ATAMA FORMU
          Expanded(
            flex: 6,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_optimizedPreviewStops.isNotEmpty) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF93C5FD)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.route_rounded, color: Color(0xFF1D4ED8), size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Akıllı Rota Önizlemesi (${_optimizedPreviewStops.length} Durak - En Yakın Komşu Sıralı)',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E3A8A),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ..._optimizedPreviewStops.map((s) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1D4ED8),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    s['stop_label'].toString(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${s['customer_name']} — ${s['delivery_address']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _orderNumberCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Sipariş No (Boşsa Otomatik)',
                          hintText: 'SIP-2026-1042',
                          prefixIcon: Icon(Icons.tag),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        initialValue: _selectedDriverId,
                        decoration: const InputDecoration(
                          labelText: 'Atanacak Kurye / Araç',
                          prefixIcon: Icon(Icons.two_wheeler_rounded),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Sonra Ata (Beklemede)'),
                          ),
                          ...widget.availableDrivers.map(
                            (d) => DropdownMenuItem<String?>(
                              value: d['id'].toString(),
                              child: Text(
                                '${d['full_name']} (${d['vehicle_plate'] ?? ''})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (val) {
                          setState(() => _selectedDriverId = val);
                          _recalculateQueuedRoute();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customerNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Müşteri Adı Soyadı *',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _customerPhoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Müşteri Telefonu *',
                          prefixIcon: Icon(Icons.phone_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _addressCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Açık Teslimat Adresi (Aramadan Otomatik Dolar / Kurye Değiştiremez) *',
                    prefixIcon: Icon(Icons.place_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Teslimat Notu (Kat, Daire, Zile Basmayın vb.)',
                    prefixIcon: Icon(Icons.notes_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSubmitting ? null : _addCurrentFormToStopQueue,
                        icon: const Icon(Icons.add_road_rounded),
                        label: const Text('+ DURAK EKLE (ÇOKLU GÖREV)'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: _isSubmitting ? null : _submitOrder,
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text(
                    _isSubmitting
                        ? 'SİPARİŞLER KAYDEDİLİYOR...'
                        : (_queuedStops.isNotEmpty
                            ? 'TÜM DURAKLARI KAYDET VE AKILLI ROTAYI BAŞLAT'
                            : 'SİPARİŞİ OLUŞTUR VE GEÇİCİ TAKİP LİNKİ ÜRET'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
