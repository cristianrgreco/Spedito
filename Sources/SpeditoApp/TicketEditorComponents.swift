import SpeditoCore
import SwiftUI

struct TicketDetailPresentation: Identifiable, Equatable {
  enum Mode: Equatable {
    case editable
    case delivery
  }

  let item: WorkItem
  let startRefinementOnAppear: Bool
  let mode: Mode

  var id: UUID { item.id }

  static func newlyCreated(_ item: WorkItem) -> Self {
    Self(item: item, startRefinementOnAppear: true, mode: .editable)
  }

  static func existing(_ item: WorkItem, activeSprint: SprintPlan?) -> Self {
    let isActiveSprintTicket =
      activeSprint?.sprint.state.isInProgress == true
      && activeSprint?.items.contains { $0.workItemID == item.id } == true
    return Self(
      item: item,
      startRefinementOnAppear: false,
      mode: isActiveSprintTicket ? .delivery : .editable
    )
  }
}

struct TicketEpicLink: View {
  let epic: Epic
  var onOpen: ((Epic) -> Void)?
  @State private var selectedEpic: Epic?
  @State private var isHovered = false

  var body: some View {
    Button {
      if let onOpen {
        onOpen(epic)
      } else {
        selectedEpic = epic
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "flag.checkered")
          .font(.caption2)
          .foregroundStyle(.purple)

        Text("Epic")
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(epic.displayTitle)
          .font(.caption.weight(.semibold))
          .lineLimit(1)

        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(isHovered ? Color.purple : Color.secondary)
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .fixedSize(horizontal: true, vertical: false)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isHovered
        ? Color.purple.opacity(0.12)
        : Color(nsColor: .controlBackgroundColor).opacity(0.72),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(
          isHovered
            ? Color.purple.opacity(0.55)
            : Color(nsColor: .separatorColor).opacity(0.45),
          lineWidth: 1
        )
    }
    .onHover { isHovered = $0 }
    .help("Open \(epic.displayTitle) in epic details")
    .sheet(item: $selectedEpic) { selectedEpic in
      EpicDetailView(epic: selectedEpic)
    }
  }
}

struct AcceptanceCriterionDraft: Identifiable, Equatable {
  let id = UUID()
  var text: String
}

struct EpicDetailItemDraft: Identifiable {
  let id = UUID()
  var text: String
}

struct FirstItemButton: View {
  let label: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(label, systemImage: systemImage)
        .font(.subheadline)
        .frame(maxWidth: .infinity, minHeight: 40)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(.separator.opacity(0.65), lineWidth: 1)
    }
  }
}

struct EpicDetailItemsEditor: View {
  let title: String
  let guidance: String
  let addLabel: String
  let firstItemLabel: String
  let itemPrompt: String
  let systemImage: String
  @Binding var items: [EpicDetailItemDraft]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(items.count.formatted())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.quaternary, in: Capsule())
        Spacer()
        Button {
          items.append(EpicDetailItemDraft(text: ""))
        } label: {
          Label(addLabel, systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Text(guidance)
        .font(.caption)
        .foregroundStyle(.secondary)

      if items.isEmpty {
        FirstItemButton(
          label: firstItemLabel,
          systemImage: systemImage
        ) {
          items.append(EpicDetailItemDraft(text: ""))
        }
      } else {
        VStack(spacing: 8) {
          ForEach($items) { $item in
            HStack(alignment: .center, spacing: 10) {
              Text("•")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 24)

              TextField(itemPrompt, text: $item.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)

              Button {
                items.removeAll { $0.id == item.id }
              } label: {
                Image(systemName: "xmark")
                  .frame(width: 20, height: 24)
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Remove item")
            }
            .padding(10)
            .background(
              Color(nsColor: .textBackgroundColor),
              in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 9)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
            }
          }
        }
      }
    }
  }
}

struct AcceptanceCriteriaEditor: View {
  @Binding var criteria: [AcceptanceCriterionDraft]

