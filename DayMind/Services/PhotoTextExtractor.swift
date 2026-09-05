import Foundation
import UIKit
import Vision
import DayMindCore

/// Text found in a photo, plus the dates the system detector could read from it.
struct ExtractedPhotoText: Equatable, Sendable {
    var lines: [String]
    var detectedDates: [DetectedDate]

    var fullText: String { lines.joined(separator: "\n") }
    var isEmpty: Bool { lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    struct DetectedDate: Equatable, Sendable, Identifiable {
        var id: String { "\(date.timeIntervalSince1970)-\(sourceText)" }
        var date: Date
        var hasTime: Bool
        var sourceText: String
    }
}

/// On-device text recognition (Apple Vision) for appointment cards, screenshots and notices.
/// Text extraction only — it does not "understand" the image. Nothing leaves the device.
enum PhotoTextExtractor {
    enum ExtractionError: LocalizedError {
        case unreadableImage
        case noText
        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "That image could not be read."
            case .noText: return "I couldn't find any readable text in that picture."
            }
        }
    }

    static func recognizeText(in image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { throw ExtractionError.unreadableImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Top-to-bottom reading order.
                let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                let lines = sorted.compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Full pipeline: recognise text, then find dates with Foundation's data detector (plus the
    /// app's own parser as a fallback for phrases like "next Tuesday at 3").
    static func extract(from image: UIImage, calendar: Calendar, now: Date = Date(), defaults: TimeDefaults) async throws -> ExtractedPhotoText {
        let lines = try await recognizeText(in: image)
        guard !lines.isEmpty else { throw ExtractionError.noText }
        return ExtractedPhotoText(lines: lines, detectedDates: PhotoDateFinder.dates(in: lines, calendar: calendar, now: now, defaults: defaults))
    }
}

/// Finds dates in recognised text. Deterministic; testable without Vision.
enum PhotoDateFinder {
    static func dates(in lines: [String], calendar: Calendar, now: Date, defaults: TimeDefaults) -> [ExtractedPhotoText.DetectedDate] {
        var found: [ExtractedPhotoText.DetectedDate] = []
        let joined = lines.joined(separator: "\n")
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = joined as NSString
            for match in detector.matches(in: joined, options: [], range: NSRange(location: 0, length: ns.length)) {
                guard var date = match.date else { continue }
                let source = ns.substring(with: match.range)
                // The detector assumes the current time zone; keep the wall-clock time in the app's zone.
                if let tz = match.timeZone, tz != calendar.timeZone {
                    let comps = Calendar.current.dateComponents(in: tz, from: date)
                    var c = DateComponents(); c.year = comps.year; c.month = comps.month; c.day = comps.day; c.hour = comps.hour; c.minute = comps.minute
                    date = calendar.date(from: c) ?? date
                }
                let hasTime = Self.mentionsTime(source)
                if !hasTime {
                    // Detector puts date-only matches at noon; use the configured morning time instead.
                    let day = calendar.startOfDay(for: date)
                    date = calendar.date(bySettingHour: defaults.morning.hour, minute: defaults.morning.minute, second: 0, of: day) ?? date
                }
                found.append(.init(date: date, hasTime: hasTime, sourceText: source))
            }
        }
        if found.isEmpty {
            let parser = NaturalDateParser(calendar: calendar, now: now, defaults: defaults)
            for line in lines {
                if let parsed = parser.parse(line), parsed.hasExplicitDate {
                    found.append(.init(date: parsed.date, hasTime: parsed.hasExplicitTime, sourceText: line))
                }
            }
        }
        var seen = Set<Date>()
        return found.filter { seen.insert($0.date).inserted }.sorted { $0.date < $1.date }
    }

    static func mentionsTime(_ text: String) -> Bool {
        text.range(of: #"\d{1,2}(:\d{2})?\s*(am|pm|AM|PM|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|noon|midnight"#, options: .regularExpression) != nil
    }

    /// A short title for a photo-derived reminder: the first line with letters that is not the date itself.
    static func suggestedTitle(from lines: [String], excluding dateSources: [String]) -> String {
        let lowerSources = dateSources.map { $0.lowercased() }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.rangeOfCharacter(from: .letters) != nil, trimmed.count >= 4, trimmed.count <= 80 else { continue }
            if lowerSources.contains(where: { trimmed.lowercased().contains($0) && trimmed.count < $0.count + 6 }) { continue }
            return SpokenFormatter.capitalizeFirst(trimmed)
        }
        return "Appointment from photo"
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Stores attached photos only when the user asks to keep them. Files live in the app's own
/// Application Support directory and are never uploaded.
enum PhotoStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the file name to reference from notes, e.g. "[photo: 3F2A….jpg]".
    static func save(_ image: UIImage) throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.8) else { throw PhotoTextExtractor.ExtractionError.unreadableImage }
        let name = UUID().uuidString + ".jpg"
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        return name
    }

    static func noteReference(_ name: String) -> String { "[photo: \(name)]" }

    static func image(named name: String) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
    }
}
