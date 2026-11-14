import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import KumoneCore

@Suite("Comment share card rendering")
struct CommentShareCardTests {
    /// The card's height follows its text, so it is rarely a whole number of points. The last
    /// pixel row used to be only partly covered by the background and showed as a pale line
    /// along the bottom edge of the shared picture.
    @MainActor
    @Test func everyPixelRowIsOpaqueForAnyTextLength() throws {
        let sentences = [
            "好听",
            "爱你的人给了你力量，批评你的人给了你清醒。",
            "爱你的人给了你力量，批评你的人给了你清醒，帮助你的人给了你机会，陷害你的人给了你胸怀，赞扬你的人给了你信心，抹黑打击你的人给了你坚强，但凡是岁月馈赠于你的，都有他的道理，岁月给你的沉淀，让人成长，生命中遇到的各种苦难磨难和劫难，有福之人才配经历，命运送你的，暗中都标好了他的意义。",
            "It is a song for the nights when nothing needs to be said and everyone in the room already knows.",
        ]
        for text in sentences {
            for scale in [CGFloat(2), 3] {
                let image = try render(text, scale: scale)
                let (width, height) = (image.width, image.height)
                let pixels = try rgba(image)
                for row in [height - 1, height - 2, 0] {
                    for column in stride(from: 0, to: width, by: 7) {
                        let alpha = pixels[(row * width + column) * 4 + 3]
                        #expect(alpha == 255, "row \(row)/\(height) column \(column) alpha \(alpha) at scale \(scale), text \(text.count) characters")
                    }
                }
            }
        }
    }

    @MainActor
    private func render(_ text: String, scale: CGFloat) throws -> CGImage {
        let card = CommentShareCard(
            track: try makeTrack(),
            comment: SongComment(id: 1, userID: 1, nickname: "天马的诗", content: text, likedCount: 11),
            artwork: nil,
            avatar: nil,
            colors: .fallback
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: CommentShareCard.width, height: nil)
        return try #require(renderer.cgImage)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func makeTrack() throws -> Track {
        let data = Data(
            """
            {"id": 1, "name": "借来的体温", "ar": [{"id": 2, "name": "树离suliii_"}],
             "al": {"id": 3, "name": "Album", "picUrl": null}, "dt": 180000}
            """.utf8)
        return try JSONDecoder().decode(Track.self, from: data)
    }
}
