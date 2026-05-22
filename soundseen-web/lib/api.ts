/** Thin fetch wrapper for the soundseen-backend FastAPI. The backend
 *  emits snake_case JSON; this module converts to camelCase at the edge
 *  so component code can stay idiomatic TypeScript. */

const baseURL = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000";

export type RenderStatus =
  | "queued"
  | "rendering"
  | "complete"
  | "failed"
  | "unavailable";

export interface RenderJobStatus {
  jobId: string;
  songId: string;
  status: RenderStatus;
  progress: number;
  videoUrl: string | null;
  error: string | null;
}

export interface SongCard {
  songId: string;
  filename: string | null;
  userId: string | null;
  createdAt: string;
  durationSeconds: number | null;
  bpm: number | null;
  videoUrl: string | null;
  renderStatus: RenderStatus | null;
}

export interface SongDetail {
  songId: string;
  filename: string;
  storagePath: string;
  durationSeconds: number;
  bpm: number;
  bandNames: string[];
  // The full analysis blob is huge — we only surface the summary fields
  // the playback view uses. If a future feature needs more, extend here.
}

function snakeToCamel(key: string): string {
  return key.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
}

function camelize<T>(value: unknown): T {
  if (Array.isArray(value)) return value.map((v) => camelize(v)) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      out[snakeToCamel(k)] = camelize(v);
    }
    return out as T;
  }
  return value as T;
}

async function jsonFetch<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`${baseURL}${path}`, {
    ...init,
    cache: "no-store",
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`HTTP ${res.status} ${path}: ${body}`);
  }
  return camelize<T>(await res.json());
}

function authHeaders(token?: string): RequestInit {
  return token ? { headers: { Authorization: `Bearer ${token}` } } : {};
}

export const api = {
  gallery: (limit = 24, offset = 0) =>
    jsonFetch<SongCard[]>(`/gallery?limit=${limit}&offset=${offset}`),

  song: (songId: string) => jsonFetch<SongDetail>(`/song/${songId}`),

  songOwner: (songId: string) =>
    jsonFetch<{ exists: boolean; userId: string | null }>(
      `/song/${songId}/owner`,
    ),

  deleteSong: async (songId: string, token: string) => {
    const res = await fetch(`${baseURL}/song/${songId}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}: ${await res.text()}`);
    }
    return camelize<{ deleted: string }>(await res.json());
  },

  renderStatus: (jobId: string) =>
    jsonFetch<RenderJobStatus>(`/render/${encodeURIComponent(jobId)}`),

  jobsForSongs: (songIds: string[]) => {
    if (songIds.length === 0) return Promise.resolve([] as RenderJobStatus[]);
    return jsonFetch<RenderJobStatus[]>(
      `/jobs?song_ids=${songIds.map(encodeURIComponent).join(",")}`,
    );
  },

  mySongs: (token: string, limit = 50, offset = 0) =>
    jsonFetch<SongCard[]>(
      `/me/songs?limit=${limit}&offset=${offset}`,
      authHeaders(token),
    ),

  /** Upload an mp3/wav/m4a. Returns the parsed SongAnalysis; the backend
   *  fires the Modal render asynchronously, so the caller should poll
   *  /jobs?song_ids=... to track render progress. */
  analyze: async (file: File, token: string) => {
    const form = new FormData();
    form.append("file", file);
    const res = await fetch(`${baseURL}/analyze`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
      body: form,
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}: ${await res.text()}`);
    }
    return camelize<{ songId: string; filename: string; durationSeconds: number; bpm: number }>(
      await res.json(),
    );
  },
};
