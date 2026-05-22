# SoundSeen

> Upload a song. Get a cinematic visualization back. Share it.

SoundSeen analyzes uploaded audio (mood, structure, beat grid, spectral
content) and renders a per-song video on a GPU, then plays it back in
the browser. Renders are public by default — every visualization lands
in a shared gallery — and signed-in users have a "My uploads" view.

## Stack

| Piece | Tech | Hosted on |
|-------|------|-----------|
| Frontend | Next.js 16 (App Router) + Tailwind 4 + Supabase Auth | Vercel |
| Backend API | FastAPI + librosa + Essentia + pyjwt | Railway |
| Renderer | Three.js, headless via Playwright, on GPU containers | Modal |
| Data + Auth + Storage | Postgres + magic-link auth + object storage | Supabase |

```
soundseen-web/         Next.js app (this is the user-facing surface)
soundseen-backend/     FastAPI — /analyze, /render, /jobs, /gallery, /me/songs
soundseen-renderer/    Modal app: Three.js scene rendered to mp4
scripts/               Misc operational scripts
renders/               Sample renders (gitignored except a few seed files)
```

## Local dev

### Backend

```sh
cd soundseen-backend
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in SUPABASE_URL, SUPABASE_KEY, SUPABASE_JWT_SECRET
uvicorn main:app --reload --port 8000
```

### Frontend

```sh
cd soundseen-web
cp .env.example .env.local   # fill in NEXT_PUBLIC_SUPABASE_URL/ANON_KEY
npm install
npm run dev    # http://localhost:3000
```

### Renderer

The renderer runs on Modal. You don't run it locally — deploy it once and the backend invokes it remotely:

```sh
cd soundseen-renderer
modal deploy modal_app.py
```

## Required configuration

**Supabase**: create the `songs` and `render_jobs` tables, enable Row Level
Security with public-read policies, and turn on Email + Google auth
providers. The exact SQL lives in
[`docs/supabase-schema.sql`](docs/supabase-schema.sql) (TODO: extract).

**Railway env**: `SUPABASE_URL`, `SUPABASE_KEY`, `SUPABASE_JWT_SECRET`,
`MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET`, plus optional
`CORS_ORIGINS` to allow your Vercel domain.

**Vercel env**: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`,
`NEXT_PUBLIC_BACKEND_URL` (the Railway URL).

## Authors

Team BENEV: Benson Vo, Vincent Liu, Edward Lee, Nicole Zhou, Evan Chang.
