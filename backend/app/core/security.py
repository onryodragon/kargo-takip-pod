"""
security.py
-----------
JWT Tabanlı Kimlik Doğrulama, Şifre Hashleme ve Sıkı Rol Kontrolü (RBAC).

İş Kuralları:
- Her JWT token içinde `user_id`, `tenant_id` ve `role` ('admin' veya 'driver') taşınır.
- `require_admin`: Sadece işletme sahibi (admin) erişebilir. Kuryeler (driver) kesinlikle reddedilir.
- `require_driver`: Kurye (veya test/operasyon amaçlı admin) erişebilir.
- Tüm uç noktalar `current_user.tenant_id` ile Multi-Tenant veri izolasyonu uygular.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Literal, Optional

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from app.core.config import settings

try:
    import jwt as pyjwt  # PyJWT
except ImportError:
    pyjwt = None  # type: ignore

bearer_scheme = HTTPBearer(auto_error=False)

RoleType = Literal["admin", "driver"]


class CurrentUser(BaseModel):
    """Doğrulanmış JWT oturum kullanıcısı modeli."""
    user_id: str
    tenant_id: str
    role: RoleType
    email: Optional[str] = None
    full_name: Optional[str] = None


# ============================================================================
# 1. ŞİFRE HASHLEME VE DOĞRULAMA (Python 3.14 Uyumlu - scrypt)
# ============================================================================
def hash_password(plain_password: str) -> str:
    """Şifreyi rastgele tuz (salt) ile scrypt algoritması kullanarak güvenli şekilde hashler."""
    salt = secrets.token_hex(16)
    derived = hashlib.scrypt(
        plain_password.encode("utf-8"),
        salt=salt.encode("utf-8"),
        n=16384,
        r=8,
        p=1,
        dklen=64,
    )
    return f"scrypt${salt}${derived.hex()}"


def verify_password(plain_password: str, stored_hash: str) -> bool:
    """Düz metin şifreyi kayıtlı hash ile sabit zamanda (timing-attack korumalı) karşılaştırır."""
    try:
        scheme, salt, digest_hex = stored_hash.split("$", 2)
        if scheme != "scrypt":
            return False
        derived = hashlib.scrypt(
            plain_password.encode("utf-8"),
            salt=salt.encode("utf-8"),
            n=16384,
            r=8,
            p=1,
            dklen=64,
        )
        return hmac.compare_digest(derived.hex(), digest_hex)
    except Exception:
        return False


# ============================================================================
# 2. JWT TOKEN ÜRETİMİ VE ÇÖZÜMLEME (HS256)
# ============================================================================
def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(segment: str) -> bytes:
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


def create_access_token(
    *,
    user_id: str,
    tenant_id: str,
    role: RoleType,
    email: Optional[str] = None,
    full_name: Optional[str] = None,
    expires_delta: Optional[timedelta] = None,
) -> str:
    """
    İçinde `user_id`, `tenant_id` ve `role` ('admin' | 'driver') barındıran
    imzalı JWT erişim token'ı üretir.
    """
    now = datetime.now(timezone.utc)
    expire = now + (expires_delta or timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES))

    payload: Dict[str, Any] = {
        "sub": str(user_id),
        "user_id": str(user_id),
        "tenant_id": str(tenant_id),
        "role": role,
        "email": email,
        "full_name": full_name,
        "iat": int(now.timestamp()),
        "exp": int(expire.timestamp()),
    }

    if pyjwt is not None:
        return pyjwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)

    # PyJWT yüklü değilse standart RFC 7519 HS256 imzalayıcı
    header = {"alg": "HS256", "typ": "JWT"}
    signing_input = (
        f"{_b64url_encode(json.dumps(header, separators=(',', ':')).encode('utf-8'))}."
        f"{_b64url_encode(json.dumps(payload, separators=(',', ':')).encode('utf-8'))}"
    )
    signature = hmac.new(
        settings.JWT_SECRET_KEY.encode("utf-8"),
        signing_input.encode("ascii"),
        hashlib.sha256,
    ).digest()
    return f"{signing_input}.{_b64url_encode(signature)}"


def decode_access_token(token: str) -> Dict[str, Any]:
    """JWT token imzasını ve geçerlilik süresini doğrular, payload sözlüğünü döner."""
    if pyjwt is not None:
        try:
            return pyjwt.decode(
                token,
                settings.JWT_SECRET_KEY,
                algorithms=[settings.JWT_ALGORITHM],
            )
        except Exception as exc:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Geçersiz veya süresi dolmuş oturum anahtarı: {exc}",
                headers={"WWW-Authenticate": "Bearer"},
            ) from exc

    # Standart RFC 7519 HS256 doğrulayıcı
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
        signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
        expected_sig = hmac.new(
            settings.JWT_SECRET_KEY.encode("utf-8"),
            signing_input,
            hashlib.sha256,
        ).digest()
        actual_sig = _b64url_decode(sig_b64)
        if not hmac.compare_digest(expected_sig, actual_sig):
            raise ValueError("İmza doğrulaması başarısız.")

        payload = json.loads(_b64url_decode(payload_b64).decode("utf-8"))
        exp = payload.get("exp")
        if exp and int(datetime.now(timezone.utc).timestamp()) > int(exp):
            raise ValueError("Token süresi dolmuş.")
        return payload
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Geçersiz veya süresi dolmuş oturum anahtarı: {exc}",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc


# ============================================================================
# 3. FASTAPI DEPENDENCIES (YÖNETİCİ VS. KURYE YETKİ KONTROLÜ)
# ============================================================================
async def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
) -> CurrentUser:
    """Bearer JWT token içerisinden `user_id`, `tenant_id` ve `role` bilgilerini çıkarır."""
    if credentials is None or not credentials.credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Kimlik doğrulama bilgisi (Bearer Token) eksik.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    payload = decode_access_token(credentials.credentials)
    user_id = payload.get("user_id") or payload.get("sub")
    tenant_id = payload.get("tenant_id")
    role = payload.get("role")

    if not user_id or not tenant_id or role not in ("admin", "driver"):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token içeriğinde zorunlu (user_id, tenant_id, role) alanları eksik.",
        )

    return CurrentUser(
        user_id=str(user_id),
        tenant_id=str(tenant_id),
        role=role,
        email=payload.get("email"),
        full_name=payload.get("full_name"),
    )


async def require_admin(current_user: CurrentUser = Depends(get_current_user)) -> CurrentUser:
    """
    İŞ KURALI #2: Sadece İşletme Sahibi (Admin) erişebilir.
    Kurye (driver) rolündeki bir kullanıcı sipariş açmaya, adres/konum değiştirmeye
    veya kurye atamaya çalışırsa 403 Forbidden döner.
    """
    if current_user.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "YETKİ REDDEDİLDİ: Bu işlem sadece İşletme Yöneticisi (admin) tarafından yapılabilir. "
                "Kuryeler sipariş oluşturamaz, adres/konum veya atama değiştiremez."
            ),
        )
    return current_user


async def require_driver(current_user: CurrentUser = Depends(get_current_user)) -> CurrentUser:
    """
    Kurye (veya işletme yöneticisi) erişimine izin verir.
    Veri erişimi her zaman `current_user.tenant_id` ile sınırlandırılır.
    """
    if current_user.role not in ("driver", "admin"):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="YETKİ REDDEDİLDİ: Geçerli bir kurye veya yönetici yetkisi gerekli.",
        )
    return current_user
