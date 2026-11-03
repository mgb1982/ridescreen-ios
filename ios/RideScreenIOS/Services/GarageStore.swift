import Foundation
import SwiftUI
import UIKit

/// The rider's bike: a name and a garage photo. Both stay on the iPhone (UserDefaults and Application Support).
@MainActor
final class GarageStore: ObservableObject {
    static let maximumNameLength = 28
    private static let nameKey = "ridescreen.garage.bikeName"
    private static let maximumPhotoSide: CGFloat = 1_600

    @Published var bikeName: String {
        didSet {
            UserDefaults.standard.set(String(bikeName.prefix(Self.maximumNameLength)), forKey: Self.nameKey)
        }
    }

    @Published private(set) var photo: UIImage?

    private let photoURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RideScreen", isDirectory: true)
        photoURL = base.appendingPathComponent("garage.jpg")
        bikeName = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        photo = UIImage(contentsOfFile: photoURL.path)
    }

    /// Saves a picked photo, scaled down so the file stays small. Returns false if the data is not an image.
    @discardableResult
    func setPhoto(from data: Data) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        let scaled = Self.downscaled(image)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: photoURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try jpeg.write(to: photoURL, options: .atomic)
            photo = scaled
            return true
        } catch {
            return false
        }
    }

    func removePhoto() {
        try? FileManager.default.removeItem(at: photoURL)
        photo = nil
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maximumPhotoSide else { return image }
        let factor = maximumPhotoSide / longest
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
