import SwiftUI
import UIKit
import CryptoKit

/// Image loading with the device token, a bounded memory cache and an
/// on-disk cache in Caches (cleared by iOS under pressure). Screenshot
/// galleries request server-side thumbnails; full size only on demand.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { memory.countLimit = 300; memory.totalCostLimit = 200 * 1024 * 1024 }

    func image(client: GatewayClient, path: String, query: [String: String?]) async -> UIImage? {
        let key = client.url(path, query).absoluteString
        if let m = memory.object(forKey: key as NSString) { return m }
        if let t = inflight[key] { return await t.value }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = dir.appendingPathComponent(String(digest.prefix(32)) + ".img")
        let t = Task<UIImage?, Never> {
            if let d = try? Data(contentsOf: file), let img = UIImage(data: d) { return img }
            guard let d = try? await client.data(path, query), let img = UIImage(data: d) else { return nil }
            try? d.write(to: file, options: .completeFileProtection)
            return img
        }
        inflight[key] = t
        let img = await t.value
        inflight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString, cost: Int(img.size.width * img.size.height * img.scale * 4)) }
        return img
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

struct AuthImage: View {
    @Environment(AppModel.self) private var app
    let path: String
    var query: [String: String?] = [:]
    var contentMode: ContentMode = .fit
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(Theme.textFaint)
            } else {
                Rectangle().fill(Theme.raised).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: path + query.description) {
            image = await ImageCache.shared.image(client: app.client, path: path, query: query)
            failed = image == nil
        }
    }
}
