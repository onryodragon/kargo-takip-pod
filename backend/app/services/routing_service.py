"""
routing_service.py
------------------
Ücretsiz Açık Kaynak Harita Servisleri:
1. OpenStreetMap Nominatim + Komoot Photon Adres Arama ve Otomatik Öneri (Autocomplete)
2. En Yakın Komşu (Nearest-Neighbor / TSP) Çoklu Durak Sıralama Algoritması
3. OSRM (Open Source Routing Machine) Gerçek Karayolu Rota Çizimi (`geometries=geojson`)
"""

from __future__ import annotations

import json
import logging
import math
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import quote
from urllib.request import Request as UrlRequest, urlopen

logger = logging.getLogger("pod_system.routing_service")

USER_AGENT_HEADER = "KargoTakipPoD-MultiTenant/2.0 (https://kargo-takip-pod.onrender.com)"


def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """İki GPS koordinatı arasındaki kuş uçuşu mesafeyi kilometre cinsinden hesaplar."""
    r = 6371.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lng2 - lng1)

    a = (
        math.sin(d_phi / 2.0) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2.0) ** 2
    )
    c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
    return r * c


def optimize_orders_nearest_neighbor(
    orders: List[Dict[str, Any]],
    start_lat: Optional[float] = None,
    start_lng: Optional[float] = None,
) -> List[Dict[str, Any]]:
    """
    Bir kuryenin aktif siparişlerini başlangıç konumundan (kuryenin anlık GPS konumu
    veya ilk sipariş hedefi) başlayarak En Yakın Komşu (Nearest-Neighbor / TSP)
    algoritması ile en verimli teslimat sırasına dizer.

    Her siparişe şu alanları ekler:
    - `stop_sequence`: 1, 2, 3, ...
    - `stop_label`: "1. Durak (En Yakın)", "2. Durak", "3. Durak", ...
    - `distance_from_prev_km`: Önceki noktadan mesafe (km)
    """
    if not orders:
        return []

    remaining = [dict(o) for o in orders]
    optimized: List[Dict[str, Any]] = []

    if start_lat is not None and start_lng is not None:
        cur_lat = float(start_lat)
        cur_lng = float(start_lng)
    else:
        # Kuryenin canlı GPS konumu henüz yoksa ilk eklenen siparişi başlangıç referansı al
        first = remaining.pop(0)
        cur_lat = float(first["dest_lat"])
        cur_lng = float(first["dest_lng"])
        first["stop_sequence"] = 1
        first["stop_label"] = "1. Durak (En Yakın)"
        first["distance_from_prev_km"] = 0.0
        optimized.append(first)

    while remaining:
        nearest_idx = 0
        nearest_dist = float("inf")
        for idx, item in enumerate(remaining):
            d = haversine_km(
                cur_lat,
                cur_lng,
                float(item["dest_lat"]),
                float(item["dest_lng"]),
            )
            if d < nearest_dist:
                nearest_dist = d
                nearest_idx = idx

        chosen = remaining.pop(nearest_idx)
        seq = len(optimized) + 1
        chosen["stop_sequence"] = seq
        chosen["stop_label"] = "1. Durak (En Yakın)" if seq == 1 else f"{seq}. Durak"
        chosen["distance_from_prev_km"] = round(nearest_dist, 2)
        optimized.append(chosen)

        cur_lat = float(chosen["dest_lat"])
        cur_lng = float(chosen["dest_lng"])

    return optimized


