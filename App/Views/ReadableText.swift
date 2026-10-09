import SwiftUI
import StormRadioCore

/// Product text you can tap: tapping a word starts reading aloud from that word, and the word being
/// spoken is highlighted. "Original" shows the product exactly as issued (fixed-width).
struct ReadableText: View {
    @ObservedObject private var speech: SpeechCenter
    let text: String
    let raw: String
    let sourceID: String
    let title: String
    private let paragraphs: [Paragraph]
    @State private var showOriginal = false
    private let follow = true

    struct Paragraph: Identifiable, Equatable {
        let offset: Int
        let text: String
        var id: Int { offset }
        var length: Int { (text as NSString).length }
    }

    /// `text` is the product text (NWS line wrapping is undone for display and reading).
    init(_ text: String, sourceID: String, title: String, speech: SpeechCenter) {
        self.raw = text
        self.text = Self.unwrap(text)
        self.sourceID = sourceID
        self.title = title
        self._speech = ObservedObject(wrappedValue: speech)
        var paras: [Paragraph] = []
        let ns = self.text as NSString
        var start = 0
        while start < ns.length {
            let r = ns.range(of: "\n\n", options: [], range: NSRange(location: start, length: ns.length - start))
            let end = r.location == NSNotFound ? ns.length : r.location
            let piece = ns.substring(with: NSRange(location: start, length: end - start))
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { paras.append(Paragraph(offset: start, text: piece)) }
            start = r.location == NSNotFound ? ns.length : r.location + r.length
        }
        paragraphs = paras
    }

    /// Joins hard-wrapped lines inside paragraphs; keeps bullets and blank-line paragraph breaks.
    static func unwrap(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out = ""
        var prevBlank = true
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                if !prevBlank { out += "\n\n" }
                prevBlank = true
                continue
            }
            let startsItem = t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix(".") || t.hasPrefix("&&") || t.hasPrefix("$$")
            if prevBlank { out += t } else if startsItem { out += "\n" + t } else { out += " " + t }
            prevBlank = false
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var highlight: NSRange? {
        speech.readingSourceID == sourceID ? speech.readingHighlight : nil
    }

    private var activeParagraph: Int? {
        guard let h = highlight else { return nil }
        return paragraphs.last(where: { $0.offset <= h.location })?.offset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if speech.isReading(sourceID) {
                    Button { speech.stopAll() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { speech.read(text: text, from: 0, sourceID: sourceID, title: title) } label: {
                        Label("Read from start", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Toggle("Original", isOn: $showOriginal).toggleStyle(.button).font(.caption)
            }
            if showOriginal {
                ScrollView(.horizontal) {
                    Text(raw)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                Text("Tap any word to start reading from there.").font(.caption).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(paragraphs) { p in
                            ReadableParagraph(paragraph: p, highlight: localHighlight(p))
                                .equatable()
                                .id(p.offset)
                        }
                    }
                    .onChange(of: activeParagraph) { _, para in
                        guard follow, let para else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(para, anchor: .center) }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "stormradio-word", let host = url.host, let off = Int(host) else { return .systemAction }
                    speech.read(text: text, from: off, sourceID: sourceID, title: title)
                    return .handled
                })
            }
        }
    }

    private func localHighlight(_ p: Paragraph) -> NSRange? {
        guard let h = highlight, h.location >= p.offset, h.location < p.offset + p.length else { return nil }
        return NSRange(location: h.location - p.offset, length: min(h.length, p.offset + p.length - h.location))
    }
}

/// One paragraph: every word is a link to "start reading here".
struct ReadableParagraph: View, Equatable {
    let paragraph: ReadableText.Paragraph
    let highlight: NSRange?

    var body: some View {
        Text(attributed)
            .tint(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        let ns = paragraph.text as NSString
        var result = AttributedString()
        var cursor = 0
        let words = Self.wordRegex.matches(in: paragraph.text, range: NSRange(location: 0, length: ns.length))
        for m in words {
            let r = m.range
            if r.location > cursor {
                result.append(AttributedString(ns.substring(with: NSRange(location: cursor, length: r.location - cursor))))
            }
            var word = AttributedString(ns.substring(with: r))
            word.link = URL(string: "stormradio-word://\(paragraph.offset + r.location)")
            if let h = highlight, NSIntersectionRange(h, r).length > 0 || (h.length == 0 && h.location == r.location) {
                word.backgroundColor = .yellow.opacity(0.55)
                word.foregroundColor = .black
            }
            result.append(word)
            cursor = r.location + r.length
        }
        if cursor < ns.length { result.append(AttributedString(ns.substring(from: cursor))) }
        return result
    }

    private static let wordRegex = try! NSRegularExpression(pattern: "\\S+")
}
