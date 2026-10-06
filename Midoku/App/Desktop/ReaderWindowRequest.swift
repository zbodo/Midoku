import AidokuRunner
import Foundation

/// Content identity for opening and restoring a reader. Source instances are resolved by the source manager.
struct ReaderWindowRequest: Codable {
    private let sourceKey: String
    let manga: AidokuRunner.Manga
    let chapter: AidokuRunner.Chapter
    var startPage: Int?

    static let activityType = "app.midoku.reader"
    static let compatibleActivityTypes = [activityType, "app.aidoku.reader"]

    var activity: NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = manga.title
        if let data = try? JSONEncoder().encode(self) {
            activity.userInfo = ["reader": data]
        }
        return activity
    }

    init(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter, startPage: Int? = nil) {
        self.sourceKey = manga.sourceKey
        self.manga = manga
        self.chapter = chapter
        self.startPage = startPage
    }

    private enum CodingKeys: String, CodingKey { case sourceKey, manga, chapter, startPage }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceKey = try values.decode(String.self, forKey: .sourceKey)
        let decoded = try values.decode(AidokuRunner.Manga.self, forKey: .manga)
        // AidokuRunner intentionally excludes sourceKey from Manga's JSON representation.
        manga = AidokuRunner.Manga(sourceKey: sourceKey, key: decoded.key, title: decoded.title).copy(from: decoded)
        chapter = try values.decode(AidokuRunner.Chapter.self, forKey: .chapter)
        startPage = try values.decodeIfPresent(Int.self, forKey: .startPage)
    }

    init?(activity: NSUserActivity?) {
        guard let activity, Self.compatibleActivityTypes.contains(activity.activityType),
              let data = activity.userInfo?["reader"] as? Data,
              let request = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = request
    }
}
