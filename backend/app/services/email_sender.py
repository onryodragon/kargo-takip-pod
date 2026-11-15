"""
email_sender.py
---------------
Render ücretsiz planı gibi giden SMTP portlarının (587 / 465) zaman aşımına uğrayabildiği
ortamlar için çok kanallı, dayanıklı e-posta gönderim katmanı.

Gönderim sırası (EMAIL_DELIVERY_ORDER ile değiştirilebilir, varsayılan: "http,smtp"):
1. HTTP API (HTTPS 443 — Render'da asla engellenmez):
   - Resend      (RESEND_API_KEY)
   - Brevo       (BREVO_API_KEY)
   - SendGrid    (SENDGRID_API_KEY)
2. SMTP (sırasıyla birincil port + SMTP_FALLBACK_PORTS, varsayılan: 465,587,2525):
   - 465  -> Doğrudan SSL (SMTP_SSL)
   - 587  -> STARTTLS
   - 2525 -> STARTTLS (Brevo / Mailgun / SendGrid gibi sağlayıcıların alternatif portu)

Tüm kanallar başarısız olursa her denemenin GERÇEK hata mesajını içeren
`EmailDeliveryError` fırlatılır.
"""

from __future__ import annotations

import base64
import json
import logging
import smtplib
import socket
import ssl
from dataclasses import dataclass, field
from email.message import EmailMessage
from email.utils import formataddr
from typing import Any, Dict, List, Optional, Sequence
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from app.core.config import settings

logger = logging.getLogger("pod_system.email_sender")

# Kullanıcının henüz doldurmadığı örnek / yer tutucu değerler
_PLACEHOLDER_MARKERS = (
    "GONDERICI_GMAIL_ADRESIN",
    "16_HANELI_UYGULAMA_SIFREN",
    "uygulama-sifresi-buraya",
    "arsiv@isletmeniz.com",
    "xxxx xxxx xxxx xxxx",
)


class EmailDeliveryError(RuntimeError):
    """Tüm e-posta kanalları başarısız olduğunda gerçek hata ayrıntılarıyla fırlatılır."""


@dataclass
class EmailAttachment:
    filename: str
    content: bytes
    mime_type: str = "application/octet-stream"


@dataclass
class EmailDeliveryResult:
    channel: str
    recipient: str
    attempts: List[str] = field(default_factory=list)


@dataclass
class SmtpCredentials:
    host: str
    port: int
    user: str
    password: str


def is_placeholder_value(value: Optional[str]) -> bool:
    if not value or not str(value).strip():
        return True
    upper = str(value).strip().upper()
    return any(marker.upper() in upper for marker in _PLACEHOLDER_MARKERS)


def resolve_smtp_credentials(smtp_override: Optional[Dict[str, Any]] = None) -> Optional[SmtpCredentials]:
    """Uygulama içi (tenant) SMTP ayarlarını, yoksa `.env` / Render ortam değişkenlerini kullanır."""
    override = smtp_override or {}
    host = str(override.get("host") or settings.SMTP_HOST or "smtp.gmail.com").strip()
    port = int(override.get("port") or settings.SMTP_PORT or 587)
    user = str(override.get("user") or settings.SMTP_USER or "").strip()
    # Gmail 16 haneli uygulama şifreleri "abcd efgh ijkl mnop" biçiminde boşluklu kopyalanabilir
    password = str(override.get("password") or settings.SMTP_PASSWORD or "").replace(" ", "").strip()

    if is_placeholder_value(user) or is_placeholder_value(password):
        return None
    return SmtpCredentials(host=host, port=port, user=user, password=password)


def _smtp_port_sequence(primary_port: int) -> List[int]:
    ports: List[int] = [int(primary_port)]
    for raw in (settings.SMTP_FALLBACK_PORTS or "").split(","):
        raw = raw.strip()
        if raw.isdigit() and int(raw) not in ports:
            ports.append(int(raw))
    return ports


def _build_mime_message(
    *,
    sender_name: str,
    sender_email: str,
    to_email: str,
    subject: str,
    text_body: str,
    html_body: str,
    attachments: Sequence[EmailAttachment],
) -> EmailMessage:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = formataddr((sender_name, sender_email))
    msg["To"] = to_email
    msg.set_content(text_body)
    msg.add_alternative(html_body, subtype="html")
    for att in attachments:
        maintype, _, subtype = (att.mime_type or "application/octet-stream").partition("/")
        msg.add_attachment(
            att.content,
            maintype=maintype or "application",
            subtype=subtype or "octet-stream",
            filename=att.filename,
        )
    return msg


