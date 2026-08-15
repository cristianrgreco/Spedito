import SpeditoCore
import SwiftUI

struct KnowledgeBaseView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selectedPageID: UUID?
  @State private var searchText = ""
  @State private var question = ""
  @State private var submittedQuestion = ""
  @State private var answer: KnowledgeAnswer?
  @State private var showingKnowledgeAnswer = false
  @State private var isEditing = false
  @State private var titleDraft = ""
  @State private var bodyDraft = ""
  @State private var revisions: [KnowledgePageRevision] = []
  @State private var showingNewPage = false
  @State private var newPageTitle = ""

  var body: some View {
    GeometryReader { proxy in
      VStack(alignment: .leading, spacing: 0) {
        header
          .workspaceHeaderLayout()

        Divider()

        HSplitView {
          pageTree
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
          pageContent
            .frame(minWidth: 480, maxWidth: .infinity)
          metadataRail
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
        }
      }
      .frame(
        width: proxy.size.width,
        height: proxy.size.height,
        alignment: .topLeading
      )
    }
    .onAppear { selectRequestedOrInitialPage() }
    .onChange(of: model.knowledgePages) { selectRequestedOrInitialPage() }
    .onChange(of: model.selectedProductID) { _, _ in
      selectRequestedOrInitialPage()
    }
    .onChange(of: model.knowledgeFocusPageID) { _, _ in
      selectRequestedOrInitialPage()
    }
    .onChange(of: selectedPageID) { loadSelectedPage() }
    .alert("New knowledge page", isPresented: $showingNewPage) {
      TextField("Page title", text: $newPageTitle)
      Button("Cancel", role: .cancel) {}
      Button("Create") {
        let title = newPageTitle
        let parentID = newPageParentID
        guard let productID = model.selectedProductID else { return }
        Task {
          if let page = await model.createKnowledgePage(
            productID: productID,
            parentID: parentID,
            title: title
          ) {
            selectedPageID = page.id
            isEditing = true
          }
        }
      }
      .disabled(newPageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("The page will be created beneath the current section.")
    }
    .sheet(isPresented: $showingKnowledgeAnswer) {
      KnowledgeAnswerSheet(
        question: submittedQuestion,
        answer: $answer,
        selectedPageID: $selectedPageID,
        isPresented: $showingKnowledgeAnswer
      )
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Product")
            .font(.largeTitle.bold())
          Text("Verified product knowledge, decisions, runbooks, and delivery history.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          newPageTitle = ""
          showingNewPage = true
        } label: {
          Label("New page", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
      }
      .disabled(repositoryKnowledgeIsRunning)

      HStack(spacing: 8) {
        Image(systemName: "sparkle.magnifyingglass")
          .foregroundStyle(.indigo)
        TextField("Ask…", text: $question)
          .textFieldStyle(.plain)
          .onSubmit { askKnowledge() }
          .disabled(model.isAskingKnowledge)
          .help("Press Return to ask")
        if !question.isEmpty {
          Button {
            question = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("Clear question")
        }
        if model.isAskingKnowledge {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }
  }

  private var repositoryKnowledgeIsRunning: Bool {
    guard let status = model.repositoryKnowledgeSnapshot?.run?.status else { return false }
    return status == .pendingAnalysis || status == .analyzing || status == .reviewing
      || status == .publishing
  }

  private var selectedPage: KnowledgePage? {
    guard let selectedPageID else { return nil }
    return model.knowledgePages.first { $0.id == selectedPageID }
  }

  private var newPageParentID: UUID? {
    guard let selectedPage else { return nil }
    return selectedPage.kind == .section ? selectedPage.id : selectedPage.parentID
  }

  private var rootPages: [KnowledgePage] {
    sorted(model.knowledgePages.filter { $0.parentID == nil })
  }

  private var filteredPages: [KnowledgePage] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return [] }
    return model.knowledgePages.filter {
      $0.title.lowercased().contains(query)
        || $0.bodyMarkdown.lowercased().contains(query)
    }
  }

  private var changedPageIDs: Set<UUID> {
    model.unreadKnowledgePageIDs
  }

  private var pageTree: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search pages", text: $searchText)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ForEach(rootPages) { page in
              KnowledgeTreeBranch(
                page: page,
                pages: model.knowledgePages,
                changedPageIDs: changedPageIDs,
                selectedPageID: $selectedPageID,
                depth: 0
              )
            }
          } else if filteredPages.isEmpty {
            Text("No matching pages")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(10)
          } else {
            ForEach(filteredPages) { page in
              KnowledgeTreeRow(
                page: page,
                isSelected: selectedPageID == page.id,
                isChanged: changedPageIDs.contains(page.id),
                containsChangedPage: false
              ) {
                selectedPageID = page.id
              }
            }
          }
        }
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.14))
  }

  @ViewBuilder
  private var pageContent: some View {
    if let page = selectedPage {
      VStack(alignment: .leading, spacing: 0) {
        pageToolbar(page)
        Divider()
        if isEditing {
          pageEditor(page)
        } else {
          pageReader(page)
        }
      }
    } else {
      ContentUnavailableView("Choose a page", systemImage: "doc.text")
    }
  }

  private func pageToolbar(_ page: KnowledgePage) -> some View {
    HStack {
      HStack(spacing: 5) {
        ForEach(Array(breadcrumbs(for: page).enumerated()), id: \.element.id) { index, crumb in
          if index > 0 {
            Image(systemName: "chevron.right")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Button(crumb.title) { selectedPageID = crumb.id }
            .buttonStyle(.plain)
            .foregroundStyle(crumb.id == page.id ? .primary : .secondary)
        }
      }
      .font(.caption)
      Spacer()
      if isEditing {
        Button("Cancel") {
          loadSelectedPage()
          isEditing = false
        }
        Button("Save") {
          Task {
            if await model.saveKnowledgePage(
              productID: page.productID,
              id: page.id,
              title: titleDraft,
              bodyMarkdown: bodyDraft,
              changeSummary: "Edited page"
            ) {
              isEditing = false
              revisions = await model.knowledgeRevisions(
                productID: page.productID,
                for: page.id
              )
            }
          }
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button {
          isEditing = true
        } label: {
          Label("Edit", systemImage: "pencil")
        }
        .disabled(repositoryKnowledgeIsRunning)
      }
    }
    .padding(.horizontal, 22)
    .frame(height: 50)
  }

  private func pageEditor(_ page: KnowledgePage) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      TextField("Page title", text: $titleDraft)
        .font(.title.bold())
        .textFieldStyle(.plain)
      TextEditor(text: $bodyDraft)
        .font(.body.monospaced())
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }
    .padding(24)
  }

  private func pageReader(_ page: KnowledgePage) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text(page.title)
          .font(.largeTitle.bold())
          .textSelection(.enabled)

        let body = KnowledgeMarkdown.normalizedBody(page.bodyMarkdown)
        if body.isEmpty {
          Text(
            page.kind == .section
              ? "Choose a page in this section or create one."
              : "This page is empty. Edit it to add verified knowledge."
          )
          .foregroundStyle(.secondary)
        } else {
          KnowledgeMarkdownDocument(source: body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        let children = childPages(of: page.id)
        if !children.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            Text("In this section")
              .font(.headline)
            ForEach(children) { child in
              Button {
                selectedPageID = child.id
              } label: {
                HStack {
                  Image(systemName: child.kind == .section ? "folder" : "doc.text")
                  Text(child.title)
                  Spacer()
                  Image(systemName: "chevron.right")
                    .font(.caption)
                }
              }
              .buttonStyle(.plain)
              .padding(10)
              .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var metadataRail: some View {
    if let page = selectedPage {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("Page details")
            .font(.headline)
          KnowledgeMetadataRow(
            title: "Status",
            value: page.verificationStatus.title,
            symbol: page.verificationStatus == .verified
              ? "checkmark.seal.fill" : "clock.badge"
          )
          KnowledgeMetadataRow(
            title: "Updated",
            value: page.updatedAt.formatted(date: .abbreviated, time: .shortened),
            symbol: "clock"
          )
          if let sourceID = page.sourceWorkItemID,
            let ticket = model.workItems.first(where: { $0.id == sourceID })
          {
            KnowledgeMetadataRow(title: "Source ticket", value: ticket.key, symbol: "link")
          }

          Divider()
          metadataSection(title: "On this page") {
            let headings = tableOfContents(KnowledgeMarkdown.normalizedBody(page.bodyMarkdown))
            if headings.isEmpty {
              metadataEmpty("No headings")
            } else {
              ForEach(headings, id: \.self) { Text($0).font(.caption) }
            }
          }

          Divider()
          metadataSection(title: "Version history") {
            ForEach(revisions.prefix(8)) { revision in
              VStack(alignment: .leading, spacing: 2) {
                Text("v\(revision.version) · \(revision.authorName)")
                  .font(.caption.weight(.semibold))
                Text(revision.changeSummary)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                Text(revision.createdAt, style: .relative)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }
            }
          }

          Divider()
          metadataSection(title: "Backlinks") {
            let linkedPages = backlinks(to: page)
            if linkedPages.isEmpty {
              metadataEmpty("No backlinks yet")
            } else {
              ForEach(linkedPages) { linkedPage in
                Button {
                  selectedPageID = linkedPage.id
                } label: {
                  HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(linkedPage.title)
                      .lineLimit(2)
                    Spacer(minLength: 0)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.link)
              }
            }
          }
        }
        .padding(18)
      }
      .background(.quaternary.opacity(0.14))
    } else {
      Color.clear
    }
  }

  private func metadataSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.subheadline.bold())
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func metadataEmpty(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func sorted(_ pages: [KnowledgePage]) -> [KnowledgePage] {
    pages.sorted {
      $0.sortOrder == $1.sortOrder ? $0.title < $1.title : $0.sortOrder < $1.sortOrder
    }
  }

  private func childPages(of parentID: UUID) -> [KnowledgePage] {
    sorted(model.knowledgePages.filter { $0.parentID == parentID })
  }

  private func breadcrumbs(for page: KnowledgePage) -> [KnowledgePage] {
    var result = [page]
    var parentID = page.parentID
    while let id = parentID, let parent = model.knowledgePages.first(where: { $0.id == id }) {
      result.insert(parent, at: 0)
      parentID = parent.parentID
    }
    return result
  }

  private func tableOfContents(_ source: String) -> [String] {
    source.split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#") else { return nil }
      return trimmed.drop(while: { $0 == "#" || $0 == " " }).description
    }
  }

  private func backlinks(to page: KnowledgePage) -> [KnowledgePage] {
    model.knowledgePages.filter {
      $0.id != page.id
        && ($0.bodyMarkdown.localizedCaseInsensitiveContains("[[\(page.title)]]")
          || $0.bodyMarkdown.localizedCaseInsensitiveContains(page.slug))
    }
  }

  private func selectRequestedOrInitialPage() {
    if let requestedPageID = model.knowledgeFocusPageID,
      model.knowledgePages.contains(where: { $0.id == requestedPageID })
    {
      selectedPageID = requestedPageID
      model.consumeKnowledgeFocus(pageID: requestedPageID)
      loadSelectedPage()
      return
    }
    if selectedPageID == nil
      || !model.knowledgePages.contains(where: { $0.id == selectedPageID })
    {
      selectedPageID =
        model.knowledgePages.first(where: { $0.slug == "home" })?.id
        ?? model.knowledgePages.first?.id
    }
    loadSelectedPage()
  }

  private func loadSelectedPage() {
    guard let page = selectedPage else { return }
    model.markKnowledgePageRead(page)
    titleDraft = page.title
    bodyDraft = KnowledgeMarkdown.normalizedBody(page.bodyMarkdown)
    isEditing = false
    Task {
      revisions = await model.knowledgeRevisions(
        productID: page.productID,
        for: page.id
      )
    }
  }

  private func askKnowledge() {
    let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !submitted.isEmpty, !model.isAskingKnowledge else { return }
    submittedQuestion = submitted
    question = ""
    answer = nil
    showingKnowledgeAnswer = true
    Task { answer = await model.askKnowledge(submitted) }
  }

}

