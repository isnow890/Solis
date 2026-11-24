import Testing
@testable import halo

struct VirtualHiDPISizingTests {
    private func base(_ width: Int, _ height: Int) -> [Int] {
        let size = VirtualDisplayManager.mirrorBaseSize(width: width, height: height)
        return [size.width, size.height]
    }

    @Test func sizesInsideTheBoxAreKept() {
        #expect(base(1920, 1080) == [1920, 1080])
        #expect(base(2560, 1440) == [2560, 1440])
        #expect(base(1080, 1920) == [1080, 1920])
    }

    @Test func largerSizesShrinkToTheBoxWithEvenSides() {
        #expect(base(3840, 2160) == [2560, 1440])
        #expect(base(3440, 1440) == [2560, 1072])
        #expect(base(5120, 1440) == [2560, 720])
        #expect(base(1440, 3440) == [1072, 2560])
    }

    @Test func oddInputsAreRoundedToEvenSides() {
        #expect(base(1365, 767) == [1366, 768])
    }
}
