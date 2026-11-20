import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A real Provider screenshot in a bounded 16:9 frame, fitted whole inside it. It is evidence, not an action:
/// it is never a button, and its description is the host's approved alt text. Nothing is drawn when the bytes
/// do not decode as an image.
struct OOWorkRoomPreview: View {
    let screenshot: OIPProviderArtifact.Screenshot
    @State private var image: Image?

    var body: some View {
        content.task(id: screenshot) { image = Self.image(screenshot.imageData) }
    }

    @ViewBuilder private var content: some View {
        if let image {
            let shape = RoundedRectangle(cornerRadius: OORadius.medium, style: .continuous)
            OOColor.surface
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { image.resizable().scaledToFit() }
                .clipShape(shape)
                .overlay(shape.stroke(OOColor.hairline, lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(screenshot.alt)
                .accessibilityAddTraits(.isImage)
        }
    }

    private static func image(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #elseif canImport(AppKit)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        nil
        #endif
    }
}
