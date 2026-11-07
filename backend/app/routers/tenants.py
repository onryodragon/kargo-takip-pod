"""
tenants.py
----------
Özelleştirilebilir İşletme Yapısı (Multi-Tenant & White-Label) ve Kurye Yönetimi Uç Noktaları.

İş Kuralları:
- Her işletme kayıt olduğunda kendi "İşletme Adını", logosunu, temasını ve arşivlerin
  gideceği "Rapor E-posta Adresini" (`report_email`) belirler.
- Sadece İşletme Sahibi (`require_admin`) işletme bilgilerini güncelleyebilir ve yeni kurye ekleyebilir.
"""

from __future__ import annotations

from typing import Annotated, List, Optional

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, Field, StringConstraints

EmailAddress = Annotated[
    str,
    StringConstraints(pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$", strip_whitespace=True),
]

from app.core.database import db
from app.core.security import (
    CurrentUser,
    create_access_token,
    get_current_user,
    require_admin,
)

router = APIRouter(prefix="/api/v1/tenants", tags=["1. İşletme (White-Label) & Kurye Yönetimi"])


# ============================================================================
# ŞEMALAR (PYDANTIC MODELLERİ)
# ============================================================================
class TenantRegisterRequest(BaseModel):
    name: str = Field(..., min_length=2, max_length=150, examples=["Yıldız Ekspres Kargo"])
    slug: str = Field(..., min_length=2, max_length=100, examples=["yildiz-ekspres"])
    report_email: EmailAddress = Field(..., examples=["arsiv@yildizekspres.com"])
    logo_url: Optional[str] = Field(None, examples=["https://cdn.ornek.com/logo.png"])
    primary_color: str = Field("#1E40AF", examples=["#1E40AF"])
    phone: Optional[str] = Field(None, examples=["+90 216 000 00 00"])

    # İlk İşletme Sahibi (Admin) Bilgileri
    admin_full_name: str = Field(..., min_length=2, max_length=120, examples=["Olkan Yılmaz"])
    admin_email: EmailAddress = Field(..., examples=["admin@yildizekspres.com"])
    admin_phone: str = Field(..., examples=["+90 532 111 22 33"])
    admin_password: str = Field(..., min_length=6, examples=["GucluSifre2026!"])


class LoginRequest(BaseModel):
    email: EmailAddress = Field(..., examples=["admin@yildizekspres.com"])
    password: str = Field(..., examples=["GucluSifre2026!"])


class TenantUpdateRequest(BaseModel):
    name: Optional[str] = Field(None, min_length=2, max_length=150)
    logo_url: Optional[str] = None
    report_email: Optional[EmailAddress] = None
    primary_color: Optional[str] = None
    phone: Optional[str] = None


class DriverCreateRequest(BaseModel):
    full_name: str = Field(..., min_length=2, max_length=120, examples=["Mehmet Demir"])
    email: EmailAddress = Field(..., examples=["mehmet@yildizekspres.com"])
    phone: str = Field(..., examples=["+90 533 444 55 66"])
    password: str = Field(..., min_length=6, examples=["KuryeSifre123!"])
    vehicle_plate: str = Field(..., examples=["34 KRG 2026"])
    vehicle_type: Optional[str] = Field("Motosiklet", examples=["Motosiklet", "Panelvan"])


# ============================================================================
# UÇ NOKTALAR (ENDPOINTS)
# ============================================================================
@router.post(
    "/register",
    status_code=status.HTTP_201_CREATED,
    summary="Yeni İşletme (White-Label) ve İlk Admin Kullanıcısını Oluştur",
)
async def register_tenant(payload: TenantRegisterRequest):
    """
    Yeni bir işletme (`tenants`) ve işletme sahibini (`users` role='admin')
    tek işlemde (transaction) oluşturur ve doğrudan JWT `access_token` döner.
    """
    tenant, admin_user = db.register_tenant_and_admin(
        name=payload.name,
        slug=payload.slug,
        report_email=str(payload.report_email),
        logo_url=payload.logo_url,
        primary_color=payload.primary_color,
        phone=payload.phone,
        admin_full_name=payload.admin_full_name,
        admin_email=str(payload.admin_email),
        admin_phone=payload.admin_phone,
        admin_password=payload.admin_password,
    )

    access_token = create_access_token(
        user_id=admin_user["id"],
        tenant_id=tenant["id"],
        role="admin",
        email=admin_user["email"],
        full_name=admin_user["full_name"],
    )

    return {
        "access_token": access_token,
        "token_type": "bearer",
        "tenant": tenant,
        "user": {k: v for k, v in admin_user.items() if k != "password_hash"},
    }


@router.post(
    "/login",
    summary="Yönetici (Admin) veya Kurye (Driver) Girişi",
)
async def login(payload: LoginRequest):
    """
    Kullanıcıyı doğrular; içinde `user_id`, `tenant_id` ve `role` ('admin' | 'driver')
    bulunan JWT token ile işletmenin White-Label ayarlarını döner.
    """
    user, tenant = db.authenticate_user(str(payload.email), payload.password)
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
        "tenant": tenant,
        "user": {k: v for k, v in user.items() if k != "password_hash"},
    }


@router.get(
    "/me",
    summary="Aktif Kullanıcının İşletme (White-Label) Bilgilerini Getir",
)
async def get_my_tenant(current_user: CurrentUser = Depends(get_current_user)):
    """Oturum açmış kullanıcının kendi `tenant_id` işletme profilini döner."""
    return db.get_tenant_by_id(current_user.tenant_id)


@router.patch(
    "/me",
    summary="İşletme Adını, Logosunu, Temasını ve Rapor E-postasını Güncelle (Sadece Admin)",
)
async def update_my_tenant(
    payload: TenantUpdateRequest,
    current_user: CurrentUser = Depends(require_admin),
):
    """
    Sadece `admin` kendi işletmesinin adını, logosunu, temasını ve
    Excel PoD arşivlerinin gideceği `report_email` adresini güncelleyebilir.
    """
    updates = payload.model_dump(exclude_unset=True)
    if "report_email" in updates and updates["report_email"] is not None:
        updates["report_email"] = str(updates["report_email"])
    return db.update_tenant(current_user.tenant_id, updates)


@router.post(
    "/drivers",
    status_code=status.HTTP_201_CREATED,
    summary="İşletmeye Yeni Kurye (Driver) Ekle (Sadece Admin)",
)
async def create_tenant_driver(
    payload: DriverCreateRequest,
    current_user: CurrentUser = Depends(require_admin),
):
    """Sadece `admin` kendi işletmesine (`tenant_id`) yeni saha kuryesi ekleyebilir."""
    driver = db.create_driver(
        tenant_id=current_user.tenant_id,
        full_name=payload.full_name,
        email=str(payload.email),
        phone=payload.phone,
        password=payload.password,
        vehicle_plate=payload.vehicle_plate,
        vehicle_type=payload.vehicle_type,
    )
    return {k: v for k, v in driver.items() if k != "password_hash"}


@router.get(
    "/drivers",
    summary="İşletmenin Tüm Kuryelerini ve Son Konumlarını Listele (Sadece Admin)",
)
async def list_tenant_drivers(
    current_user: CurrentUser = Depends(require_admin),
) -> List[dict]:
    """Sadece `admin` kendi işletmesine kayıtlı aktif kuryeleri ve son konumlarını listeler."""
    return db.list_drivers(current_user.tenant_id)
