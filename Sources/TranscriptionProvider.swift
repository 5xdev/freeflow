import Foundation

/// The wire protocol a transcription endpoint speaks.
///
/// FreeFlow has always spoken the OpenAI-compatible multipart protocol
/// (`POST <base>/audio/transcriptions` with `Authorization: Bearer`). Sarvam
/// uses a different path, a different auth header, a different field set, and a
/// different response field, so the provider is resolved once per request and
/// then drives every one of those details.
enum TranscriptionProvider: String {
    case openAICompatible
    case sarvam
}

/// The user-facing provider choice. `auto` keeps the historical behavior of
/// inferring everything from the transcription URL and key the user typed, so
/// existing installs never change protocol without the user doing something.
enum TranscriptionProviderPreference: String, CaseIterable, Identifiable {
    case auto
    case openAICompatible
    case sarvam

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .openAICompatible: return "OpenAI-compatible"
        case .sarvam: return "Sarvam"
        }
    }
}

/// The provider, base URL, and key a transcription request should actually use,
/// after applying the "falls back to the general API settings when empty" rules.
struct ResolvedTranscriptionEndpoint {
    let provider: TranscriptionProvider
    let baseURL: String
    let apiKey: String
}

extension TranscriptionProvider {
    /// Used when Sarvam is selected (or detected from the key) but the user left
    /// the Transcription API URL empty. Without this the empty field would fall
    /// back to the general API Base URL and send a Sarvam key to Groq.
    static let sarvamDefaultBaseURL = "https://api.sarvam.ai"

    static func resolveEndpoint(
        preference: TranscriptionProviderPreference,
        transcriptionAPIURL: String,
        transcriptionAPIKey: String,
        fallbackBaseURL: String,
        fallbackAPIKey: String
    ) -> ResolvedTranscriptionEndpoint {
        let trimmedURL = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = resolveProvider(
            preference: preference,
            transcriptionAPIURL: trimmedURL,
            transcriptionAPIKey: trimmedKey
        )

        let baseURL: String
        if !trimmedURL.isEmpty {
            baseURL = trimmedURL
        } else if provider == .sarvam {
            baseURL = sarvamDefaultBaseURL
        } else {
            baseURL = fallbackBaseURL
        }

        return ResolvedTranscriptionEndpoint(
            provider: provider,
            baseURL: baseURL,
            apiKey: trimmedKey.isEmpty ? fallbackAPIKey : trimmedKey
        )
    }

    /// Detection order under `auto`: an explicitly entered URL wins, because it
    /// is the unambiguous signal. Only when no URL was entered do we look at the
    /// transcription key's shape. The general API key is never sniffed — if the
    /// transcription key field is empty the user has not pointed transcription
    /// anywhere new, so the OpenAI-compatible path must stay.
    static func resolveProvider(
        preference: TranscriptionProviderPreference,
        transcriptionAPIURL: String,
        transcriptionAPIKey: String
    ) -> TranscriptionProvider {
        switch preference {
        case .openAICompatible:
            return .openAICompatible
        case .sarvam:
            return .sarvam
        case .auto:
            break
        }

        let trimmedURL = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            return isSarvamHost(trimmedURL) ? .sarvam : .openAICompatible
        }
        return looksLikeSarvamAPIKey(transcriptionAPIKey) ? .sarvam : .openAICompatible
    }

    static func isSarvamHost(_ urlString: String) -> Bool {
        var candidate = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        // Tolerate a scheme-less host so detection still works while the user is
        // mid-edit. normalizedBaseURL(from:) still rejects it at request time.
        if !candidate.contains("://") {
            candidate = "https://" + candidate
        }
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else { return false }
        return host == "sarvam.ai" || host.hasSuffix(".sarvam.ai")
    }

    /// Sarvam issues subscription keys with an `sk_` prefix. Groq (`gsk_`) and
    /// OpenAI (`sk-`) keys use different shapes, so this never claims one of
    /// those. Older UUID-shaped Sarvam keys are not detectable — those users
    /// enter the URL or pick Sarvam explicitly.
    static func looksLikeSarvamAPIKey(_ key: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sk_")
    }

    /// The full transcription endpoint for a normalized base URL.
    func transcriptionEndpoint(baseURL: URL) -> URL {
        switch self {
        case .openAICompatible:
            return baseURL
                .appendingPathComponent("audio")
                .appendingPathComponent("transcriptions")
        case .sarvam:
            // Accept both `https://api.sarvam.ai` and the full endpoint URL from
            // Sarvam's own docs, so pasting either into Settings works.
            if baseURL.path.lowercased().hasSuffix("/" + SarvamTranscription.endpointPath) {
                return baseURL
            }
            return baseURL.appendingPathComponent(SarvamTranscription.endpointPath)
        }
    }

    var authorizationHeaderName: String {
        switch self {
        case .openAICompatible: return "Authorization"
        case .sarvam: return SarvamTranscription.apiKeyHeaderName
        }
    }

    func authorizationHeaderValue(apiKey: String) -> String {
        switch self {
        case .openAICompatible: return "Bearer \(apiKey)"
        case .sarvam: return apiKey
        }
    }
}

