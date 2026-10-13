import FluidAudio
import Foundation

/// Headless mode of the Whisper binary for Debrief (and anything else that
/// needs the same ParakeetEngine without the dictation HUD).
///
///   Whisper --ensure      load models, print ready, exit
///   Whisper --transcribe  load once, then JSON-lines on stdin/stdout
enum TranscribeCLI {
    private static let engineName = "Parakeet TDT v3 (FluidAudio)"

    static func run() {
        let ensureOnly = CommandLine.arguments.contains("--ensure")
            && !CommandLine.arguments.contains("--transcribe")
        let engine = ParakeetEngine()
        engine.latinOnly = ParakeetEngine.usesLatinScript(Config.load().language)
        engine.start()
        let deadline = Date().addingTimeInterval(120)
        while !engine.isReady && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard engine.isReady else {
            emit(["error": "FluidAudio failed to load"])
            exit(1)
        }
        emit(["status": "ready", "engine": engineName])
        if ensureOnly { exit(0) }
        serve(engine)
    }

    private static func serve(_ engine: ParakeetEngine) {
        let converter = AudioConverter()
        while let raw = readLine(strippingNewline: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "quit" { break }
            guard let wav = wavPath(from: line) else {
                emit(["error": "bad request"])
                continue
            }
            do {
                let samples = try converter.resampleAudioFile(path: wav)
                let text = engine.transcribe(samples, timeout: 90)
                emit(["text": Numbers.digitize(text)])
            } catch {
                NSLog("Whisper transcribe CLI: \(error)")
                emit(["error": error.localizedDescription, "text": ""])
            }
        }
    }

    private static func wavPath(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wav = obj["wav"] as? String, !wav.isEmpty else { return nil }
        return wav
    }

    private static func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
}
