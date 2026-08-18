import AppKit
import SpeditoCore
import SwiftUI

struct ProductContextView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var name = ""
  @State private var isSaving = false
  @State private var isRevokingSavedAccess = false
  @State private var showingRevokeAllConfirmation = false
  @State private var pendingSavedAccessRevocation: AgentSavedAccessRevocationPlan?
  @State private var showingArchiveConfirmation = false
  @State private var isArchiving = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Product settings")
          .font(.title.bold())
        Text("Manage product details and saved agent access.")
          .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          EditableTextField(
            title: "Product name",
            prompt: "Product name",
            text: $name
          )

          Divider()
          if let product = model.selectedProduct {
            GitHubRepositorySettingsSection(
              product: product,
              importedRepository: model.productRepository
            )
          }

          Divider()

          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
              VStack(alignment: .leading, spacing: 3) {
                Text("Saved agent access")
                  .font(.headline)
                Text(
                  "Equivalent or narrower capability requests are allowed automatically for this product and recorded in the ticket work log. Exact commands remain exact."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer(minLength: 12)
              if !model.permissionGrants.isEmpty {
                Button("Revoke all", role: .destructive) {
                  requestSavedAccessRevocation(.all(model.permissionGrants))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isRevokingSavedAccess)
              }
            }

            if model.permissionGrants.isEmpty {
              Text("No saved access")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            } else {
              ForEach(AgentPermissionGrantPolicy.savedAccessGroups(for: model.permissionGrants)) {
                group in
                HStack(alignment: .top, spacing: 12) {
                  Image(systemName: group.kind == .command ? "terminal" : "lock.open")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.secondary)
                    Text(group.detail)
                      .font(
                        group.kind == .command
                          ? .system(.callout, design: .monospaced)
                          : .callout
                      )
                      .textSelection(.enabled)
                      .fixedSize(horizontal: false, vertical: true)
                    Text(
                      "Updated \(group.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                  }
                  Spacer(minLength: 12)
                  Button("Revoke", role: .destructive) {
                    requestSavedAccessRevocation(.group(group))
                  }
                  .disabled(isRevokingSavedAccess)
                }
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
              }
            }
          }

          Divider()

          VStack(alignment: .leading, spacing: 10) {
            Text("Archive product")
              .font(.headline)
            Text(
              "Remove this product from active navigation while preserving its backlog, work logs, product knowledge, source workspace, and delivery history."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Archive product", role: .destructive) {
              showingArchiveConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isArchiving || isSaving)
          }
        }
        .padding(24)
      }

      Divider()
      HStack {
        Spacer()
        Button("Cancel") {
          finishNameEdit(.cancel)
        }
        .disabled(isSaving)
        Button(isSaving ? "Saving..." : "Save") {
          finishNameEdit(.save)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isArchiving
            || isSaving
        )
      }
      .padding(20)
    }
    .background(InitialFocusClearer())
    .frame(width: 680, height: 640)
    .onAppear {
      name = model.selectedProduct?.name ?? ""
    }
    .confirmationDialog(
      "Revoke all saved agent access?",
      isPresented: $showingRevokeAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Revoke all", role: .destructive) {
        if let pendingSavedAccessRevocation {
          performSavedAccessRevocation(pendingSavedAccessRevocation)
        }
      }
      Button("Cancel", role: .cancel) {
        pendingSavedAccessRevocation = nil
      }
    } message: {
      Text(
        "Future matching requests will need your approval again. Existing work log history is preserved."
      )
    }
    .confirmationDialog(
      "Archive \(model.selectedProduct?.name ?? "this product")?",
      isPresented: $showingArchiveConfirmation,
      titleVisibility: .visible
    ) {
      Button("Archive product", role: .destructive) {
        archiveProduct(confirmed: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Active delivery will be safely suspended. Nothing is deleted, and you can restore the product later from products."
      )
    }
  }

  private func finishNameEdit(_ action: ProductNameEditAction) {
    switch ProductNameEditPolicy.resolve(draftName: name, action: action) {
    case .cancel:
      isPresented = false
    case .invalid:
      return
    case .save(let committedName):
      guard !isSaving else { return }
      isSaving = true
      Task {
        let didSave = await model.updateProductDetails(name: committedName)
        isSaving = false
        if didSave {
          isPresented = false
        }
      }
    }
  }

  private func requestSavedAccessRevocation(_ plan: AgentSavedAccessRevocationPlan) {
    guard !isRevokingSavedAccess, !plan.grantIDs.isEmpty else { return }
    if plan.requiresConfirmation {
      pendingSavedAccessRevocation = plan
      showingRevokeAllConfirmation = true
    } else {
      performSavedAccessRevocation(plan)
    }
  }

  private func performSavedAccessRevocation(_ plan: AgentSavedAccessRevocationPlan) {
    guard !isRevokingSavedAccess, !plan.grantIDs.isEmpty else { return }
    pendingSavedAccessRevocation = nil
    isRevokingSavedAccess = true
    Task {
      await model.revokePermissionGrants(plan.grantIDs)
      isRevokingSavedAccess = false
    }
  }

  private func archiveProduct(confirmed: Bool) {
    guard
      DestructiveProductSettingConfirmationPolicy.command(
        .archiveProduct,
        confirmed: confirmed
      ) != nil,
      !isArchiving
    else { return }
    isArchiving = true
    Task {
      let archived = await model.archiveSelectedProduct()
      isArchiving = false
      if archived {
        isPresented = false
      }
    }
  }
}

