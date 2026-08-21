import SpeditoCore
import SwiftUI

struct NewProductView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let onCreated: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text("New product")
          .font(.title2.bold())
        Text("Create a blank product or start from an existing public or private repository.")
          .foregroundStyle(.secondary)
      }

      ProductCreationForm(
        blankActionTitle: "Create product",
        importActionTitle: "Create from repository",
        onCreate: model.createProductAndSelect,
        onCreated: {
          isPresented = false
          onCreated()
        }
      ) { isCreating in
        Button("Cancel") { isPresented = false }
          .keyboardShortcut(.cancelAction)
          .disabled(isCreating)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private enum ProductCreationMode: String, CaseIterable, Identifiable {
  case blank
  case importRepository

  var id: String { rawValue }
}

struct ProductCreationForm<SecondaryActions: View>: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  let blankActionTitle: String
  let importActionTitle: String
  let actionControlSize: ControlSize
  let onCreate: (ProductCreationRequest) async -> Bool
  let onCreated: () -> Void
  @ViewBuilder let secondaryActions: (Bool) -> SecondaryActions

  @State private var mode = ProductCreationMode.blank
  @State private var name = ""
  @State private var repositoryLink = ""
  @State private var generatedName: String?
  @State private var isCreating = false
  @State private var selectedGitHubRepositoryID: Int64?
  @State private var awaitingGitHubRepositoryAccess = false
  @State private var creationError: String?

  init(
    blankActionTitle: String,
    importActionTitle: String,
    actionControlSize: ControlSize = .regular,
    onCreate: @escaping (ProductCreationRequest) async -> Bool,
    onCreated: @escaping () -> Void = {},
    @ViewBuilder secondaryActions: @escaping (Bool) -> SecondaryActions
  ) {
    self.blankActionTitle = blankActionTitle
    self.importActionTitle = importActionTitle
    self.actionControlSize = actionControlSize
    self.onCreate = onCreate
    self.onCreated = onCreated
    self.secondaryActions = secondaryActions
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("Start with", selection: $mode) {
        Text("Blank product").tag(ProductCreationMode.blank)
        Text("Git repository").tag(ProductCreationMode.importRepository)
      }
      .pickerStyle(.segmented)
      .disabled(isCreating)
      ProductNameEntryField(
        text: $name,
        isDisabled: isCreating,
        onSubmit: createProduct
      )

      if mode == .importRepository {
        githubRepositoryImportPicker
        RepositoryLinkEntryField(text: $repositoryLink, isDisabled: isCreating)
        Text(
          "Spedito preserves existing Git history and the default branch. If the repository is empty, Spedito initializes it with the new Product. Spedito uses your internet connection to access the repository, and Codex sends sanitized repository context to your selected model provider. The analysis agent itself cannot run repository code, browse the web, or contact other services."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      if let creationError {
        Label(creationError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        secondaryActions(isCreating)
        Spacer()
        Button(actionTitle) {
          createProduct()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canCreate || isCreating)
      }
      .controlSize(actionControlSize)
    }
    .onChange(of: repositoryLink) { _, _ in
      prefillSuggestedName()
    }
    .onChange(of: mode) { _, _ in
      creationError = nil
    }
    .task(id: mode) {
      guard mode == .importRepository else { return }
      await model.sendRepositoryImportCommand(.loadAuthorizedRepositories)
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active, awaitingGitHubRepositoryAccess else { return }
      awaitingGitHubRepositoryAccess = false
      Task { await model.sendRepositoryImportCommand(.loadAuthorizedRepositories) }
    }
    .sheet(isPresented: githubImportDevicePromptPresentation) {
      if let prompt = model.repositoryImportSnapshot.authorizationPrompt {
        GitHubDeviceAuthorizationSheet(
          prompt: prompt,
          onCancel: {
            Task { await model.cancelRepositoryImport() }
          }
        )
      }
    }
  }

  @ViewBuilder
  private var githubRepositoryImportPicker: some View {
    let catalog = model.repositoryImportSnapshot.catalog
    let choices = catalog.choices
    VStack(alignment: .leading, spacing: 7) {
      Text("GitHub repository")
        .font(.subheadline.weight(.semibold))
      if model.repositoryImportSnapshot.isLoadingAuthorizedRepositories, choices.isEmpty {
        ProgressView("Loading repositories...")
          .controlSize(.small)
      } else if !choices.isEmpty {
        HStack(spacing: 6) {
          Picker("GitHub repository", selection: $selectedGitHubRepositoryID) {
            Text("Choose a repository").tag(Int64?.none)
            ForEach(choices) { choice in
              Text(
                choice.repository.fullName
                  + (choice.repository.isPrivate ? " · Private" : "")
              )
              .tag(Optional(choice.repository.id))
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .disabled(isCreating)
          .onChange(of: selectedGitHubRepositoryID) { _, repositoryID in
            guard
              let repositoryID,
              let repository = choices.first(where: { $0.repository.id == repositoryID })?
                .repository
            else { return }
            repositoryLink = repository.canonicalHTTPSURL.absoluteString
            prefillSuggestedName()
          }
          refreshRepositoryListControl
        }
        Text(
          "Choose a repository available to the Spedito GitHub App. To add another repository, manage access on GitHub; Spedito refreshes this list when you return."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        HStack {
          githubRepositoryAccessControl
            .buttonStyle(.bordered)
          Button("Add GitHub account") {
            Task { await model.sendRepositoryImportCommand(.authorizeGitHub) }
          }
          .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .disabled(isCreating)
      } else {
        Text(
          model.repositoryImportSnapshot.failure?.message
            ?? "No repositories are available through a connected GitHub account. You can still paste a public repository link."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          if catalog.installations.isEmpty {
            Button("Connect GitHub") {
              Task { await model.sendRepositoryImportCommand(.authorizeGitHub) }
            }
            .buttonStyle(.borderedProminent)
            githubRepositoryAccessControl
              .buttonStyle(.bordered)
          } else {
            githubRepositoryAccessControl
              .buttonStyle(.borderedProminent)
            Button("Add GitHub account") {
              Task { await model.sendRepositoryImportCommand(.authorizeGitHub) }
            }
            .buttonStyle(.bordered)
          }
          refreshRepositoryListControl
        }
        .disabled(isCreating)
      }
    }
  }

  @ViewBuilder
  private var refreshRepositoryListControl: some View {
    Group {
      if model.repositoryImportSnapshot.isLoadingAuthorizedRepositories {
        ProgressView()
          .controlSize(.small)
      } else {
        Button {
          Task { await model.sendRepositoryImportCommand(.loadAuthorizedRepositories) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .help("Refresh list")
        .accessibilityLabel("Refresh list")
        .disabled(isCreating)
      }
    }
    .frame(width: 30)
  }

  private var githubImportDevicePromptPresentation: Binding<Bool> {
    Binding(
      get: { model.repositoryImportSnapshot.authorizationPrompt != nil },
      set: { presented in
        if !presented, model.repositoryImportSnapshot.authorizationPrompt != nil {
          Task { await model.cancelRepositoryImport() }
        }
      }
    )
  }

  private var githubRepositoryAccessDestinations: [GitHubRepositoryImportAccessDestination] {
    GitHubRepositoryImportAccessPresentation.resolve(
      installations: model.repositoryImportSnapshot.catalog.installations,
      appSlug: GitHubConfiguration.current().appSlug
    )
  }

  @ViewBuilder
  private var githubRepositoryAccessControl: some View {
    if githubRepositoryAccessDestinations.count == 1,
      let destination = githubRepositoryAccessDestinations.first
    {
      Button(destination.title) {
        openGitHubRepositoryAccess(destination)
      }
    } else if !githubRepositoryAccessDestinations.isEmpty {
      Menu("Manage repository access") {
        ForEach(githubRepositoryAccessDestinations, id: \.url) { destination in
          Button(destination.title) {
            openGitHubRepositoryAccess(destination)
          }
        }
      }
    }
  }

  private func openGitHubRepositoryAccess(
    _ destination: GitHubRepositoryImportAccessDestination
  ) {
    awaitingGitHubRepositoryAccess = true
    openURL(destination.url)
  }

  private var publicRepositoryURL: PublicGitRepositoryURL? {
    try? PublicGitRepositoryURL(repositoryLink)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canCreate: Bool {
    guard !trimmedName.isEmpty else { return false }
    return mode == .blank
      || selectedGitHubRepositoryID != nil
      || publicRepositoryURL != nil
  }

  private var actionTitle: String {
    if isCreating {
      return mode == .blank ? "Creating…" : "Creating product from repository…"
    }
    return mode == .blank ? blankActionTitle : importActionTitle
  }

  private func prefillSuggestedName() {
    guard let publicRepositoryURL else { return }
    if trimmedName.isEmpty || name == generatedName {
      name = publicRepositoryURL.suggestedProductName
      generatedName = name
    }
  }

  private func createProduct() {
    guard canCreate, !isCreating else { return }
    let request: ProductCreationRequest
    switch mode {
    case .blank:
      request = .blank(name: trimmedName)
    case .importRepository:
      if let selectedGitHubRepositoryID {
        request = .importGitHubRepository(
          name: trimmedName,
          repositoryID: selectedGitHubRepositoryID
        )
      } else {
        guard let publicRepositoryURL else { return }
        request = .importRepository(name: trimmedName, source: publicRepositoryURL)
      }
    }
    creationError = nil
    isCreating = true
    Task {
      let created = await onCreate(request)
      isCreating = false
      if created {
        onCreated()
      } else {
        creationError =
          model.repositoryImportSnapshot.failure?.message
          ?? model.productCreationError
          ?? "Spedito couldn't create the Product. Review the details and try again."
      }
    }
  }
}

private struct RepositoryLinkEntryField: View {
  @Binding var text: String
  let isDisabled: Bool
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Repository link")
        .font(.subheadline.weight(.semibold))
      TextField("Repository link", text: $text, prompt: Text("https://github.com/team/product.git"))
        .textFieldStyle(.plain)
        .padding(.horizontal, 11)
        .frame(height: 40)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(
              isFocused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.7),
              lineWidth: isFocused ? 2 : 1
            )
        }
        .focused($isFocused)
        .disabled(isDisabled)
    }
  }
}

private struct ProductNameEntryField: View {
  @Binding var text: String
  let isDisabled: Bool
  let onSubmit: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Product name")
        .font(.subheadline.weight(.semibold))
      TextField(
        "Product name",
        text: $text,
        prompt: Text("e.g. Weather App")
      )
      .textFieldStyle(.plain)
      .padding(.horizontal, 11)
      .frame(height: 40)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isFocused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.7),
            lineWidth: isFocused ? 2 : 1
          )
      }
      .focused($isFocused)
      .disabled(isDisabled)
      .onSubmit(onSubmit)
    }
    .task {
      isFocused = true
    }
    .onChange(of: isDisabled) { _, disabled in
      if !disabled {
        isFocused = true
      }
    }
  }
}
