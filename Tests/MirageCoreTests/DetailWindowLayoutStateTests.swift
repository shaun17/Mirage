import CoreGraphics
import MirageDetailWindow
import XCTest

final class DetailWindowLayoutStateTests: XCTestCase {
    /// 右侧空间充足时只增加详情宽度，主内容的左边缘保持不动。
    func testOpeningExpandsToRightWhenScreenHasRoom() {
        var state = DetailWindowLayoutState()
        let closed = CGRect(x: 100, y: 80, width: 1_000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 2_200, height: 1_400)

        let target = state.targetFrame(
            whenPresented: true,
            currentFrame: closed,
            visibleFrame: visible
        )

        XCTAssertEqual(
            target,
            CGRect(
                x: 100,
                y: 80,
                width: 1_000 + DetailDrawerMetrics.width,
                height: 700
            )
        )
    }

    /// 右侧不足但屏幕可容纳完整窗口时，只向左补偿缺少的距离。
    func testOpeningShiftsLeftOnlyWhenRightEdgeNeedsRoom() {
        var state = DetailWindowLayoutState()
        let closed = CGRect(x: 700, y: 80, width: 1_000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 1_800, height: 1_200)

        let target = state.targetFrame(
            whenPresented: true,
            currentFrame: closed,
            visibleFrame: visible
        )

        XCTAssertEqual(
            target,
            CGRect(x: 444, y: 80, width: 1_356, height: 700)
        )
    }

    /// 屏幕本身放不下主窗口与完整抽屉时，展开结果不能越过可见区域。
    func testOpeningCapsWidthToNarrowVisibleFrame() {
        var state = DetailWindowLayoutState()
        let closed = CGRect(x: 100, y: 80, width: 1_000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 1_200, height: 900)

        let target = state.targetFrame(
            whenPresented: true,
            currentFrame: closed,
            visibleFrame: visible
        )

        XCTAssertEqual(target, CGRect(x: 0, y: 80, width: 1_200, height: 700))
    }

    /// 副屏可能使用负坐标，边界计算不能假设屏幕从零开始。
    func testOpeningUsesNegativeScreenCoordinates() {
        var state = DetailWindowLayoutState()
        let closed = CGRect(x: -1_100, y: 80, width: 1_000, height: 700)
        let visible = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_200)

        let target = state.targetFrame(
            whenPresented: true,
            currentFrame: closed,
            visibleFrame: visible
        )

        XCTAssertEqual(
            target,
            CGRect(x: -1_356, y: 80, width: 1_356, height: 700)
        )
    }

    /// 抽屉已展开时切换记录只更新内容，不应再次增加窗口宽度。
    func testRepeatedPresentationDoesNotExpandAgain() {
        var state = DetailWindowLayoutState()
        let closed = CGRect(x: 100, y: 80, width: 1_000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 2_200, height: 1_400)
        let expanded = state.targetFrame(
            whenPresented: true,
            currentFrame: closed,
            visibleFrame: visible
        )!

        let repeatedTarget = state.targetFrame(
            whenPresented: true,
            currentFrame: expanded,
            visibleFrame: visible
        )

        XCTAssertNil(repeatedTarget)
    }

    /// 用户未调整窗口时，收起详情必须精确恢复展开前的 frame。
    func testClosingRestoresOriginalFrame() {
        var state = DetailWindowLayoutState()
        let closed = CGRect(x: 100, y: 80, width: 1_000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 2_200, height: 1_400)
        let expanded = state.targetFrame(
            whenPresented: true,
            currentFrame: closed,
            visibleFrame: visible
        )!

        let restored = state.targetFrame(
            whenPresented: false,
            currentFrame: expanded,
            visibleFrame: visible
        )

        XCTAssertEqual(restored, closed)
    }

    /// 打开期间的移动和缩放属于用户意图，收起时应保留相对增量。
    func testClosingPreservesUserMoveAndResizeDelta() {
        var state = DetailWindowLayoutState()
        let closed = CGRect(x: 100, y: 80, width: 1_000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 2_400, height: 1_400)
        let expanded = state.targetFrame(
            whenPresented: true,
            currentFrame: closed,
            visibleFrame: visible
        )!
        let adjusted = CGRect(
            x: expanded.minX + 60,
            y: expanded.minY + 20,
            width: expanded.width + 100,
            height: expanded.height + 40
        )

        let restored = state.targetFrame(
            whenPresented: false,
            currentFrame: adjusted,
            visibleFrame: visible
        )

        XCTAssertEqual(restored, CGRect(x: 160, y: 100, width: 1_100, height: 740))
    }

    /// 极端缩放或移动后恢复，仍需满足主窗口最小宽度并留在当前屏幕内。
    func testClosingClampsToMinimumWidthAndVisibleFrame() {
        var state = DetailWindowLayoutState()
        let closed = CGRect(x: 100, y: 80, width: 920, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 1_600, height: 1_200)
        _ = state.targetFrame(
            whenPresented: true,
            currentFrame: closed,
            visibleFrame: visible
        )

        let restored = state.targetFrame(
            whenPresented: false,
            currentFrame: CGRect(x: 1_000, y: 80, width: 800, height: 700),
            visibleFrame: visible
        )

        XCTAssertEqual(
            restored,
            CGRect(
                x: 680,
                y: 80,
                width: DetailDrawerMetrics.minimumClosedWindowWidth,
                height: 700
            )
        )
    }
}