def _send_via_smtp_port(msg: EmailMessage, creds: SmtpCredentials, port: int) -> None:
    timeout = float(settings.SMTP_TIMEOUT_SECONDS or 10)
    context = ssl.create_default_context()
    if port == 465:
        with smtplib.SMTP_SSL(creds.host, port, timeout=timeout, context=context) as server:
            server.login(creds.user, creds.password)
            server.send_message(msg)
        return

    with smtplib.SMTP(creds.host, port, timeout=timeout) as server:
        server.ehlo()
        if server.has_extn("starttls"):
            server.starttls(context=context)
            server.ehlo()
        elif settings.SMTP_USE_TLS:
            raise smtplib.SMTPException(f"{creds.host}:{port} STARTTLS desteklemiyor.")
        server.login(creds.user, creds.password)
        server.send_message(msg)


def _http_post_json(url: str, payload: Dict[str, Any], headers: Dict[str, str]) -> None:
    body = json.dumps(payload).encode("utf-8")
    req = Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json", **headers},
    )
    try:
        with urlopen(req, timeout=float(settings.SMTP_TIMEOUT_SECONDS or 10) + 5) as resp:
            resp.read()
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="ignore")[:400]
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"Bağlantı hatası: {exc.reason}") from exc


def _http_sender_email(creds: Optional[SmtpCredentials]) -> str:
    for candidate in (settings.MAIL_HTTP_FROM, settings.SMTP_FROM, creds.user if creds else None):
        if candidate and not is_placeholder_value(candidate) and "@" in candidate:
            return candidate.strip()
    return "onboarding@resend.dev"


def _send_via_http_providers(
    *,
    sender_name: str,
    sender_email: str,
    to_email: str,
    subject: str,
    text_body: str,
    html_body: str,
    attachments: Sequence[EmailAttachment],
    attempts: List[str],
) -> Optional[str]:
    encoded_atts = [
        (att, base64.b64encode(att.content).decode("ascii")) for att in attachments
    ]

    providers = []
    if settings.RESEND_API_KEY:
        providers.append("resend")
    if settings.BREVO_API_KEY:
        providers.append("brevo")
    if settings.SENDGRID_API_KEY:
        providers.append("sendgrid")

    for provider in providers:
        try:
            if provider == "resend":
                _http_post_json(
                    "https://api.resend.com/emails",
                    {
                        "from": formataddr((sender_name, sender_email)),
                        "to": [to_email],
                        "subject": subject,
                        "html": html_body,
                        "text": text_body,
                        **(
                            {"attachments": [{"filename": a.filename, "content": b64} for a, b64 in encoded_atts]}
                            if encoded_atts
                            else {}
                        ),
                    },
                    {"Authorization": f"Bearer {settings.RESEND_API_KEY}"},
                )
            elif provider == "brevo":
                _http_post_json(
                    "https://api.brevo.com/v3/smtp/email",
                    {
                        "sender": {"name": sender_name, "email": sender_email},
                        "to": [{"email": to_email}],
                        "subject": subject,
                        "htmlContent": html_body,
                        "textContent": text_body,
                        **(
                            {"attachment": [{"name": a.filename, "content": b64} for a, b64 in encoded_atts]}
                            if encoded_atts
                            else {}
                        ),
                    },
                    {"api-key": settings.BREVO_API_KEY},
                )
            else:
                _http_post_json(
                    "https://api.sendgrid.com/v3/mail/send",
                    {
                        "personalizations": [{"to": [{"email": to_email}]}],
                        "from": {"email": sender_email, "name": sender_name},
                        "subject": subject,
                        "content": [
                            {"type": "text/plain", "value": text_body},
                            {"type": "text/html", "value": html_body},
                        ],
                        **(
                            {
                                "attachments": [
                                    {
                                        "content": b64,
                                        "filename": a.filename,
                                        "type": a.mime_type,
                                        "disposition": "attachment",
                                    }
                                    for a, b64 in encoded_atts
                                ]
                            }
                            if encoded_atts
                            else {}
                        ),
                    },
                    {"Authorization": f"Bearer {settings.SENDGRID_API_KEY}"},
                )
            attempts.append(f"HTTP API ({provider}) -> BAŞARILI")
            return f"http:{provider}"
        except Exception as exc:
            attempts.append(f"HTTP API ({provider}) -> {type(exc).__name__}: {exc}")
            logger.warning("E-posta HTTP API (%s) hatası: %s", provider, exc)
    return None


