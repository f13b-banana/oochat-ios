import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The green onion from oo-chat's public/onion-green.png. The app icons keep the
/// original onion.
public enum OOLogo {
    static var url: URL? {
        Bundle.module.url(forResource: "onion-green", withExtension: "png")
    }

    public static var image: Image {
        #if canImport(UIKit)
        let platformImage = url.flatMap { UIImage(contentsOfFile: $0.path) }
        return platformImage.map { Image(uiImage: $0) } ?? Image(systemName: "circle.fill")
        #elseif canImport(AppKit)
        let platformImage = url.flatMap { NSImage(contentsOf: $0) }
        return platformImage.map { Image(nsImage: $0) } ?? Image(systemName: "circle.fill")
        #endif
    }
}
