import CoreGraphics

/// 详情抽屉与主窗口共享的唯一尺寸定义，避免内容宽度和窗口扩展量彼此漂移。
public enum DetailDrawerMetrics {
    public static let width: CGFloat = 356
    public static let minimumClosedWindowWidth: CGFloat = 920
}
