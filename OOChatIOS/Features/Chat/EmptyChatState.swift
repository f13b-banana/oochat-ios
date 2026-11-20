import ConnectOnionKit
import SwiftUI

struct EmptyChatState: View {
    let agentName: String
    /// The agent's own skills, already in starter order. Empty while the profile loads or when it has none.
    let skills: [OIPAgentSkill]
    let showsSkills: Bool
    let onSelectSkill: (OIPAgentSkill) -> Void
    let onShowAllSkills: () -> Void

    /// Chips on screen. With more skills than this, the last place opens the full list instead.
    static let starterSlots = 4

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasSkills: Bool {
        showsSkills && !skills.isEmpty
    }

    private var starterSkills: [OIPAgentSkill] {
        skills.count > Self.starterSlots
            ? Array(skills.prefix(Self.starterSlots - 1))
            : skills
    }

    var body: some View {
        VStack(spacing: EmptyChatMetrics.sectionSpacing) {
            VStack(spacing: EmptyChatMetrics.headingSpacing) {
                brandMark

                Text(agentName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(EmptyChatPalette.heading)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: EmptyChatMetrics.headingMaximumWidth)
                    .accessibilityAddTraits(.isHeader)

                Text(hasSkills ? "Pick a skill or type a message." : "Type a message to start.")
                    .font(.subheadline)
                    .foregroundStyle(OOColor.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: EmptyChatMetrics.headingMaximumWidth)
            }

            if hasSkills {
                LazyVGrid(columns: suggestionColumns, spacing: EmptyChatMetrics.chipSpacing) {
                    ForEach(starterSkills, id: \.name) { skill in
                        Button {
                            onSelectSkill(skill)
                        } label: {
                            chip("/\(skill.name)", leadingSymbol: "command")
                        }
                        .buttonStyle(EmptyChatSuggestionButtonStyle())
                        .accessibilityHint(skillHint(skill))
                    }

                    if skills.count > starterSkills.count {
                        Button(action: onShowAllSkills) {
                            chip("All \(skills.count) skills", trailingSymbol: "chevron.right")
                        }
                        .buttonStyle(EmptyChatSuggestionButtonStyle())
                        .accessibilityHint("Shows every skill this agent has")
                    }
                }
                .frame(maxWidth: EmptyChatMetrics.suggestionGroupMaximumWidth)
                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
            }
        }
        .animation(AppMotion.stateChange(reduceMotion: reduceMotion), value: hasSkills)
        .padding(.top, EmptyChatMetrics.topOffset)
        .padding(.vertical, EmptyChatMetrics.verticalPadding)
        .accessibilityElement(children: .contain)
    }

    private func skillHint(_ skill: OIPAgentSkill) -> String {
        let action = "Adds /\(skill.name) to the message field"
        guard let description = skill.description, !description.isEmpty else {
            return action
        }
        return "\(description). \(action)"
    }

    // A still mark: the logo over one soft backlight, with no pulse and no aura layers.
    private var brandMark: some View {
        ZStack {
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
                        EmptyChatMetrics.logoShadowOpacity(for: colorScheme)
                    ),
                    radius: EmptyChatMetrics.logoShadowRadius,
                    y: EmptyChatMetrics.logoShadowOffset
                )
        }
        .frame(
            width: EmptyChatMetrics.logoStageSize,
            height: EmptyChatMetrics.logoStageSize
        )
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

    private func chip(
        _ title: String,
        leadingSymbol: String? = nil,
        trailingSymbol: String? = nil
    ) -> some View {
        let chipShape = RoundedRectangle(
            cornerRadius: EmptyChatMetrics.chipCornerRadius,
            style: .continuous
        )

        return HStack(spacing: EmptyChatMetrics.chipContentSpacing) {
            if let leadingSymbol {
                chipSymbol(leadingSymbol)
            }

            Text(title)
                .font(.subheadline.weight(.regular))
                .foregroundStyle(EmptyChatPalette.chipText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if let trailingSymbol {
                chipSymbol(trailingSymbol)
            }
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

    private func chipSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(EmptyChatPalette.chipIcon)
            .frame(
                width: EmptyChatMetrics.chipIconSize,
                height: EmptyChatMetrics.chipIconSize
            )
            .accessibilityHidden(true)
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
