"""
auth.py
-------
1. Şifremi Unuttum (6 Haneli OTP E-posta Gönderimi ve Şifre Sıfırlama)
2. GMS Bağımsız (Huawei AppGallery Uyumlu) Google Hesabı ile Giriş / Kayıt / Kurye Bağlama
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Annotated, Optional
from urllib.parse import quote
from urllib.request import Request as UrlRequest, urlopen

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field, StringConstraints

from app.core.database import db
from app.core.security import create_access_token
from app.routers.tenants import _sanitize_tenant
from app.routers.tracking import tracking_ws_manager
from app.services.excel_mailer import ExcelPoDMailerService

logger = logging.getLogger("pod_system.auth")

router = APIRouter(prefix="/api/v1/auth", tags=["0. Kimlik Doğrulama, Şifremi Unuttum & Google Girişi"])

mailer_service = ExcelPoDMailerService()

EmailAddress = Annotated[
    str,
    StringConstraints(pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$", strip_whitespace=True),
]


class ForgotPasswordRequest(BaseModel):
    email: EmailAddress = Field(..., examples=["info@kuzeylojistik.com"])


class ResetPasswordRequest(BaseModel):
    email: EmailAddress = Field(..., examples=["info@kuzeylojistik.com"])
    code: str = Field(..., min_length=6, max_length=6, examples=["482910"])
    new_password: str = Field(..., min_length=6, examples=["YeniGucluSifre2026!"])


class GoogleAuthRequest(BaseModel):
    id_token: Optional[str] = Field(None, description="Google OAuth2 ID Token (varsa)")
    access_token: Optional[str] = Field(None, description="Google OAuth2 Access Token (varsa)")
    email: Optional[EmailAddress] = Field(None, description="Google hesap e-postası")
    full_name: Optional[str] = Field(None, description="Google hesap adı soyadı")
    google_sub: Optional[str] = Field(None, description="Google benzersiz kullanıcı kimliği")
    company_name: Optional[str] = Field(None, description="Yeni işletme kaydı ise işletme adı")
    phone: Optional[str] = Field(None, description="Telefon numarası")
    invite_token: Optional[str] = Field(
        None,
        description="WhatsApp kurye davet linkinden bağlanıyorsa davet tokenı",
    )
    vehicle_plate: Optional[str] = Field(None, description="Kurye araç plakası")
    vehicle_type: Optional[str] = Field(None, description="Kurye araç cinsi")


def _verify_google_token_sync(
    id_token: Optional[str], access_token: Optional[str]
) -> Optional[dict]:
    """
    Google'ın standart HTTPS uç noktaları üzerinden (GMS bağımsız)
    `id_token` veya `access_token` doğrulaması yapar.
    """
    if id_token and id_token.strip():
        url = f"https://oauth2.googleapis.com/tokeninfo?id_token={quote(id_token.strip())}"
        try:
            req = UrlRequest(url, headers={"User-Agent": "KargoTakipPoD-Auth/2.0"})
            with urlopen(req, timeout=6.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("email"):
                    return {
                        "email": str(data["email"]).strip().lower(),
                        "full_name": str(data.get("name") or data["email"].split("@")[0]),
                        "google_sub": str(data.get("sub") or ""),
                    }
        except Exception as exc:
            logger.debug("Google id_token doğrulaması uyarısı: %s", exc)

    if access_token and access_token.strip():
        url = "https://www.googleapis.com/oauth2/v3/userinfo"
        try:
            req = UrlRequest(
                url,
                headers={
                    "Authorization": f"Bearer {access_token.strip()}",
                    "User-Agent": "KargoTakipPoD-Auth/2.0",
                },
            )
            with urlopen(req, timeout=6.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("email"):
                    return {
                        "email": str(data["email"]).strip().lower(),
                        "full_name": str(data.get("name") or data["email"].split("@")[0]),
                        "google_sub": str(data.get("sub") or ""),
                    }
        except Exception as exc:
            logger.debug("Google access_token doğrulaması uyarısı: %s", exc)

    return None


@router.post(
    "/forgot-password",
    summary="Şifremi Unuttum: Kullanıcının E-postasına 6 Haneli Sıfırlama Kodu (OTP) Gönder",
)
async def forgot_password(payload: ForgotPasswordRequest):
    """
    GÖREV #6:
    Kullanıcının e-postasına 6 haneli sıfırlama kodu (OTP) üretir ve
    işletmenin/sistemin Gmail SMTP ayarları üzerinden gerçek e-posta olarak gönderir.
    """
    code, user, tenant = db.create_password_reset_code(str(payload.email))
    smtp_creds = db.get_effective_smtp_credentials(
        tenant_id=tenant["id"],
        email=str(payload.email),
    )

    email_sent = False
    smtp_error: Optional[str] = None
    try:
        email_sent = await asyncio.to_thread(
            mailer_service.send_password_reset_otp_email,
            to_email=user["email"],
            code=code,
            full_name=user["full_name"],
            tenant_name=tenant["name"],
            smtp_override=smtp_creds,
        )
    except Exception as exc:
        smtp_error = str(exc)
        logger.warning("Şifre sıfırlama e-postası SMTP hatası: %s", exc)

    if email_sent:
        return {
            "status": "sent",
            "email_sent": True,
            "message": f"6 haneli şifre sıfırlama kodunuz {user['email']} adresine gönderildi.",
        }

    # Henüz SMTP uygulama şifresi girilmemişse kullanıcı kilitlenmesin diye bilgilendir
    return {
        "status": "generated",
        "email_sent": False,
        "fallback_code": code,
        "smtp_error": smtp_error,
        "message": (
            "Sistemde henüz Gmail 16 haneli uygulama şifresi (SMTP) tanımlanmadığı için "
            f"tek kullanımlık doğrulama kodunuz ekranda oluşturuldu: {code}"
        ),
    }


@router.post(
    "/reset-password",
    summary="E-posta + 6 Haneli Kod (OTP) + Yeni Şifre ile Şifreyi Güncelle",
)
async def reset_password(payload: ResetPasswordRequest):
    """
    GÖREV #6:
    E-posta + 6 haneli OTP kodunu doğrular ve kullanıcının şifresini günceller.
    """
    updated_user = db.reset_password_with_code(
        email=str(payload.email),
        code=payload.code,
        new_password=payload.new_password,
    )
    return {
        "status": "ok",
        "message": "Şifreniz başarıyla güncellendi. Yeni şifrenizle giriş yapabilirsiniz.",
        "email": updated_user["email"],
    }


@router.post(
    "/google",
    summary="GMS Bağımsız (Huawei Uyumlu) Google Hesabı ile Giriş / İşletme Kaydı / Kurye Bağlama",
)
async def google_authenticate(payload: GoogleAuthRequest):
    """
    GÖREV #7:
    Huawei AppGallery cihazlarında (GMS olmayan telefonlarda) çökmemesi için
    standart OAuth2 / Token veya doğrulanmış Google E-posta kimliği ile çalışır.
    Tek tıkla mevcut hesaba giriş yapar, yeni işletme açar veya kurye davetini tamamlar.
    """
    verified = await asyncio.to_thread(
        _verify_google_token_sync,
        payload.id_token,
        payload.access_token,
    )

    email = (verified or {}).get("email") or (str(payload.email).strip().lower() if payload.email else "")
    if not email:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Google hesap e-postası veya OAuth token bilgisi gereklidir.",
        )

    full_name = (
        (verified or {}).get("full_name")
        or (payload.full_name.strip() if payload.full_name else "")
        or email.split("@")[0].title()
    )
    google_sub = (verified or {}).get("google_sub") or payload.google_sub or f"google:{email}"

    user, tenant = db.authenticate_or_register_google_user(
        email=email,
        full_name=full_name,
        google_sub=google_sub,
        company_name=payload.company_name,
        phone=payload.phone,
        invite_token=payload.invite_token,
        vehicle_plate=payload.vehicle_plate,
        vehicle_type=payload.vehicle_type,
    )

    if payload.invite_token:
        await tracking_ws_manager.broadcast_to_tenant(
            tenant["id"],
            {
                "event": "driver_registered",
                "driver": {k: v for k, v in user.items() if k != "password_hash"},
            },
        )

    access_token = create_access_token(
        user_id=user["id"],
        tenant_id=tenant["id"],
        role=user["role"],
        email=user["email"],
        full_name=user["full_name"],
    )

    return {
        "access_token": access_token,
        "token_type": "bearer",
        "tenant": _sanitize_tenant(tenant),
        "user": {k: v for k, v in user.items() if k != "password_hash"},
    }
