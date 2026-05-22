"""Supabase Auth JWT verification deps for FastAPI routes.

Supabase has two signing modes:

* **Asymmetric (RS256/ES256)** — the modern default. Tokens are signed
  with a project-specific private key; we verify against the matching
  public key fetched from the project's JWKS endpoint.
* **Legacy HS256** — older projects still use a shared secret. If
  `SUPABASE_JWT_SECRET` is set we use it as a fallback.

`PyJWKClient` caches the JWKS response between requests so each /analyze
call costs one local signature check, not an HTTP hop.
"""

import logging

import jwt
from fastapi import Header, HTTPException

from config import settings

logger = logging.getLogger(__name__)

_jwks_client: jwt.PyJWKClient | None = None


def _jwks() -> jwt.PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        if not settings.supabase_url:
            raise HTTPException(
                status_code=500,
                detail="SUPABASE_URL is not configured on the server",
            )
        url = (
            settings.supabase_url.rstrip("/")
            + "/auth/v1/.well-known/jwks.json"
        )
        _jwks_client = jwt.PyJWKClient(url, cache_keys=True)
    return _jwks_client


def _decode(token: str) -> dict:
    try:
        header = jwt.get_unverified_header(token)
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")

    alg = header.get("alg")
    try:
        if alg == "HS256":
            if not settings.supabase_jwt_secret:
                raise HTTPException(
                    status_code=500,
                    detail="SUPABASE_JWT_SECRET is not configured on the server",
                )
            return jwt.decode(
                token,
                settings.supabase_jwt_secret,
                algorithms=["HS256"],
                audience="authenticated",
            )
        if alg in ("RS256", "ES256"):
            signing_key = _jwks().get_signing_key_from_jwt(token).key
            return jwt.decode(
                token,
                signing_key,
                algorithms=[alg],
                audience="authenticated",
            )
        raise HTTPException(
            status_code=401, detail=f"Unsupported JWT algorithm: {alg}"
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("JWKS verification failed")
        raise HTTPException(
            status_code=401, detail=f"Could not verify token: {e}"
        )


async def current_user_id(
    authorization: str | None = Header(default=None),
) -> str:
    """Required-auth dep. Returns the Supabase user uuid (jwt.sub) or 401."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    payload = _decode(authorization.removeprefix("Bearer "))
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(status_code=401, detail="Token has no subject")
    return sub


async def optional_user_id(
    authorization: str | None = Header(default=None),
) -> str | None:
    """Optional-auth dep. Returns user uuid or None. Never 401s."""
    if not authorization or not authorization.startswith("Bearer "):
        return None
    try:
        payload = _decode(authorization.removeprefix("Bearer "))
    except HTTPException:
        return None
    return payload.get("sub")
