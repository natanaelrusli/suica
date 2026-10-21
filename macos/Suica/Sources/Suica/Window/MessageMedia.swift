import AppKit
import SuicaCore
import SwiftUI

// MARK: - Loading images

/// Loads the images (GIFs) a template links to, for the previews: https only, 10 s, at most
/// 5 MB, and only what decodes as an image. Results are kept for the session.
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    enum Failure: Error { case notHTTPS, notImage, tooLarge, unreachable }

    private static let maxBytes = 5 * 1024 * 1024
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()
    private var cache: [URL: NSImage] = [:]

    func image(at url: URL) async -> Result<NSImage, Failure> {
        if let cached = cache[url] { return .success(cached) }
        guard url.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failure(.notImage) }
            if response.expectedContentLength > Self.maxBytes { return .failure(.tooLarge) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes { return .failure(.tooLarge) }
            }
            guard let image = NSImage(data: data), image.isValid else { return .failure(.notImage) }
            cache[url] = image
            return .success(image)
        } catch {
            return .failure(.unreachable)
        }
    }
}

/// An `NSImageView` that plays an animated GIF.
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

/// The image at `url`, animated, fitted into `maxHeight`; a quiet placeholder while it loads or
/// when it cannot be shown.
struct RemoteImage: View {
    let url: URL
    let alt: String
    var maxHeight: CGFloat = 160
    @State private var state: Result<NSImage, RemoteImageLoader.Failure>?

    var body: some View {
        Group {
            switch state {
            case .success(let image):
                let size = image.size
                let height = min(maxHeight, size.height)
                AnimatedImage(image: image)
                    .frame(width: size.height > 0 ? height * size.width / size.height : height, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(alt.isEmpty ? "GIF" : alt)
            case .failure:
                Label(alt.isEmpty ? Copy.imageNotLoaded : "\(Copy.imageNotLoaded): \(alt)", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case nil:
                ProgressView().controlSize(.small).frame(width: 60, height: 40)
            }
        }
        .task(id: url) { state = await RemoteImageLoader.shared.image(at: url) }
    }
}

// MARK: - GIF sheet

/// GIFs added before, newest first, for the picker; kept in this Mac's user defaults.
enum RecentGIFs {
    private static let key = "recentGIFs"
    private static let limit = 8

    static func load() -> [(alt: String, url: String)] {
        (UserDefaults.standard.array(forKey: key) as? [[String]] ?? []).compactMap { pair in
            pair.count == 2 ? (pair[0], pair[1]) : nil
        }
    }

    static func remember(alt: String, url: String) {
        let rest = load().filter { $0.url != url }.map { [$0.alt, $0.url] }
        UserDefaults.standard.set(Array(([[alt, url]] + rest).prefix(limit)), forKey: key)
    }
}

/// Paste a GIF's link, see it play, describe it, add it; or pick one used before.
struct GIFPickerSheet: View {
    let onInsert: (_ alt: String, _ url: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var alt = ""
    @State private var preview: Result<NSImage, RemoteImageLoader.Failure>?
    @State private var loading = false
    private let recent = RecentGIFs.load()

    private var url: URL? {
        let text = TemplateTextView.encoded(link)
        guard let url = DisplayText.safeURL(text), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.gifTitle).font(.title3.weight(.semibold))
            Text(Copy.gifHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(Copy.gifURL, text: $link).textFieldStyle(.roundedBorder)
            TextField(Copy.gifAlt, text: $alt, prompt: Text(Copy.gifAltPlaceholder)).textFieldStyle(.roundedBorder)
            previewArea
                .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 170)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            if !recent.isEmpty {
                Text(Copy.gifRecent).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(recent, id: \.url) { item in
                            Button {
                                link = item.url
                                alt = item.alt
                            } label: {
                                if let url = URL(string: item.url) {
                                    RemoteImage(url: url, alt: item.alt, maxHeight: 54)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(item.alt)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(Copy.confirmCancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Copy.gifInsert) {
                    guard let url else { return }
                    let description = alt.trimmingCharacters(in: .whitespacesAndNewlines)
                    RecentGIFs.remember(alt: description, url: url.absoluteString)
                    onInsert(description, url.absoluteString)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canInsert)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(id: link) { await load() }
    }

    private var canInsert: Bool {
        if case .success = preview { return url != nil }
        return false
    }

    @ViewBuilder private var previewArea: some View {
        if link.trimmingCharacters(in: .whitespaces).isEmpty {
            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.tertiary)
        } else if url == nil {
            Text(Copy.gifNotHTTPS).foregroundStyle(.secondary).padding()
        } else if loading {
            ProgressView(Copy.gifLoading)
        } else {
            switch preview {
            case .success(let image):
                AnimatedImage(image: image).padding(6)
            case .failure(.tooLarge):
                Text(Copy.gifTooLarge).foregroundStyle(.red).padding()
            case .failure:
                Text(Copy.gifNotImage).foregroundStyle(.red).padding()
            case nil:
                EmptyView()
            }
        }
    }

    private func load() async {
        preview = nil
        guard let url else { return }
        // Wait for typing to pause before fetching.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        loading = true
        let result = await RemoteImageLoader.shared.image(at: url)
        guard !Task.isCancelled else { return }
        preview = result
        loading = false
    }
}

// MARK: - Emoji

/// Quick picks from the agent's shortcode table, the system palette, and the shortcode hint.
struct EmojiPicker: View {
    let emoji: [String: String]
    let onPick: (String) -> Void
    let onMore: () -> Void

    /// The shortcodes shown first, in this order; the rest of the table follows.
    private static let favourites = [
        "wave", "pray", "tada", "rocket", "fire", "eyes", "smile", "joy", "thinking", "+1", "clap", "raised_hands",
        "white_check_mark", "warning", "bug", "sparkles", "coffee", "watermelon",
    ]

    private var names: [String] {
        Self.favourites.filter { emoji[$0] != nil } + emoji.keys.filter { !Self.favourites.contains($0) && $0 != "thumbsup" }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                ForEach(names, id: \.self) { name in
                    Button { onPick(emoji[name] ?? "") } label: {
                        Text(emoji[name] ?? "").font(.system(size: 19)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help(":\(name):")
                }
            }
            Divider()
            Button(Copy.formatEmojiMore, action: onMore)
            Text(Copy.formatEmojiHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 290)
    }
}

// MARK: - Notification preview

/// A notification as macOS shows it in the corner: app icon, name, time, title and body.
struct NotificationBannerPreview: View {
    let title: String
    let body_: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Copy.teamsNow).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(body_).font(.system(size: 13)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.alertPreviewHeading)
    }
}
