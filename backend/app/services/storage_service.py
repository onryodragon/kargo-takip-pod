"""
storage_service.py
------------------
Zorunlu Teslimat Kanıtı (PoD: Fotoğraf + İmza) Medya Kayıt Servisi.

Özellikler:
- Kuryeden gelen fotoğraf ve imzayı hem `UploadFile` (multipart/form-data)
  hem de `Base64` (`data:image/png;base64,...`) formatında kabul eder.
- Görselin gerçekten geçerli bir resim dosyası olduğunu Pillow ile doğrular.
- Her durumda `backend/uploads/pod-media/{tenant_id}/{order_number}/` dizinine kaydeder.
- Supabase aktifse ayrıca `pod-media` public bucket'ına da yükler.
"""

from __future__ import annotations

import base64
import io
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Tuple

from fastapi import HTTPException, UploadFile, status
from PIL import Image as PILImage

from app.core.config import settings
from app.core.database import db

logger = logging.getLogger("pod_system.storage_service")


class PoDStorageService:
    """Teslimat fotoğrafı ve alıcı imzasını doğrulayan ve kaydeden servis."""

    @staticmethod
    async def extract_and_validate_image(
        *,
        upload_file: Optional[UploadFile],
        base64_str: Optional[str],
        field_label: str,
    ) -> bytes:
        """
        UploadFile veya Base64 girdisinden ham görsel byte'larını çözer.
        Görsel eksikse veya geçerli bir resim değilse 422 / 400 hatası fırlatır.
        """
        raw_bytes: Optional[bytes] = None

        if upload_file is not None and upload_file.filename:
            raw_bytes = await upload_file.read()
        elif base64_str is not None and base64_str.strip():
            cleaned = base64_str.strip()
            if cleaned.startswith("data:image") and "," in cleaned:
                _, cleaned = cleaned.split(",", 1)
            try:
                raw_bytes = base64.b64decode(cleaned, validate=False)
            except Exception as exc:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"{field_label} Base64 formatı geçersiz: {exc}",
                ) from exc

        if not raw_bytes or len(raw_bytes) < 64:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"ZORUNLU ALAN EKSİK: '{field_label}' olmadan teslimat tamamlanamaz!",
            )

        try:
            with PILImage.open(io.BytesIO(raw_bytes)) as img:
                img.verify()
        except Exception as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"'{field_label}' geçerli bir görüntü dosyası değil: {exc}",
            ) from exc

        return raw_bytes

    @classmethod
    async def save_pod_media(
        cls,
        *,
        tenant_id: str,
        order_number: str,
        pod_photo_file: Optional[UploadFile] = None,
        pod_photo_base64: Optional[str] = None,
        pod_signature_file: Optional[UploadFile] = None,
        pod_signature_base64: Optional[str] = None,
    ) -> Tuple[str, str, bytes, bytes]:
        """
        Fotoğraf ve imzayı doğrular, `backend/uploads/pod-media/` altına (ve varsa Supabase
        `pod-media` bucket'ına) kaydeder ve `(photo_url, signature_url, photo_bytes, signature_bytes)` döner.
        """
        photo_bytes = await cls.extract_and_validate_image(
            upload_file=pod_photo_file,
            base64_str=pod_photo_base64,
            field_label="Teslimat Fotoğrafı (pod_photo)",
        )
        signature_bytes = await cls.extract_and_validate_image(
            upload_file=pod_signature_file,
            base64_str=pod_signature_base64,
            field_label="Alıcı İmzası (pod_signature)",
        )

        safe_order = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in order_number)
        ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

        rel_dir = Path(tenant_id) / safe_order
        target_dir = settings.POD_MEDIA_DIR / rel_dir
        target_dir.mkdir(parents=True, exist_ok=True)

        photo_filename = f"photo_{ts}.png"
        sig_filename = f"signature_{ts}.png"

        photo_path = target_dir / photo_filename
        sig_path = target_dir / sig_filename

        photo_path.write_bytes(photo_bytes)
        sig_path.write_bytes(signature_bytes)

        photo_url = (
            f"{settings.PUBLIC_BASE_URL}/uploads/pod-media/{tenant_id}/{safe_order}/{photo_filename}"
        )
        sig_url = (
            f"{settings.PUBLIC_BASE_URL}/uploads/pod-media/{tenant_id}/{safe_order}/{sig_filename}"
        )

        # Supabase aktifse ayrıca pod-media bucket'ına yükle
        if db.supabase_client is not None:
            try:
                bucket = settings.SUPABASE_STORAGE_BUCKET
                remote_photo_key = f"{tenant_id}/{safe_order}/{photo_filename}"
                remote_sig_key = f"{tenant_id}/{safe_order}/{sig_filename}"
                db.supabase_client.storage.from_(bucket).upload(
                    remote_photo_key,
                    photo_bytes,
                    {"content-type": "image/png", "upsert": "true"},
                )
                db.supabase_client.storage.from_(bucket).upload(
                    remote_sig_key,
                    signature_bytes,
                    {"content-type": "image/png", "upsert": "true"},
                )
                photo_url = db.supabase_client.storage.from_(bucket).get_public_url(
                    remote_photo_key
                )
                sig_url = db.supabase_client.storage.from_(bucket).get_public_url(remote_sig_key)
            except Exception as exc:
                logger.warning(
                    "Supabase Storage yüklemesi atlandı, yerel pod-media URL kullanılacak: %s",
                    exc,
                )

        return photo_url, sig_url, photo_bytes, signature_bytes


storage_service = PoDStorageService()
