import ConnectOnionKit
import SwiftUI

struct EmptyChatState: View {
    let agentName: String
    let showsSuggestions: Bool
    let onSelectSuggestion: (ChatStarterSuggestion) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var logoPulse = false

    var body: some View {
        VStack(spacing: EmptyChatMetrics.sectionSpacing) {
            VStack(spacing: EmptyChatMetrics.headingSpacing) {
                brandMark

                Text("What can we work on")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(EmptyChatPalette.heading)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: EmptyChatMetrics.headingMaximumWidth)
            }

            if showsSuggestions {
                LazyVGrid(columns: suggestionColumns, spacing: EmptyChatMetrics.chipSpacing) {
                    ForEach(ChatStarterSuggestion.defaults) { suggestion in
                        suggestionButton(for: suggestion)
                    }
                }
                .frame(maxWidth: EmptyChatMetrics.suggestionGroupMaximumWidth)
            }
        }
        .padding(.top, EmptyChatMetrics.topOffset)
        .padding(.vertical, EmptyChatMetrics.verticalPadding)
        .accessibilityLabel("Start with \(agentName)")
        .accessibilityElement(children: .contain)
    }

    private var brandMark: some View {
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppTheme.primary.opacity(
                                EmptyChatMetrics.logoOuterAuraCoreOpacity(for: colorScheme)
                            ),
                            AppTheme.primary.opacity(
                                EmptyChatMetrics.logoOuterAuraEdgeOpacity(for: colorScheme)
                            ),
                            AppTheme.primary.opacity(0)
                        ],
                        center: .center,
                        startRadius: EmptyChatMetrics.logoOuterAuraStartRadius,
                        endRadius: EmptyChatMetrics.logoOuterAuraEndRadius
                    )
                )
                .frame(
                    width: EmptyChatMetrics.logoOuterAuraSize,
                    height: EmptyChatMetrics.logoOuterAuraSize
                )
                .blur(radius: EmptyChatMetrics.logoOuterAuraBlur)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppTheme.primary.opacity(
                                EmptyChatMetrics.logoAuraCoreOpacity(for: colorScheme)
                            ),
                            AppTheme.primary.opacity(
                                EmptyChatMetrics.logoAuraEdgeOpacity(for: colorScheme)
                            ),
                            AppTheme.primary.opacity(0)
                        ],
                        center: .center,
                        startRadius: EmptyChatMetrics.logoAuraStartRadius,
                        endRadius: EmptyChatMetrics.logoAuraEndRadius
                    )
                )
                .frame(
                    width: EmptyChatMetrics.logoAuraSize,
                    height: EmptyChatMetrics.logoAuraSize
                )
                .blur(radius: EmptyChatMetrics.logoAuraBlur)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            EmptyChatPalette.logoBacklightCore,
                            EmptyChatPalette.logoBacklightEdge,
                            EmptyChatPalette.logoBacklightEdge.opacity(0)
                        ],
                        center: .center,
                        startRadius: EmptyChatMetrics.logoBacklightStartRadius,
                        endRadius: EmptyChatMetrics.logoBacklightEndRadius
                    )
                )
                .frame(
                    width: EmptyChatMetrics.logoBacklightSize,
                    height: EmptyChatMetrics.logoBacklightSize
                )
                .blur(radius: EmptyChatMetrics.logoBacklightBlur)

            OOLogo.image
                .resizable()
                .scaledToFit()
                .frame(
                    width: EmptyChatMetrics.logoSize,
                    height: EmptyChatMetrics.logoSize
                )
                .opacity(EmptyChatMetrics.logoImageOpacity(for: colorScheme))
                .offset(y: EmptyChatMetrics.logoImageVerticalOffset)
                .shadow(
                    color: EmptyChatPalette.logoShadow.opacity(
                        EmptyChatMetrics.logoShadowOpacity(
                            isActive: logoPulse,
                            colorScheme: colorScheme
                        )
                    ),
                    radius: logoPulse ? EmptyChatMetrics.logoActiveShadowRadius : EmptyChatMetrics.logoIdleShadowRadius,
                    y: logoPulse ? EmptyChatMetrics.logoActiveShadowOffset : EmptyChatMetrics.logoIdleShadowOffset
                )
        }
        .frame(
            width: EmptyChatMetrics.logoStageSize,
            height: EmptyChatMetrics.logoStageSize
        )
        .scaleEffect(logoPulse && !reduceMotion ? 1.015 : 1)
        // Pulse must start via withAnimation, not a subtree-level .animation(value:):
        // a repeat-forever subtree animation also captures coincident layout moves,
        // leaving the logo oscillating sideways (seen on regular-width first runs).
        .onAppear {
            guard !reduceMotion else {
                return
            }
            withAnimation(
                .easeInOut(duration: EmptyChatMetrics.logoPulseDuration)
                    .repeatForever(autoreverses: true)
            ) {
                logoPulse = true
            }
        }
        .accessibilityHidden(true)
    }

    private var suggestionColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }

        return [
            GridItem(.flexible(), spacing: EmptyChatMetrics.chipSpacing),
            GridItem(.flexible())
        ]
    }

    private func suggestionButton(for suggestion: ChatStarterSuggestion) -> some View {
        Button {
            onSelectSuggestion(suggestion)
        } label: {
            suggestionChip(suggestion)
        }
        .buttonStyle(EmptyChatSuggestionButtonStyle())
        .accessibilityHint("\(suggestion.detail). Adds this starter to the message field")
    }

    private func suggestionChip(_ suggestion: ChatStarterSuggestion) -> some View {
        let chipShape = RoundedRectangle(
            cornerRadius: EmptyChatMetrics.chipCornerRadius,
            style: .continuous
        )

        return HStack(spacing: EmptyChatMetrics.chipContentSpacing) {
            Image(systemName: suggestion.systemImage)
                .font(.footnote.weight(.regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(EmptyChatPalette.chipIcon)
                .frame(
                    width: EmptyChatMetrics.chipIconSize,
                    height: EmptyChatMetrics.chipIconSize
                )

            Text(suggestion.title)
                .font(.subheadline.weight(.regular))
                .foregroundStyle(EmptyChatPalette.chipText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, EmptyChatMetrics.chipHorizontalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: EmptyChatMetrics.chipMinimumHeight,
            alignment: .leading
        )
        .background(
            EmptyChatPalette.chipFill,
            in: chipShape
        )
        .overlay {
            chipShape
                .stroke(
                    EmptyChatPalette.chipStroke,
                    lineWidth: 0.5
                )
        }
        .shadow(
            color: EmptyChatPalette.chipShadow,
            radius: EmptyChatMetrics.chipShadowRadius,
            y: EmptyChatMetrics.chipShadowOffset
        )
        .contentShape(chipShape)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyChatSuggestionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let chipShape = RoundedRectangle(
            cornerRadius: EmptyChatMetrics.chipCornerRadius,
            style: .continuous
        )

        configuration.label
            .overlay {
                chipShape
                    .fill(EmptyChatPalette.chipPressedFill)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                chipShape
                    .stroke(
                        EmptyChatPalette.chipPressedStroke,
                        lineWidth: configuration.isPressed ? 1 : 0
                    )
                    .opacity(configuration.isPressed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .animation(AppMotion.press, value: configuration.isPressed)
            .animation(AppMotion.press, value: isEnabled)
    }
}

struct ChatStarterSuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let prompt: String

    static let defaults = [
        ChatStarterSuggestion(
            id: "plan-feature",
            title: "Plan a feature",
            detail: "Shape an idea into clear next steps",
            systemImage: "checklist",
            prompt: "Help me plan a feature. Ask for the goal and constraints, then give me a focused implementation plan."
        ),
        ChatStarterSuggestion(
            id: "review-code",
            title: "Review code",
            detail: "Find concrete issues and improvements",
            systemImage: "doc.text.magnifyingglass",
            prompt: "Review the relevant code for correctness, clarity, and maintainability. Prioritize concrete issues."
        ),
        ChatStarterSuggestion(
            id: "debug-problem",
            title: "Debug issue",
            detail: "Trace the cause and smallest fix",
            systemImage: "wrench.adjustable",
            prompt: "Help me debug a problem. Start by asking for the symptoms and expected behavior."
        ),
        ChatStarterSuggestion(
            id: "explain-project",
            title: "Explain project",
            detail: "Map the architecture and data flow",
            systemImage: "square.stack.3d.up",
            prompt: "Explain this project's architecture and trace the main data flow in plain language."
        )
    ]
}