def fetch_osrm_route(
    waypoints: List[Tuple[float, float]],
) -> Dict[str, Any]:
    """
    Ücretsiz OSRM API (`https://router.project-osrm.org/route/v1/driving/...`)
    üzerinden duraklar arasındaki gerçek karayolu rotasını (`geometries=geojson`) döner.

    `waypoints`: [(lat, lng), (lat, lng), ...]
    """
    if len(waypoints) < 2:
        pts = [[float(lat), float(lng)] for lat, lng in waypoints]
        return {
            "polyline": pts,
            "total_distance_km": 0.0,
            "total_duration_min": 0.0,
            "source": "direct",
        }

    coord_str = ";".join(f"{ float(lng):.6f},{float(lat):.6f}" for lat, lng in waypoints)
    osrm_url = (
        f"https://router.project-osrm.org/route/v1/driving/{coord_str}"
        "?overview=full&geometries=geojson"
    )

    try:
        req = UrlRequest(osrm_url, headers={"User-Agent": USER_AGENT_HEADER})
        with urlopen(req, timeout=8.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))

        routes = data.get("routes") or []
        if routes:
            best = routes[0]
            coords = best.get("geometry", {}).get("coordinates") or []
            # GeoJSON [lng, lat] -> Flutter [lat, lng]
            polyline = [[float(c[1]), float(c[0])] for c in coords if len(c) >= 2]
            dist_km = round(float(best.get("distance", 0.0)) / 1000.0, 2)
            dur_min = round(float(best.get("duration", 0.0)) / 60.0, 1)
            if polyline:
                return {
                    "polyline": polyline,
                    "total_distance_km": dist_km,
                    "total_duration_min": dur_min,
                    "source": "osrm",
                }
    except Exception as exc:
        logger.debug("OSRM rota sorgusu yedek düz çizgiye düştü: %s", exc)

    # Yedek: Kuş uçuşu sıralı noktalar
    total_km = 0.0
    for i in range(len(waypoints) - 1):
        total_km += haversine_km(
            waypoints[i][0],
            waypoints[i][1],
            waypoints[i + 1][0],
            waypoints[i + 1][1],
        )
    return {
        "polyline": [[float(lat), float(lng)] for lat, lng in waypoints],
        "total_distance_km": round(total_km, 2),
        "total_duration_min": round((total_km / 35.0) * 60.0, 1),
        "source": "fallback",
    }


def search_address_suggestions(query: str, limit: int = 6) -> List[Dict[str, Any]]:
    """
    Ücretsiz ve API anahtarsız OpenStreetMap Nominatim + Komoot Photon servislerini
    kullanarak Türkiye öncelikli adres önerileri döner.
    """
    cleaned = (query or "").strip()
    if len(cleaned) < 2:
        return []

    encoded = quote(cleaned)
    nominatim_url = (
        f"https://nominatim.openstreetmap.org/search"
        f"?format=json&q={encoded}&countrycodes=tr&addressdetails=1&limit={int(limit)}"
    )

    try:
        req = UrlRequest(
            nominatim_url,
            headers={
                "User-Agent": USER_AGENT_HEADER,
                "Accept-Language": "tr,en;q=0.8",
            },
        )
        with urlopen(req, timeout=6.0) as resp:
            raw_list = json.loads(resp.read().decode("utf-8"))

        if isinstance(raw_list, list) and raw_list:
            results: List[Dict[str, Any]] = []
            for item in raw_list:
                lat = float(item.get("lat", 0.0))
                lng = float(item.get("lon", 0.0))
                display_name = str(item.get("display_name") or "").strip()
                if display_name:
                    results.append(
                        {
                            "display_name": display_name,
                            "lat": lat,
                            "lng": lng,
                            "type": item.get("type") or "address",
                            "source": "nominatim",
                        }
                    )
            if results:
                return results
    except Exception as exc:
        logger.debug("Nominatim arama uyarısı, Photon denenecek: %s", exc)

    # Yedek: Komoot Photon API (Ücretsiz OSM tabanlı)
    photon_url = f"https://photon.komoot.io/api/?q={encoded}&limit={int(limit)}"
    try:
        req2 = UrlRequest(photon_url, headers={"User-Agent": USER_AGENT_HEADER})
        with urlopen(req2, timeout=6.0) as resp2:
            photon_data = json.loads(resp2.read().decode("utf-8"))

        features = photon_data.get("features") or []
        results = []
        for feat in features:
            geom = feat.get("geometry") or {}
            coords = geom.get("coordinates") or []
            props = feat.get("properties") or {}
            if len(coords) >= 2:
                parts = [
                    props.get("name"),
                    props.get("street"),
                    props.get("housenumber"),
                    props.get("district"),
                    props.get("city") or props.get("state"),
                    props.get("country"),
                ]
                label = ", ".join(str(p) for p in parts if p)
                if label:
                    results.append(
                        {
                            "display_name": label,
                            "lat": float(coords[1]),
                            "lng": float(coords[0]),
                            "type": props.get("osm_value") or "address",
                            "source": "photon",
                        }
                    )
        return results
    except Exception as exc:
        logger.warning("Adres arama servislerine ulaşılamadı: %s", exc)
        return []
