import Testing
@testable import CameraCapture

/// Regression for the two crashes on 2026-10-13 (stack overflow on the preview queue and in
/// teardown): the handler, stored straight in the lock's tuple, gained one reabstraction thunk per
/// frame, so after minutes of preview calling or freeing it overflowed the stack.
@Suite struct PictureCheckHandlerTests {
    final class Counter: @unchecked Sendable { var calls = 0 }

    @Test func handlerSurvivesAnHourOfFrames() {
        let check = PictureCheck()
        let counter = Counter()
        check.setHandler { _ in counter.calls += 1 }
        // About an hour of preview at 23.976 fps: every frame writes the locked state.
        for _ in 0..<200_000 {
            check.report(nil, sawPicture: true, from: .preview)
            _ = check.status
        }
        // The first picture fired once; nothing since changed the overall state.
        #expect(counter.calls == 1)
        // Calling the handler after all those writes must not recurse.
        check.report(.began(.zero), sawPicture: false, from: .preview)
        #expect(counter.calls == 2)
        // Freeing it must not recurse either.
        check.setHandler(nil)
        check.report(.ended(frames: 12), sawPicture: true, from: .preview)
        #expect(counter.calls == 2)
    }
}
