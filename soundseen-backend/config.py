from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    supabase_url: str = ""
    supabase_key: str = ""
    # HS256 secret for verifying Supabase Auth JWTs server-side.
    # Supabase dashboard → Project Settings → API → JWT Secret.
    supabase_jwt_secret: str = ""
    env: str = "development"
    model_dir: str = "./models"
    max_file_size_mb: int = 50
    modal_token_id: str = ""
    modal_token_secret: str = ""
    # CORS origins for the web frontend. Comma-separated in env. The regex
    # below is the catch-all — it covers any localhost port (3000, 3001,
    # 3002…) and Vercel preview deployments. Override via env if you need a
    # different prod domain.
    cors_origins: str = ""
    cors_origin_regex: str = (
        r"https?://(localhost|127\.0\.0\.1)(:\d+)?"
        r"|https://soundseen-.*\.vercel\.app"
    )

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()
