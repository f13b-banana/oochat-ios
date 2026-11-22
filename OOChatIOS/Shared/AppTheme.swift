import ConnectOnionKit
import SwiftUI

// Liquid Glass surface to match the system tab bar; falls back to a solid
// fill on OS versions before the glass effect is available or when Reduce
// Transparency is enabled. Pass a `tint` for prominent controls.
extension View {
    func glassBackground<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        tint: Color? = nil,
        fallback: Color? = nil
    ) -> some View {
        modifier(
            GlassBackgroundModifier(
                shape: shape,
                interactive: interactive,
                tint: tint,
                fallback: fallback
            )
        )
    }
}

private struct GlassBackgroundModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let shape: S
    let interactive: Bool
    let tint: Color?
    let fallback: Color?

    // The glass path needs the iOS 26 SDK to compile, not just to run: `#available`
    // guards the run time, but `Glass` and `glassEffect` must exist in the SDK being
    // built against. Compiling the branch out on older toolchains keeps this file
    // buildable on Xcode 15 while Xcode 26 still gets the real glass treatment.
    // The non-glass path is not a stub — it is the same fallback iOS 17/18 and
    // reduce-transparency users get on any toolchain.
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(glassStyle(interactive: interactive, tint: tint), in: shape)
        } else {
            content.background(
                fallback ?? tint ?? OOColor.paper,
                in: shape
            )
        }
        #else
        content.background(
            fallback ?? tint ?? OOColor.paper,
            in: shape
        )
        #endif
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func glassStyle(interactive: Bool, tint: Color?) -> Glass {
    var glass: Glass = .regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}
#endif

enum AppTheme {
    /// O Chat v12's one green: the primary action's fill, focus rings and the
    /// logo. Values live in ConnectOnionKit's OOColor
    static let primary = OOColor.primary

    /// O chat's user msg sits on neutral-100
    static let outgoingMessageBackground = OOColor.hover

    static let destructive = OOColor.failureText
}

// A small, shared motion vocabulary keeps the chat workflow cohesive. Springs
// are reserved for interruptible, spatial changes; frequent press feedback is
// deliberately short and restrained.
enum AppMotion {
    static let press = Animation.easeOut(duration: 0.12)

    static let statusChange = Animation.easeOut(duration: 0.14)

    static func statusTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
    }

    static func drawer(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .spring(response: 0.30, dampingFraction: 1.0)
    }

    static func drawerGesture(reduceMotion: Bool, initialVelocity: Double) -> Animation? {
        reduceMotion
            ? nil
            : .interpolatingSpring(
                mass: 1,
                stiffness: 385,
                damping: 33,
                initialVelocity: initialVelocity
            )
    }

    static func stateChange(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .spring(response: 0.30, dampingFraction: 0.96)
    }

    static func contentArrival(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.32, dampingFraction: 0.94)
    }

    static func materialize(reduceMotion: Bool, edge: Edge = .bottom) -> AnyTransition {
        guard !reduceMotion else {
            return .opacity
        }

        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.985, anchor: edge == .top ? .top : .bottom))
                .combined(with: .offset(x: 0, y: edge == .top ? -6 : 6)),
            removal: .opacity
        )
    }

    /// A panel sliding in from a side, such as the iPad agent pane. A fade with Reduce Motion.
    static func slide(reduceMotion: Bool, edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    static func disclosure(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .opacity
        }

        return .opacity
            .combined(with: .scale(scale: 0.99, anchor: .top))
            .combined(with: .offset(x: 0, y: -6))
    }
}

struct AppPressButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var pressedScale: CGFloat = 0.97
    var pressedOpacity: Double = 0.82

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(isEnabled ? (configuration.isPressed ? pressedOpacity : 1) : 0.38)
            .animation(AppMotion.press, value: configuration.isPressed)
            .animation(AppMotion.press, value: isEnabled)
    }
}
