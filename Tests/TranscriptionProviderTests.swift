import Foundation

@main
struct TranscriptionProviderTests {
    static func main() {
        testExistingSetupStaysOpenAICompatible()
        testSarvamURLSelectsSarvam()
        testSarvamKeyWithEmptyURLUsesHardcodedSarvamURL()
        testExplicitPreferenceOverridesDetection()
        testTranscriptionEndpointPaths()
        testAuthorizationHeaders()
        testSarvamLanguageCodes()
        testSarvamModelCoercion()
        testFormFieldsPerProvider()
        testMultipartBodyLayout()
        testTranscriptFieldNames()
        print("TranscriptionProviderTests passed")
    }

    // MARK: Endpoint resolution

    private static func testExistingSetupStaysOpenAICompatible() {
        let endpoint = TranscriptionProvider.resolveEndpoint(
            preference: .auto,
            transcriptionAPIURL: "",
            transcriptionAPIKey: "",
            fallbackBaseURL: "https://api.groq.com/openai/v1",
            fallbackAPIKey: "gsk_existing"
        )

        expectEqual(endpoint.provider, .openAICompatible)
        expectEqual(endpoint.baseURL, "https://api.groq.com/openai/v1")
        expectEqual(endpoint.apiKey, "gsk_existing")
    }

    private static func testSarvamURLSelectsSarvam() {
        for url in [
            "https://api.sarvam.ai",
            "https://api.sarvam.ai/",
            "https://api.sarvam.ai/speech-to-text",
            "  https://api.sarvam.ai  "
        ] {
            let endpoint = TranscriptionProvider.resolveEndpoint(
                preference: .auto,
                transcriptionAPIURL: url,
                transcriptionAPIKey: "some-key",
                fallbackBaseURL: "https://api.groq.com/openai/v1",
                fallbackAPIKey: "gsk_existing"
            )
            expectEqual(endpoint.provider, .sarvam, "URL \(url) should select Sarvam")
            expectEqual(endpoint.apiKey, "some-key")
        }

        // A non-Sarvam custom URL keeps the OpenAI-compatible protocol.
        let openAI = TranscriptionProvider.resolveEndpoint(
            preference: .auto,
            transcriptionAPIURL: "https://api.openai.com/v1",
            transcriptionAPIKey: "sk_looks_like_sarvam",
            fallbackBaseURL: "https://api.groq.com/openai/v1",
            fallbackAPIKey: "gsk_existing"
        )
        expectEqual(openAI.provider, .openAICompatible, "An explicit URL must outrank key sniffing")
        expectEqual(openAI.baseURL, "https://api.openai.com/v1")
    }

    private static func testSarvamKeyWithEmptyURLUsesHardcodedSarvamURL() {
        let endpoint = TranscriptionProvider.resolveEndpoint(
            preference: .auto,
            transcriptionAPIURL: "",
            transcriptionAPIKey: "sk_abc123",
            fallbackBaseURL: "https://api.groq.com/openai/v1",
            fallbackAPIKey: "gsk_existing"
        )

        expectEqual(endpoint.provider, .sarvam)
        expectEqual(endpoint.baseURL, TranscriptionProvider.sarvamDefaultBaseURL)
        expectEqual(endpoint.apiKey, "sk_abc123")

        // A Groq key must never be mistaken for a Sarvam one.
        expect(
            TranscriptionProvider.looksLikeSarvamAPIKey("gsk_abc123") == false,
            "Groq keys must not be detected as Sarvam"
        )
        expect(
            TranscriptionProvider.looksLikeSarvamAPIKey("sk-abc123") == false,
            "OpenAI keys must not be detected as Sarvam"
        )
    }

    private static func testExplicitPreferenceOverridesDetection() {
        let forcedSarvam = TranscriptionProvider.resolveEndpoint(
            preference: .sarvam,
            transcriptionAPIURL: "",
            transcriptionAPIKey: "legacy-uuid-style-key",
            fallbackBaseURL: "https://api.groq.com/openai/v1",
            fallbackAPIKey: "gsk_existing"
        )
        expectEqual(forcedSarvam.provider, .sarvam)
        expectEqual(forcedSarvam.baseURL, TranscriptionProvider.sarvamDefaultBaseURL)

        let forcedOpenAI = TranscriptionProvider.resolveEndpoint(
            preference: .openAICompatible,
            transcriptionAPIURL: "https://api.sarvam.ai",
            transcriptionAPIKey: "sk_abc123",
            fallbackBaseURL: "https://api.groq.com/openai/v1",
            fallbackAPIKey: "gsk_existing"
        )
        expectEqual(forcedOpenAI.provider, .openAICompatible)
    }

    private static func testTranscriptionEndpointPaths() {
        expectEqual(
            transcriptionURLString(baseURL: "https://api.groq.com/openai/v1", provider: .openAICompatible),
            "https://api.groq.com/openai/v1/audio/transcriptions"
        )
        expectEqual(
            transcriptionURLString(baseURL: "https://api.sarvam.ai", provider: .sarvam),
            "https://api.sarvam.ai/speech-to-text"
        )
        expectEqual(
            transcriptionURLString(baseURL: "https://api.sarvam.ai/", provider: .sarvam),
            "https://api.sarvam.ai/speech-to-text"
        )
        // Pasting the full endpoint from Sarvam's docs must not double up.
        expectEqual(
            transcriptionURLString(baseURL: "https://api.sarvam.ai/speech-to-text", provider: .sarvam),
            "https://api.sarvam.ai/speech-to-text"
        )
    }