private struct KnowledgeMarkdownDocument: View {
  let source: String

  private var blocks: [KnowledgeMarkdown.Block] {
    KnowledgeMarkdown.blocks(in: source)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func blockView(_ block: KnowledgeMarkdown.Block) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(inlineMarkdown(text))
        .font(headingFont(level))
        .padding(.top, level == 2 ? 5 : 1)
    case .paragraph(let lines):
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(inlineMarkdown(line))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .lineSpacing(3)
    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("•")
              .foregroundStyle(.secondary)
            Text(inlineMarkdown(item))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.leading, 5)
    case .orderedList(let items):
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(index + 1).")
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .frame(minWidth: 20, alignment: .trailing)
            Text(inlineMarkdown(item))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    case .quote(let lines):
      HStack(alignment: .top, spacing: 12) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.accentColor.opacity(0.55))
          .frame(width: 3)
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(inlineMarkdown(line))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .foregroundStyle(.secondary)
      }
      .padding(.vertical, 2)
    case .code(let code):
      ScrollView(.horizontal) {
        Text(code)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    case .table(let table):
      MarkdownTableView(
        table: table,
        font: .body,
        inlineMarkdown: inlineMarkdown
      )
    case .divider:
      Divider()
    }
  }

  private func inlineMarkdown(_ source: String) -> AttributedString {
    SafeURLPolicy.markdown(source)
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title.bold()
    case 2: .title2.bold()
    case 3: .title3.bold()
    default: .headline
    }
  }
}

