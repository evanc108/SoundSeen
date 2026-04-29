//
//  APIClient.swift
//  SoundSeen
//
//  Thin async wrapper over the SoundSeen backend. The backend contract lives
//  in soundseen-backend/main.py; any field additions there must be mirrored
//  in SongAnalysis.swift.
//

import Foundation

enum APIError: LocalizedError {
    case invalidResponse
    case http(status: Int, body: String)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Server error (HTTP \(status))."
            }
            return "Server error (HTTP \(status)): \(trimmed)"
        case .transport(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .decoding(let underlying):
            return "Could not decode server response: \(underlying.localizedDescription)"
        }
    }
}

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let baseURL: URL

    init(baseURL: URL = Config.backendBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Public endpoints

    func health() async throws -> Bool {
        let url = baseURL.appendingPathComponent("health")
        let (data, response) = try await perform(URLRequest(url: url))
        struct HealthResponse: Decodable { let status: String }
        do {
            let decoded = try JSONDecoder.soundSeen.decode(HealthResponse.self, from: data)
            _ = response
            return decoded.status == "ok"
        } catch {
            throw APIError.decoding(error)
        }
    }

    func fetchSong(id: String) async throws -> SongAnalysis {
        let url = baseURL.appendingPathComponent("song").appendingPathComponent(id)
        let (data, _) = try await perform(URLRequest(url: url))
        do {
            return try JSONDecoder.soundSeen.decode(SongAnalysis.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Upload an audio file to POST /analyze and return the parsed response.
    /// The caller is responsible for providing a readable `fileURL` — if the
    /// URL is security-scoped, start/stop scope access before and after this call.
    func analyze(fileURL: URL, filename: String, mimeType: String) async throws -> SongAnalysis {
        let url = baseURL.appendingPathComponent("analyze")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Long timeout because analysis can take ~5-15s depending on song length.
        request.timeoutInterval = 120

        let boundary = "soundseen.\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw APIError.transport(error)
        }

        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fieldName: "file",
            filename: filename,
            mimeType: mimeType,
            fileData: fileData
        )

        let (data, _) = try await perform(request)
        do {
            return try JSONDecoder.soundSeen.decode(SongAnalysis.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// POST /analyze_chunk with raw 16-bit PCM WAV bytes. Short timeout (5s)
    /// — the server path is <100ms; if it's slower than 5s the network is
    /// broken and we'd rather keep the visualizer running on stale emotion.
    func analyzeChunk(wav: Data, clientId: String) async throws -> (Double, Double) {
        let url = baseURL.appendingPathComponent("analyze_chunk")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.httpBody = wav

        let (data, _) = try await perform(request)
        struct ChunkEmotion: Decodable { let valence: Double; let arousal: Double }
        do {
            let decoded = try JSONDecoder.soundSeen.decode(ChunkEmotion.self, from: data)
            return (decoded.valence, decoded.arousal)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Internals

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: body)
        }
        return (data, http)
    }

    private static func multipartBody(
        boundary: String,
        fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