    private static func testAuthorizationHeaders() {
        expectEqual(TranscriptionProvider.openAICompatible.authorizationHeaderName, "Authorization")
        expectEqual(
            TranscriptionProvider.openAICompatible.authorizationHeaderValue(apiKey: "abc"),
            "Bearer abc"
        )
        expectEqual(TranscriptionProvider.sarvam.authorizationHeaderName, "api-subscription-key")
        expectEqual(TranscriptionProvider.sarvam.authorizationHeaderValue(apiKey: "abc"), "abc")
    }

    // MARK: Sarvam request details

    private static func testSarvamLanguageCodes() {
        expectEqual(SarvamTranscription.languageCode(for: nil), "unknown")
        expectEqual(SarvamTranscription.languageCode(for: ""), "unknown")
        expectEqual(SarvamTranscription.languageCode(for: "en"), "en-IN")
        expectEqual(SarvamTranscription.languageCode(for: "hi"), "hi-IN")
        // Languages Sarvam does not model fall back to auto-detection rather
        // than being rejected as an invalid language_code.
        expectEqual(SarvamTranscription.languageCode(for: "sv"), "unknown")
        // A regional code the user configured directly is passed through.
        expectEqual(SarvamTranscription.languageCode(for: "ta-IN"), "ta-IN")
    }

    private static func testSarvamModelCoercion() {
        expectEqual(SarvamTranscription.resolvedModel("whisper-large-v3"), "saaras:v4")
        expectEqual(SarvamTranscription.resolvedModel(""), "saaras:v4")
        expectEqual(SarvamTranscription.resolvedModel("saaras:v4"), "saaras:v4")
        expectEqual(SarvamTranscription.resolvedModel(" saarika:v2.5 "), "saarika:v2.5")
    }

    private static func testFormFieldsPerProvider() {
        let openAIFields = TranscriptionService.formFields(
            provider: .openAICompatible,
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "en",
            inputAudioCodec: "wav",
            sampleRate: "16000"
        )
        expectEqual(
            fieldDescription(openAIFields),
            "model=whisper-large-v3;response_format=verbose_json;language=en",
            "The OpenAI-compatible field set must not change"
        )

        let sarvamFields = TranscriptionService.formFields(
            provider: .sarvam,
            model: "saaras:v4",
            responseFormat: "json",
            language: "hi",
            inputAudioCodec: "wav",
            sampleRate: "16000"
        )
        expectEqual(
            fieldDescription(sarvamFields),
            "model=saaras:v4;language_code=hi-IN;mode=transcribe;input_audio_codec=wav;sample_rate=16000"
        )

        // Clearing the codec/sample-rate overrides omits the fields so Sarvam
        // auto-detects them.
        let autoDetectFields = TranscriptionService.formFields(
            provider: .sarvam,
            model: "saaras:v4",
            responseFormat: "json",
            language: nil,
            inputAudioCodec: nil,
            sampleRate: nil
        )
        expectEqual(
            fieldDescription(autoDetectFields),
            "model=saaras:v4;language_code=unknown;mode=transcribe"
        )
    }

    private static func testMultipartBodyLayout() {
        let body = TranscriptionService.makeMultipartBody(
            audioData: Data([0x01, 0x02]),
            fileName: "clip.wav",
            contentType: "audio/wav",
            fields: [(name: "model", value: "saaras:v4")],
            boundary: "BOUND"
        )
        let text = String(decoding: body, as: UTF8.self)

        expect(text.hasPrefix("--BOUND\r\n"), "Body must open with the boundary")
        expect(
            text.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\nsaaras:v4\r\n"),
            "Text fields must be written as multipart form fields"
        )
        expect(
            text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\n"),
            "Audio must be sent as the file field"
        )
        expect(text.contains("Content-Type: audio/wav\r\n"), "WAV uploads must declare audio/wav")
        expect(text.hasSuffix("--BOUND--\r\n"), "Body must close the boundary")
        expectEqual(TranscriptionService.audioContentType(for: "clip.wav"), "audio/wav")
    }

    private static func testTranscriptFieldNames() {
        expectEqual(TranscriptionService.transcriptText(from: ["text": "from openai"]), "from openai")
        expectEqual(TranscriptionService.transcriptText(from: ["transcript": "from sarvam"]), "from sarvam")
        expect(
            TranscriptionService.transcriptText(from: ["request_id": "abc"]) == nil,
            "A payload with no transcript field must not be treated as a transcript"
        )
    }

    // MARK: Helpers

    private static func transcriptionURLString(baseURL: String, provider: TranscriptionProvider) -> String {
        guard let url = try? TranscriptionService.transcriptionEndpointURL(
            baseURL: baseURL,
            provider: provider
        ) else {
            return "<invalid>"
        }
        return url.absoluteString
    }

    private static func fieldDescription(_ fields: [(name: String, value: String)]) -> String {
        fields.map { "\($0.name)=\($0.value)" }.joined(separator: ";")
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard actual != expected else { return }
        let suffix = message.isEmpty ? "" : " — \(message)"
        fail("expected \(expected), got \(actual)\(suffix)", file: file, line: line)
    }

    private static func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard !condition else { return }
        fail(message, file: file, line: line)
    }

    private static func fail(_ message: String, file: StaticString, line: UInt) -> Never {
        FileHandle.standardError.write(Data("\(file):\(line): \(message)\n".utf8))
        exit(1)
    }
}