  private var isMissing: Bool {
    criteria.allSatisfy {
      $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Acceptance criteria")
          .font(.subheadline.weight(.semibold))
        Text(criteria.count.formatted())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.quaternary, in: Capsule())
        if isMissing {
          Label("Required", systemImage: "exclamationmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
        Spacer()
        Button {
          criteria.append(AcceptanceCriterionDraft(text: ""))
        } label: {
          Label("Add criterion", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Text("Each item should describe one independently verifiable outcome.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if criteria.isEmpty {
        FirstItemButton(
          label: "Add the first acceptance criterion",
          systemImage: "checklist"
        ) {
          criteria.append(AcceptanceCriterionDraft(text: ""))
        }
      } else {
        VStack(spacing: 8) {
          ForEach($criteria) { $criterion in
            HStack(alignment: .center, spacing: 10) {
              Text("•")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 24)

              TextField(
                "Describe a verifiable outcome",
                text: $criterion.text,
                axis: .vertical
              )
              .textFieldStyle(.plain)
              .lineLimit(1...4)

              Button {
                criteria.removeAll { $0.id == criterion.id }
              } label: {
                Image(systemName: "xmark")
                  .frame(width: 20, height: 24)
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Remove criterion")
            }
            .padding(10)
            .background(
              Color(nsColor: .textBackgroundColor),
              in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 9)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
            }
          }
        }
      }
    }
  }
}

enum TicketBlockerChoices {
  static func availableItems(
    in workItems: [WorkItem],
    excludingWorkItemID: UUID?,
    selectedIDs: Set<UUID>
  ) -> [WorkItem] {
    workItems.filter {
      [.backlog, .refining, .ready].contains($0.state)
        && $0.id != excludingWorkItemID
        && !selectedIDs.contains($0.id)
    }
  }
}

struct TicketBlockerEditor: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedIDs: Set<UUID>
  let excludingWorkItemID: UUID?
  let onOpen: (UUID) -> Void

  private var selectedItems: [WorkItem] {
    model.workItems.filter { selectedIDs.contains($0.id) }
  }

  private var availableItems: [WorkItem] {
    TicketBlockerChoices.availableItems(
      in: model.workItems,
      excludingWorkItemID: excludingWorkItemID,
      selectedIDs: selectedIDs
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Label("Blocked by", systemImage: "arrow.turn.up.left")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text("These tickets must be completed first and are kept above this ticket.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          if availableItems.isEmpty {
            Text("No available tickets")
          } else {
            ForEach(availableItems) { item in
              Button("\(item.key)  \(item.title)") {
                selectedIDs.insert(item.id)
              }
            }
          }
        } label: {
          Label("Add blocker", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if selectedItems.isEmpty {
        Text("No blockers")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(selectedItems) { item in
            HStack(alignment: .top, spacing: 9) {
              Text("•")
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
              Button {
                onOpen(item.id)
              } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                  Text(item.key)
                    .font(.callout.monospaced().weight(.semibold))
                  Text("·")
                    .foregroundStyle(.tertiary)
                  Text(item.title)
                    .fixedSize(horizontal: false, vertical: true)
                  Image(systemName: "arrow.right")
                    .font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)
              .foregroundStyle(Color.accentColor)
              .help("Open \(item.key) · \(item.title)")
              Spacer()
              Button {
                selectedIDs.remove(item.id)
              } label: {
                Image(systemName: "xmark")
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Remove blocker")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

enum TicketRefinementField: String, CaseIterable, Identifiable {
  case title
  case type
  case context
  case acceptanceCriteria
  case priority

  var id: String { rawValue }

  var label: String {
    switch self {
    case .title: "Title"
    case .type: "Type"
    case .context: "Context"
    case .acceptanceCriteria: "Acceptance criteria"
    case .priority: "Priority"
    }
  }
}

struct TicketRefinementFieldChange: Identifiable {
  let field: TicketRefinementField
  let before: String
  let after: String

  var id: TicketRefinementField { field }
}
