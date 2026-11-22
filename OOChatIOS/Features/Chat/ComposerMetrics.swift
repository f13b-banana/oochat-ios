// swiftlint:disable:next unused_import
import CoreGraphics

enum ComposerMetrics {
    static let outerHorizontalPadding: CGFloat = 12
    static let outerBottomPadding: CGFloat = 6
    // The buttons sit in 44 pt frames, bigger than their glyphs. These paddings and the spacing
    // are smaller by the difference, so the glyphs land where they did with 32 and 40 pt frames.
    static let horizontalPadding: CGFloat = 10
    static let trailingPadding: CGFloat = 5
    static let verticalPadding: CGFloat = 5
    static let cornerRadius: CGFloat = 27
    static let stackSpacing: CGFloat = 9
    static let inputSpacing: CGFloat = 4
    static let inputVerticalPadding: CGFloat = 2
    static let inputStrokeOpacity: Double = 0.10
    static let focusedInputStrokeOpacity: Double = 0.32
    static let focusedInputShadowOpacity: Double = 0.08
    static let focusedInputShadowRadius: CGFloat = 10
    static let focusedInputShadowYOffset: CGFloat = 2
    static let modeLeadingPadding: CGFloat = 8
    static let modeHorizontalPadding: CGFloat = 10
    static let modeVerticalPadding: CGFloat = 5
    /// What the mode capsule's 44 pt frame adds under it, taken back so the input keeps its gap.
    static let modeTargetBottomInset: CGFloat = 8
    static let modeStrokeOpacity: Double = 0.08
    static let modePopoverWidth: CGFloat = 340
    static let sendButtonSize: CGFloat = 40
    static let voiceInputButtonSize: CGFloat = 32
    static let voiceInputActiveBackgroundOpacity: Double = 0.10
    static let attachmentButtonSize: CGFloat = 32
    static let attachmentPreviewSize: CGFloat = 72
    static let attachmentCornerRadius: CGFloat = 14
    static let attachmentSpacing: CGFloat = 8
    static let filePreviewWidth: CGFloat = 190
    static let filePreviewHeight: CGFloat = 62
    static let skillPickerMaxHeight: CGFloat = 260
    static let skillPickerCornerRadius: CGFloat = 24
    static let skillPickerGlassTintOpacity: Double = 0.78
    static let skillPickerHighlightOpacity: Double = 0.70
    static let skillPickerStrokeOpacity: Double = 0.22
    static let skillPickerShadowOpacity: Double = 0.13
    static let skillPickerShadowRadius: CGFloat = 30
    static let skillPickerShadowYOffset: CGFloat = 10
    static let skillRowSpacing: CGFloat = 12
    static let skillRowEstimatedHeight: CGFloat = 82
    static let skillRowHorizontalPadding: CGFloat = 14
    static let skillRowVerticalPadding: CGFloat = 12
    static let skillIconSize: CGFloat = 34
    static let skillIconCornerRadius: CGFloat = 9
    static let skillIconBackgroundOpacity: Double = 0.08
    static let skillTextTopPadding: CGFloat = 1
    static let skillDividerInset: CGFloat = 60
}
