import SwiftUI

struct StartScreenView: View {
    let recentFiles: [URL]
    let hasLastWorkingMap: Bool
    let onContinueLastWorkingMap: () -> Void
    let onNewBlankMap: () -> Void
    let onNewFromTemplate: () -> Void
    let onOpenExistingMap: () -> Void
    let onOpenRecentFile: (URL) -> Void
    let onChooseTemplate: (TemplateID) -> Void

    private let quickTemplateIDs: [TemplateID] = [
        .blankMap,
        .weeklyPlan,
        .projectPlan,
        .meetingNotes,
        .yogaClassPlan
    ]

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            HStack(spacing: 36) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MyThoughts")
                            .font(.system(size: 34, weight: .semibold))

                        Text("Choose how you want to start.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if hasLastWorkingMap {
                            Button("Continue Last Working Map") {
                                onContinueLastWorkingMap()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }

                        Button("New Blank Map") {
                            onNewBlankMap()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button("New From Template...") {
                            onNewFromTemplate()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button("Open Existing Map...") {
                            onOpenExistingMap()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Templates")
                            .font(.headline)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(quickTemplateIDs, id: \.self) { templateID in
                                if let template = BuiltInTemplateFactory.templates.first(where: { $0.id == templateID }) {
                                    Button {
                                        onChooseTemplate(templateID)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(template.name)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)

                                            Text(template.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(10)
                                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .frame(maxWidth: 500)
                    }

                    Spacer()
                }
                .frame(minWidth: 360, maxWidth: 520, alignment: .topLeading)

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Recent Files")
                        .font(.headline)

                    if recentFiles.isEmpty {
                        Text("No recent files")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(recentFiles.prefix(10), id: \.path) { url in
                                    Button {
                                        onOpenRecentFile(url)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(url.lastPathComponent)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Text(url.deletingLastPathComponent().path)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(width: 330, alignment: .topLeading)
            }
            .padding(40)
            .frame(maxWidth: 980, maxHeight: 620)
        }
    }
}