/// Sarvam-specific request details, kept in one place so the service body stays
/// readable and the mapping rules are unit-testable.
enum SarvamTranscription {
    static let endpointPath = "speech-to-text"
    static let apiKeyHeaderName = "api-subscription-key"
    static let defaultModel = "saaras:v4"
    static let mode = "transcribe"
    /// Sent for "Auto-detect" and for any language Sarvam does not model.
    static let unknownLanguageCode = "unknown"

    /// AudioRecorder always writes a 16 kHz mono PCM16 RIFF WAV for upload (see
    /// `AudioRecorder.recordingTargetFormat`), so declare that container rather
    /// than `pcm_s16le`, which describes headerless raw PCM and would make
    /// Sarvam decode the RIFF header as audio.
    static let defaultInputAudioCodec = "wav"
    static let defaultSampleRate = "16000"

    /// Escape hatches for anyone feeding a differently-encoded file through a
    /// custom build. Setting either to an empty string omits the field entirely,
    /// which asks Sarvam to auto-detect.
    static let inputAudioCodecDefaultsKey = "sarvam_input_audio_codec"
    static let sampleRateDefaultsKey = "sarvam_sample_rate"

    static func inputAudioCodec(defaults: UserDefaults = .standard) -> String? {
        overriddenValue(
            defaultsKey: inputAudioCodecDefaultsKey,
            fallback: defaultInputAudioCodec,
            defaults: defaults
        )
    }

    static func sampleRate(defaults: UserDefaults = .standard) -> String? {
        overriddenValue(
            defaultsKey: sampleRateDefaultsKey,
            fallback: defaultSampleRate,
            defaults: defaults
        )
    }

    private static func overriddenValue(
        defaultsKey: String,
        fallback: String,
        defaults: UserDefaults
    ) -> String? {
        guard let override = defaults.string(forKey: defaultsKey) else { return fallback }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// FreeFlow stores ISO 639-1 codes; Sarvam expects regional BCP-47 codes.
    /// Only `en` and `hi` are reachable from the current language picker, but
    /// the rest of Sarvam's set is mapped so the picker can grow without another
    /// round trip through this file.
    private static let languageCodesByISO639_1: [String: String] = [
        "as": "as-IN",
        "bn": "bn-IN",
        "brx": "brx-IN",
        "doi": "doi-IN",
        "en": "en-IN",
        "gu": "gu-IN",
        "hi": "hi-IN",
        "kn": "kn-IN",
        "kok": "kok-IN",
        "ks": "ks-IN",
        "mai": "mai-IN",
        "ml": "ml-IN",
        "mni": "mni-IN",
        "mr": "mr-IN",
        "ne": "ne-IN",
        "od": "od-IN",
        "or": "od-IN",
        "pa": "pa-IN",
        "sa": "sa-IN",
        "sat": "sat-IN",
        "sd": "sd-IN",
        "ta": "ta-IN",
        "te": "te-IN",
        "ur": "ur-IN"
    ]

    static func languageCode(for language: String?) -> String {
        guard let language else { return unknownLanguageCode }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unknownLanguageCode }
        if let mapped = languageCodesByISO639_1[trimmed.lowercased()] {
            return mapped
        }
        // Already a regional code (for example "ta-IN") — pass it through rather
        // than discarding a language the user deliberately configured.
        if trimmed.contains("-") { return trimmed }
        return unknownLanguageCode
    }

    static func isSarvamModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("saaras") || normalized.hasPrefix("saarika")
    }

    /// Sarvam rejects Whisper model IDs, and `whisper-large-v3` is FreeFlow's
    /// stored default. Substitute Sarvam's default rather than sending a model
    /// the endpoint cannot serve.
    static func resolvedModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSarvamModel(trimmed) ? trimmed : defaultModel
    }
}
