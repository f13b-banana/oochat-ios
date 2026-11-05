import SwiftUI
import ConnectOnionKit

struct AskUserCard: View {
    let pending: PendingAskUser
    var onSubmit: (String) -> Void

    @State private var selectedOptions: Set<String> = []
    @State private var freeText = ""
    @State private var fieldValues: [String: String]

    init(pending: PendingAskUser, onSubmit: @escaping (String) -> Void) {
        self.pending = pending
        self.onSubmit = onSubmit
        _fieldValues = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: pending.request.fields.map { ($0.name, "") }
            )
        )
    }

    private var request: AskUserRequest {
        pending.request
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Agent needs your input", systemImage: "questionmark.bubble.fill")
                .font(.headline)
                .foregroundStyle(AppTheme.primary)

            Text(request.question)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            responseControls
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    @ViewBuilder
    private var responseControls: some View {
        if !request.fields.isEmpty {
            fieldForm
        } else if request.options.isEmpty {
            freeTextForm
        } else if request.multiSelect {
            multiSelectForm
        } else {
            singleSelectForm
        }
    }

    private var singleSelectForm: some View {
        VStack(spacing: 8) {
            ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                Button {
                    onSubmit(option)
                } label: {
                    Text(option)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(
                            Color(.tertiarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(AppPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.86))
                .accessibilityIdentifier("askUser.option.\(request.id).\(index)")
            }
        }
    }

    private var multiSelectForm: some View {
        VStack(spacing: 10) {
            ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                Button {
                    if selectedOptions.contains(option) {
                        selectedOptions.remove(option)
                    } else {
                        selectedOptions.insert(option)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedOptions.contains(option) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedOptions.contains(option) ? AppTheme.primary : .secondary)
                        Text(option)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color(.tertiarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(AppPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.86))
                .accessibilityIdentifier("askUser.multiOption.\(request.id).\(index)")
            }

            submitButton(answer: orderedSelections.joined(separator: ", "))
                .disabled(selectedOptions.isEmpty)
        }
    }

    private var freeTextForm: some View {
        VStack(spacing: 10) {
            TextField("Type your answer", text: $freeText, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("askUser.freeText.\(request.id)")

            submitButton(answer: freeText.trimmingCharacters(in: .whitespacesAndNewlines))
                .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var fieldForm: some View {
        VStack(spacing: 10) {
            ForEach(request.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if field.isSecure {
                        SecureField(
                            field.placeholder ?? field.label,
                            text: binding(for: field.name)
                        )
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .privacySensitive()
                    } else {
                        TextField(
                            field.placeholder ?? field.label,
                            text: binding(for: field.name)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .accessibilityIdentifier("askUser.field.\(request.id).\(field.name)")
            }

            submitButton(answer: structuredAnswer)
                .disabled(!allFieldsHaveValues)
        }
    }

    private func submitButton(answer: String) -> some View {
        Button {
            onSubmit(answer)
        } label: {
            Text("Submit")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    AppTheme.primary,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.98, pressedOpacity: 0.88))
        .accessibilityIdentifier("askUser.submit.\(request.id)")
    }

    private func binding(for fieldName: String) -> Binding<String> {
        Binding(
            get: { fieldValues[fieldName] ?? "" },
            set: { fieldValues[fieldName] = $0 }
        )
    }

    private var orderedSelections: [String] {
        request.options.filter(selectedOptions.contains)
    }

    private var allFieldsHaveValues: Bool {
        request.fields.allSatisfy {
            !(fieldValues[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var structuredAnswer: String {
        let values = Dictionary(
            uniqueKeysWithValues: request.fields.map { field in
                (field.name, JSONValue.string(fieldValues[field.name] ?? ""))
            }
        )
        return CanonicalJSON.string(from: .object(values))
    }
}