def send_email(
    *,
    to_email: str,
    subject: str,
    html_body: str,
    text_body: str,
    sender_name: str = "Teslimat Takip Sistemi",
    attachments: Optional[Sequence[EmailAttachment]] = None,
    smtp_override: Optional[Dict[str, Any]] = None,
) -> EmailDeliveryResult:
    """
    E-postayı yapılandırılmış kanallar üzerinden sırayla göndermeyi dener.
    Başarılı olan ilk kanalı döner; hiçbiri başarılı olmazsa `EmailDeliveryError` fırlatır.
    """
    atts = list(attachments or [])
    attempts: List[str] = []
    creds = resolve_smtp_credentials(smtp_override)
    order = [p.strip().lower() for p in (settings.EMAIL_DELIVERY_ORDER or "http,smtp").split(",") if p.strip()]

    for channel in order:
        if channel == "http":
            has_http = bool(settings.RESEND_API_KEY or settings.BREVO_API_KEY or settings.SENDGRID_API_KEY)
            if not has_http:
                continue
            used = _send_via_http_providers(
                sender_name=sender_name,
                sender_email=_http_sender_email(creds),
                to_email=to_email,
                subject=subject,
                text_body=text_body,
                html_body=html_body,
                attachments=atts,
                attempts=attempts,
            )
            if used:
                logger.info("E-posta gönderildi (%s) -> %s", used, to_email)
                return EmailDeliveryResult(channel=used, recipient=to_email, attempts=attempts)

        elif channel == "smtp":
            if creds is None:
                attempts.append(
                    "SMTP -> SMTP_USER / SMTP_PASSWORD tanımlı değil veya hâlâ örnek değer "
                    "(GONDERICI_GMAIL_ADRESIN@gmail.com / 16_HANELI_UYGULAMA_SIFREN) içeriyor."
                )
                continue

            msg = _build_mime_message(
                sender_name=sender_name,
                sender_email=creds.user,
                to_email=to_email,
                subject=subject,
                text_body=text_body,
                html_body=html_body,
                attachments=atts,
            )
            for port in _smtp_port_sequence(creds.port):
                mode = "SSL" if port == 465 else "STARTTLS"
                try:
                    _send_via_smtp_port(msg, creds, port)
                    attempts.append(f"SMTP {creds.host}:{port} ({mode}) -> BAŞARILI")
                    logger.info("E-posta gönderildi (smtp:%s) -> %s", port, to_email)
                    return EmailDeliveryResult(
                        channel=f"smtp:{port}", recipient=to_email, attempts=attempts
                    )
                except smtplib.SMTPAuthenticationError as exc:
                    err = exc.smtp_error.decode("utf-8", errors="ignore") if isinstance(exc.smtp_error, bytes) else str(exc.smtp_error)
                    attempts.append(
                        f"SMTP {creds.host}:{port} ({mode}) -> Kimlik doğrulama hatası ({exc.smtp_code}): {err.strip()} "
                        "— Gmail için 2 Adımlı Doğrulama açık olmalı ve 16 haneli Uygulama Şifresi kullanılmalıdır."
                    )
                    break  # Şifre yanlışsa diğer portları denemek anlamsız
                except (socket.timeout, TimeoutError) as exc:
                    attempts.append(f"SMTP {creds.host}:{port} ({mode}) -> Zaman aşımı: {exc}")
                except Exception as exc:
                    attempts.append(f"SMTP {creds.host}:{port} ({mode}) -> {type(exc).__name__}: {exc}")
                logger.warning("SMTP denemesi başarısız: %s", attempts[-1])

    if not attempts:
        attempts.append("Hiçbir e-posta kanalı (SMTP veya HTTP API) yapılandırılmamış.")
    raise EmailDeliveryError(" | ".join(attempts))
