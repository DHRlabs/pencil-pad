import Foundation
import UIKit

/// Projection frames: a 4-byte big-endian frame number, then JPEG bytes. They are shown in the order they arrive, one at a
/// time; the JPEG is decoded off the main thread, and every frame is acknowledged, shown or not, so the Mac never stalls.
@MainActor
final class FramePipe {
    private struct Item: Sendable {
        let n: UInt32
        let jpeg: Data
        let gen: Int
    }

    private let input: AsyncStream<Item>.Continuation

    init(session: Session) {
        let (stream, input) = AsyncStream.makeStream(of: Item.self, bufferingPolicy: .unbounded)
        self.input = input
        Task.detached(priority: .userInitiated) { [weak session] in
            for await item in stream {
                guard let session else { return }
                let hold = await session.holdBeforeDrawing()
                if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
                var image: UIImage?
                if await session.wantsFrame(item.gen) { image = await UIImage(data: item.jpeg)?.byPreparingForDisplay() }
                await session.present(image, n: item.n, gen: item.gen)
            }
        }
    }

    func push(_ data: Data, gen: Int) {
        guard data.count >= 6 else { return }
        let n = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        input.yield(Item(n: n, jpeg: Data(data.dropFirst(4)), gen: gen))
    }
}
