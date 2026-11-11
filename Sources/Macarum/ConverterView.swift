import AppKit
import MacarumCore
import SwiftUI

/// The "Convert" section at the top of the menu bar panel: a drop zone that turns into the
/// outputs that fit the dropped files, then into the result.
struct ConverterView: View {
    let model: ConverterModel
    @Bindable var preferences: Preferences

    var body: some View {
        Group {
            switch model.phase {
            case .idle: dropZone
            case .picked: picked
            case .working(let done, let total): working(done: done, total: total)
            case .finished(let outcome): finished(outcome)
            case .message(let text): message(text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Idle

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.document")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.isDropTargeted ? Color.accentColor : .secondary)
            Text(model.isDropTargeted ? "Drop to convert" : "Drop files to convert")
                .font(.system(size: 12.5))
                .foregroundStyle(model.isDropTargeted ? Color.accentColor : .primary)
            Spacer(minLength: 6)
            Button("Choose…", action: model.chooseFiles)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.isDropTargeted ? Color.accentColor.opacity(0.10) : .clear)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(model.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.22),
                              style: StrokeStyle(lineWidth: 1, dash: model.isDropTargeted ? [] : [4, 3]))
        }
        .contentShape(Rectangle())
    }

    // MARK: Picked

    private var picked: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(title: model.selection?.title ?? "", icon: model.thumbnail)
            ForEach(model.rows, id: \.group) { row in
                OptionRow(label: row.group.title) {
                    ForEach(row.offers) { offer in
                        ChoiceButton(title: offer.title, isOn: model.chosen == offer) { model.choose(offer) }
                    }
                }
            }
            if model.showsLoadingHint {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading the file…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let note = model.chosenNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.usesSVGScale {
                OptionRow(label: "Size") {
                    Picker("Size", selection: $preferences.svgScale) {
                        ForEach(SVGScale.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if model.usesQuality {
                OptionRow(label: "JPG quality") {
                    Picker("JPG quality", selection: $preferences.converterQuality) {
                        ForEach(JPEGQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if let note = model.skippedNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Convert", action: model.runChosen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chosen == nil)
            }
        }
    }

    // MARK: Working

    private func working(done: Double, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workingTitle(done: done, total: total))
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: model.cancel)
                    .controlSize(.small)
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .frame(minHeight: 44)
    }

    /// "Converting 2 of 3…", or "Converting… 42%" for one video or sound file.
    private func workingTitle(done: Double, total: Int) -> String {
        if total > 1 { return "Converting \(min(Int(done) + 1, total)) of \(total)…" }
        guard model.runningOffer?.reportsPartialProgress == true, done > 0 else { return "Converting…" }
        return "Converting… \(min(99, Int(done * 100)))%"
    }

    // MARK: Finished

    private func finished(_ outcome: ConversionOutcome) -> some View {
        let ok = !outcome.saved.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? (outcome.failures.isEmpty ? Color.green : Color.orange) : Color.orange)
                    .font(.system(size: 13))
                Text(model.summary(of: outcome))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                clearButton
            }
            if let line = model.failureLine(of: outcome) {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ok {
                HStack(spacing: 6) {
                    Button("Show in Finder", action: model.showInFinder)
                    Button(model.copied ? "Copied" : "Copy", action: model.copy)
                        .disabled(model.copied)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Message

    private func message(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            clearButton
        }
        .frame(minHeight: 44)
    }

    // MARK: Pieces

    private func header(title: String, icon: NSImage?) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: model.thumbnailIsPhoto ? .fill : .fit)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: model.thumbnailIsPhoto ? 4 : 0, style: .continuous))
            }
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            clearButton
        }
    }

    private var clearButton: some View {
        Button(action: model.clear) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Clear")
    }
}

/// One output choice: plain until picked, filled with the accent colour once picked.
private struct ChoiceButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.09)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// "Convert to   [JPG] [PNG] [PDF]": a label column, then the choices, wrapping when needed.
private struct OptionRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 66, height: 20, alignment: .leading)
            FlowLayout(spacing: 6) { content }
        }
    }
}

/// Lays children out left to right and starts a new line when the next one does not fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