private struct KnowledgeAnswerSheet: View {
  @EnvironmentObject private var model: AppModel
  let question: String
  @Binding var answer: KnowledgeAnswer?
  @Binding var selectedPageID: UUID?
  @Binding var isPresented: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "sparkle.magnifyingglass")
          .font(.title3)
          .foregroundStyle(.indigo)
        VStack(alignment: .leading, spacing: 2) {
          Text("Product answer")
            .font(.title2.bold())
          Text("Grounded in verified product knowledge")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Close") { isPresented = false }
      }
      .padding(22)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          VStack(alignment: .leading, spacing: 7) {
            Text("Question")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(question)
              .font(.title3.weight(.medium))
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

          if let answer {
            VStack(alignment: .leading, spacing: 12) {
              Label("Answer", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.indigo)
              KnowledgeMarkdownDocument(source: answer.answer)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !answer.citationPageIDs.isEmpty {
              Divider()
              VStack(alignment: .leading, spacing: 10) {
                Text("Sources")
                  .font(.headline)
                ForEach(answer.citationPageIDs, id: \.self) { id in
                  if let page = model.knowledgePages.first(where: { $0.id == id }) {
                    Button {
                      selectedPageID = id
                      isPresented = false
                    } label: {
                      HStack(spacing: 11) {
                        Image(systemName: "doc.text")
                          .foregroundStyle(.indigo)
                          .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                          Text(page.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                          Text(page.verificationStatus.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                          .font(.caption.weight(.semibold))
                          .foregroundStyle(.tertiary)
                      }
                      .padding(12)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .background(
                        .quaternary.opacity(0.28),
                        in: RoundedRectangle(cornerRadius: 10)
                      )
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
            }
          } else if model.isAskingKnowledge {
            VStack(spacing: 10) {
              ProgressView()
                .controlSize(.small)
              Text("Reviewing verified knowledge…")
                .font(.callout.weight(.medium))
              Text("The answer and its sources will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
          } else {
            ContentUnavailableView {
              Label("No answer available", systemImage: "questionmark.bubble")
            } description: {
              Text("Close this sheet and try a different question.")
            }
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 720, height: 620)
  }
}

private struct KnowledgeTreeBranch: View {
  let page: KnowledgePage
  let pages: [KnowledgePage]
  let changedPageIDs: Set<UUID>
  @Binding var selectedPageID: UUID?
  let depth: Int
  @State private var isExpanded = true

  private var children: [KnowledgePage] {
    pages.filter { $0.parentID == page.id }.sorted {
      $0.sortOrder == $1.sortOrder ? $0.title < $1.title : $0.sortOrder < $1.sortOrder
    }
  }

  private var containsChangedPage: Bool {
    descendants(of: page.id).contains { changedPageIDs.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 2) {
        if children.isEmpty {
          Color.clear
            .frame(width: 16, height: 16)
        } else {
          Button(action: toggleExpanded) {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .frame(width: 16, height: 16)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(isExpanded ? "Collapse section" : "Expand section")
        }

        KnowledgeTreeRow(
          page: page,
          isSelected: selectedPageID == page.id,
          isChanged: changedPageIDs.contains(page.id),
          containsChangedPage: children.isEmpty ? false : containsChangedPage
        ) {
          selectedPageID = page.id
        }
      }
      .padding(.leading, CGFloat(depth) * 13)
      .frame(maxWidth: .infinity, alignment: .leading)

      if isExpanded {
        ForEach(children) { child in
          KnowledgeTreeBranch(
            page: child,
            pages: pages,
            changedPageIDs: changedPageIDs,
            selectedPageID: $selectedPageID,
            depth: depth + 1
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func toggleExpanded() {
    withAnimation(.easeInOut(duration: 0.12)) {
      isExpanded.toggle()
    }
  }

  private func descendants(of pageID: UUID) -> [KnowledgePage] {
    let directChildren = pages.filter { $0.parentID == pageID }
    return directChildren + directChildren.flatMap { descendants(of: $0.id) }
  }
}

private struct KnowledgeTreeRow: View {
  let page: KnowledgePage
  let isSelected: Bool
  let isChanged: Bool
  let containsChangedPage: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: page.kind == .section ? "folder" : "doc.text")
          .foregroundStyle(
            page.verificationStatus == .stale
              ? Color.orange
              : isChanged || containsChangedPage ? Color.indigo : Color.secondary
          )
          .frame(width: 17)
        Text(page.title)
          .lineLimit(1)
          .fontWeight(isChanged ? .semibold : .regular)
          .foregroundStyle(isChanged ? Color.indigo : Color.primary)
        Spacer()
        if isChanged {
          Circle()
            .fill(.indigo)
            .frame(width: 6, height: 6)
            .help("Updated since you last viewed this page")
        } else if containsChangedPage {
          Circle()
            .stroke(.indigo.opacity(0.8), lineWidth: 1.2)
            .frame(width: 6, height: 6)
            .help("Contains updated pages")
        } else if page.verificationStatus == .proposed {
          Circle()
            .fill(.orange)
            .frame(width: 6, height: 6)
            .help("Proposed; awaiting verification")
        }
      }
      .font(.callout)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        isSelected ? Color.accentColor.opacity(0.13) : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct KnowledgeMetadataRow: View {
  let title: String
  let value: String
  let symbol: String

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 17)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.caption.weight(.semibold))
      }
    }
  }
}
