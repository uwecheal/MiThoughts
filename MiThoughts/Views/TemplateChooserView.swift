import SwiftUI

struct TemplateChooserView: View {
    let templates: [TemplateDefinition]
    let onChoose: (TemplateID) -> Void
    let onCancel: () -> Void

    @State private var selectedTemplateID: TemplateID? = .blankMap

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New From Template")
                    .font(.headline)

                Spacer()
            }
            .padding()

            Divider()

            List(templates, selection: $selectedTemplateID) { template in
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name)
                        .font(.body.weight(.medium))

                    Text(template.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
                .tag(template.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onChoose(template.id)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onChoose(selectedTemplateID ?? .blankMap)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 440, height: 420)
    }
}