private enum TeamSettingsSelection: Hashable {
  case shared
  case profile(UUID)
}

struct TeamPromptsView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var sharedInstructions = ""
  @State private var customInstructions: [UUID: String] = [:]
  @State private var personaModels: [UUID: String] = [:]
  @State private var personaEfforts: [UUID: String] = [:]
  @State private var selection: TeamSettingsSelection? = .shared
  @State private var hoveredSelection: TeamSettingsSelection?
  @State private var isSaving = false
  @State private var saveError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Team settings")
            .font(.title2.bold())
          Text("Configure each team member's model, reasoning effort, and custom guidance.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(22)

      Divider()

      HStack(spacing: 0) {
        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              Text("Product")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 5)

              settingsNavigationRow(
                selectionValue: .shared,
                icon: "person.3",
                tint: .secondary,
                title: "Shared guidance",
                subtitle: "Applies to everyone",
                verticalPadding: 10
              )

              Text("Team members")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 5)

              ForEach(model.profiles) { profile in
                settingsNavigationRow(
                  selectionValue: .profile(profile.id),
                  icon: profile.role.symbolName,
                  tint: profile.role.tint,
                  title: profile.name,
                  subtitle: profile.role.capabilityTitle,
                  verticalPadding: 9
                )
              }
            }
            .padding(.bottom, 10)
          }
        }
        .frame(width: 248)

        Divider()

        Group {
          switch selection ?? .shared {
          case .shared:
            sharedGuidanceSettings
          case .profile(let profileID):
            if let profile = model.profiles.first(where: { $0.id == profileID }) {
              memberSettings(profile)
            } else {
              sharedGuidanceSettings
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      Divider()

      HStack(spacing: 10) {
        if let saveError {
          Text(saveError)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        if isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button("Cancel") { isPresented = false }
          .disabled(isSaving)
        Button("Save") {
          Task { await saveSettings() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSaving)
      }
      .padding(.horizontal, 22)
      .frame(height: 62)
    }
    .frame(width: 840, height: 740)
    .onAppear {
      synchronisePromptState(includeShared: true)
    }
    .onChange(of: model.profiles) {
      synchronisePromptState(includeShared: false)
      if case .profile(let profileID)? = selection,
        !model.profiles.contains(where: { $0.id == profileID })
      {
        selection = .shared
      }
    }
  }

  private func settingsNavigationRow(
    selectionValue: TeamSettingsSelection,
    icon: String,
    tint: Color,
    title: String,
    subtitle: String,
    verticalPadding: CGFloat
  ) -> some View {
    let isSelected = selection == selectionValue
    let isHovering = hoveredSelection == selectionValue

    return Button {
      selection = selectionValue
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .foregroundStyle(tint)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected
          ? Color.accentColor.opacity(0.1)
          : (isHovering ? tint.opacity(0.09) : Color.clear),
        in: RoundedRectangle(cornerRadius: 7)
      )
      .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        hoveredSelection = hovering ? selectionValue : nil
      }
    }
  }

  private var sharedGuidanceSettings: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Shared product guidance")
            .font(.title3.bold())
          Text(
            "Optional conventions and product principles supplied to every team member."
          )
          .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 9) {
          Text("Instructions")
            .font(.headline)
          Text(
            "Verified product knowledge, the ticket contract, and the definition of done are supplied separately."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          instructionsEditor(text: $sharedInstructions)
        }

        Label {
          Text(
            "Safety, permissions, approved scope, and workflow gates are enforced by Spedito and cannot be changed here."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "lock.shield")
            .foregroundStyle(.secondary)
        }
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func memberSettings(_ profile: AgentProfile) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 12) {
          Image(systemName: profile.role.symbolName)
            .font(.title2)
            .foregroundStyle(profile.role.tint)
            .frame(width: 28)
          VStack(alignment: .leading, spacing: 3) {
            Text(profile.name)
              .font(.title3.bold())
            Text(profile.role.capabilityTitle)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if !profile.isBuiltIn {
            Button(role: .destructive) {
              model.archiveCustomPersona(profile)
            } label: {
              Label("Remove member", systemImage: "trash")
            }
            .buttonStyle(.borderless)
          }
        }

        VStack(alignment: .leading, spacing: 14) {
          Text("Runtime")
            .font(.headline)

          Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
            GridRow {
              Text("Model")
                .foregroundStyle(.secondary)
              Picker("Model", selection: modelBinding(for: profile)) {
                if model.codexModels.isEmpty {
                  Text(profile.model).tag(profile.model)
                } else {
                  ForEach(model.codexModels) { option in
                    Text(option.displayName).tag(option.model)
                  }
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            GridRow {
              Text("Reasoning effort")
                .foregroundStyle(.secondary)
              Picker("Reasoning effort", selection: effortBinding(for: profile)) {
                ForEach(effortOptions(for: profile)) { effort in
                  Text(effort.id.displayEffort).tag(effort.id)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .frame(maxWidth: 480, alignment: .leading)
        }

        VStack(alignment: .leading, spacing: 9) {
          HStack {
            Text("Custom instructions")
              .font(.headline)
            Spacer()
            Button("Clear custom instructions") {
              customInstructions[profile.id] = ""
            }
            .buttonStyle(.borderless)
            .font(.caption)
          }

          Text(
            "Spedito supplies this member's built-in role guidance. Add only the extra instructions you want applied after it."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          instructionsEditor(
            text: Binding(
              get: { customInstructions[profile.id] ?? profile.customInstructionText },
              set: { customInstructions[profile.id] = $0 }
            )
          )
        }
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func instructionsEditor(text: Binding<String>) -> some View {
    TextEditor(text: text)
      .scrollContentBackground(.hidden)
      .multilineTextAlignment(.leading)
      .font(.body)
      .padding(8)
      .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(.separator.opacity(0.7), lineWidth: 1)
      }
  }

  private func synchronisePromptState(includeShared: Bool) {
    if includeShared {
      sharedInstructions = model.selectedProduct?.instructions ?? ""
    }
    for profile in model.profiles {
      customInstructions[profile.id] = profile.customInstructionText
      personaModels[profile.id] = profile.model
      personaEfforts[profile.id] = profile.reasoningEffort
    }
    let activeIDs = Set(model.profiles.map(\.id))
    customInstructions = customInstructions.filter { activeIDs.contains($0.key) }
    personaModels = personaModels.filter { activeIDs.contains($0.key) }
    personaEfforts = personaEfforts.filter { activeIDs.contains($0.key) }
  }

  private func saveSettings() async {
    guard !isSaving else { return }
    isSaving = true
    saveError = nil
    defer { isSaving = false }
    let instructionUpdates = Dictionary(
      uniqueKeysWithValues: model.profiles.map { profile in
        (profile.id, customInstructions[profile.id] ?? profile.customInstructionText)
      }
    )
    let result = await model.updateTeamSettings(
      productInstructions: sharedInstructions,
      modelsByProfile: personaModels,
      effortsByProfile: personaEfforts,
      customInstructionsByProfile: instructionUpdates
    )
    switch result {
    case .success:
      isPresented = false
    case .failure(let failure):
      saveError = failure.message
    }
  }

  private func modelBinding(for profile: AgentProfile) -> Binding<String> {
    Binding(
      get: { personaModels[profile.id] ?? profile.model },
      set: { selectedModel in
        personaModels[profile.id] = selectedModel
        guard let option = model.codexModels.first(where: { $0.model == selectedModel }) else {
          return
        }
        let supported = option.supportedReasoningEfforts.map(\.id)
        let currentEffort = personaEfforts[profile.id] ?? profile.reasoningEffort
        if !supported.contains(currentEffort) {
          personaEfforts[profile.id] = option.defaultReasoningEffort
        }
      }
    )
  }

  private func effortBinding(for profile: AgentProfile) -> Binding<String> {
    Binding(
      get: { personaEfforts[profile.id] ?? profile.reasoningEffort },
      set: { personaEfforts[profile.id] = $0 }
    )
  }

  private func effortOptions(for profile: AgentProfile) -> [CodexReasoningEffortOption] {
    let selectedModel = personaModels[profile.id] ?? profile.model
    return model.codexModels.first(where: { $0.model == selectedModel })?
      .supportedReasoningEfforts
      ?? [
        CodexReasoningEffortOption(
          id: personaEfforts[profile.id] ?? profile.reasoningEffort,
          description: "Current selection"
        )
      ]
  }
}

private struct AddPersonaView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var templateID = "blank"
  @State private var name = ""
  @State private var capability = AgentRole.businessAnalyst
  @State private var selectedModel = "gpt-5.6-terra"
  @State private var effort = "medium"
  @State private var instructions = ""

  private var selectedModelOption: CodexModelOption? {
    model.codexModels.first { $0.model == selectedModel }
  }

  private var effortOptions: [CodexReasoningEffortOption] {
    selectedModelOption?.supportedReasoningEfforts ?? [
      CodexReasoningEffortOption(id: effort, description: "Current selection")
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add team member")
          .font(.title2.bold())
        Text("Start with a specialist template or configure a member from scratch.")
          .foregroundStyle(.secondary)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 7) {
            Text("Starting point")
              .font(.subheadline.weight(.semibold))
            Picker("Starting point", selection: $templateID) {
              Text("Blank team member").tag("blank")
              Divider()
              ForEach(PersonaTemplate.common) { template in
                Text(template.name).tag(template.id)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: templateID) {
              applySelectedTemplate()
            }
          }

          EditableTextField(
            title: "Team member name",
            prompt: "e.g. Security Auditor",
            text: $name
          )

          HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
              Text("Governed capability")
                .font(.subheadline.weight(.semibold))
              Picker("Governed capability", selection: $capability) {
                ForEach(AgentRole.allCases, id: \.self) { role in
                  Text(role.capabilityTitle).tag(role)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
              Text("Model")
                .font(.subheadline.weight(.semibold))
              Picker("Model", selection: $selectedModel) {
                if model.codexModels.isEmpty {
                  Text(selectedModel).tag(selectedModel)
                } else {
                  ForEach(model.codexModels) { option in
                    Text(option.displayName).tag(option.model)
                  }
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .onChange(of: selectedModel) {
                effort = CustomTeamMemberRuntimePolicy.compatibleEffort(
                  requestedEffort: effort,
                  model: selectedModelOption
                )
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
              Text("Reasoning effort")
                .font(.subheadline.weight(.semibold))
              Picker("Reasoning effort", selection: $effort) {
                ForEach(effortOptions) { option in
                  Text(option.id.displayEffort).tag(option.id)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          EditableTextArea(
            title: "Custom instructions",
            prompt: "Add optional guidance beyond this member's built-in role.",
            text: $instructions,
            minHeight: 150
          )
        }
      }

      HStack {
        Label(
          "This team member uses the \(capability.capabilityTitle.lowercased()) capability and cannot expand its own permissions.",
          systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { isPresented = false }
        Button("Add to team") {
          model.createCustomPersona(
            name: name,
            capability: capability,
            model: selectedModel,
            effort: effort,
            instructions: instructions
          )
          isPresented = false
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 680, height: 650)
    .onAppear {
      if let defaultModel = model.codexModels.first(where: \.isDefault) {
        selectedModel = defaultModel.model
        effort = defaultModel.defaultReasoningEffort
      }
      instructions = ""
    }
  }

  private func applySelectedTemplate() {
    guard let template = PersonaTemplate.common.first(where: { $0.id == templateID }) else {
      name = ""
      capability = .businessAnalyst
      selectedModel = model.codexModels.first(where: \.isDefault)?.model ?? "gpt-5.6-terra"
      effort = model.codexModels.first(where: \.isDefault)?.defaultReasoningEffort ?? "medium"
      instructions = ""
      return
    }
    name = template.name
    capability = template.capability
    selectedModel =
      model.codexModels.contains { $0.model == template.model }
      ? template.model
      : model.codexModels.first(where: \.isDefault)?.model ?? template.model
    effort = CustomTeamMemberRuntimePolicy.compatibleEffort(
      requestedEffort: template.effort,
      model: selectedModelOption
    )
    instructions = template.instructions
  }
}
