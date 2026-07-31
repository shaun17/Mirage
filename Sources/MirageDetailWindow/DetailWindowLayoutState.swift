import CoreGraphics

/// 纯窗口布局状态机，只计算详情打开和关闭时应提交的目标 frame。
public struct DetailWindowLayoutState {
    private struct Expansion {
        let closedFrame: CGRect
        let expandedFrame: CGRect
    }

    private var expansion: Expansion?

    public init() {}

    /// 返回需要提交的新 frame；可见性没有跨越打开/关闭边界时返回 nil。
    public mutating func targetFrame(
        whenPresented isPresented: Bool,
        currentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect? {
        if isPresented {
            return targetFrameForPresentation(
                currentFrame: currentFrame,
                visibleFrame: visibleFrame
            )
        }
        return targetFrameForDismissal(
            currentFrame: currentFrame,
            visibleFrame: visibleFrame
        )
    }

    /// 首次打开优先固定左边缘向右扩展，右侧不足时才向左补偿。
    private mutating func targetFrameForPresentation(
        currentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect? {
        guard expansion == nil else { return nil }
        let targetWidth = min(
            currentFrame.width + DetailDrawerMetrics.width,
            visibleFrame.width
        )
        guard targetWidth > currentFrame.width else {
            expansion = Expansion(closedFrame: currentFrame, expandedFrame: currentFrame)
            return nil
        }

        let target = CGRect(
            x: clampedOriginX(
                currentFrame.minX,
                width: targetWidth,
                visibleFrame: visibleFrame
            ),
            y: currentFrame.minY,
            width: targetWidth,
            height: currentFrame.height
        )
        expansion = Expansion(closedFrame: currentFrame, expandedFrame: target)
        return target
    }

    /// 收起时只反转程序造成的变化，并保留用户在展开期间做出的移动和缩放。
    private mutating func targetFrameForDismissal(
        currentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect? {
        guard let expansion else { return nil }
        self.expansion = nil

        let minimumWidth = min(
            DetailDrawerMetrics.minimumClosedWindowWidth,
            visibleFrame.width
        )
        let proposedWidth = expansion.closedFrame.width
            + currentFrame.width
            - expansion.expandedFrame.width
        let targetWidth = min(max(proposedWidth, minimumWidth), visibleFrame.width)
        let proposedOriginX = expansion.closedFrame.minX
            + currentFrame.minX
            - expansion.expandedFrame.minX
        let targetOriginY = expansion.closedFrame.minY
            + currentFrame.minY
            - expansion.expandedFrame.minY
        let targetHeight = expansion.closedFrame.height
            + currentFrame.height
            - expansion.expandedFrame.height

        return CGRect(
            x: clampedOriginX(
                proposedOriginX,
                width: targetWidth,
                visibleFrame: visibleFrame
            ),
            y: targetOriginY,
            width: targetWidth,
            height: targetHeight
        )
    }

    /// 水平约束使用屏幕真实坐标，兼容原点为负数的副显示器。
    private func clampedOriginX(
        _ proposedOriginX: CGFloat,
        width: CGFloat,
        visibleFrame: CGRect
    ) -> CGFloat {
        min(
            max(proposedOriginX, visibleFrame.minX),
            visibleFrame.maxX - width
        )
    }
}
