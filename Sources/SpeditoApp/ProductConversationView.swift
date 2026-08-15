import SpeditoCore
import SwiftUI

struct ProductConversationView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var conversations: ProductConversationFeatureModel
  @State private var selectedThreadID: UUID?
  @State private var selectedRecipientID: UUID?
  @State private var draft = ""
  @State private var isStartingThread = false
  @State private var showingArchived = false
  @State private var visibleNotificationProductID: UUID?
  @State private var visibleNotificationThreadID: UUID?

  private var activeThreads: [ProductConversationThread] {
    conversations.threads.filter { !$0.isArchived }
  }

  private var archivedThreads: [ProductConversationThread] {
    conversations.threads.filter(\.isArchived)
  }

  private var selectedThread: ProductConversationThread? {
    conversations.threads.first { $0.id == selectedThreadID }
  }

  private var selectedRecipient: AgentProfile? {
    let recipientID = selectedRecipientID ?? selectedThread?.recipientProfileID
    return model.profiles.first { $0.id == recipientID }
  }

  private var messages: [ProductConversationMessage] {
    guard let selectedThreadID else { return [] }
    return conversations.messagesByThread[selectedThreadID] ?? []
  }

  private var isSelectedThreadResponding: Bool {
    guard let selectedThreadID else { return false }
    return conversations.respondingThreadIDs.contains(selectedThreadID)
  }

  private var archiveThreadTitle: AttributedString {
    var title = AttributedString("Archive thread")
    title.foregroundColor = .red
    return title
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Chat")
          .font(.largeTitle.bold())
        Text("Ask your team about the product, delivery, and what needs your attention.")
          .foregroundStyle(.secondary)
      }
      .workspaceHeaderLayout()

      Divider()

      HSplitView {
        threadList
          .frame(idealWidth: 290, maxWidth: 360)
          .frame(maxHeight: .infinity)

        VStack(spacing: 0) {
          conversationHeader
          Divider()
          conversationTimeline
          Divider()
          conversationStatus
          if selectedThread?.isArchived == true {
            archivedThreadFooter
          } else {
            composer
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      if let focusedThreadID = model.conversationFocusThreadID,
        activeThreads.contains(where: { $0.id == focusedThreadID })
      {
        selectedThreadID = focusedThreadID
        model.conversationFocusThreadID = nil
      } else if selectedThreadID == nil, let firstThread = activeThreads.first {
        selectedThreadID = firstThread.id
        selectedRecipientID = firstThread.recipientProfileID
      } else {
        synchronizeRecipientWithSelection()
      }
    }
    .onChange(of: model.selectedProductID) { _, _ in
      clearVisibleNotificationTarget()
      selectedThreadID = activeThreads.first?.id
      selectedRecipientID = nil
      draft = ""
      showingArchived = false
      synchronizeRecipientWithSelection()
    }
    .onChange(of: conversations.threads) { _, threads in
      let active = threads.filter { !$0.isArchived }
      if isStartingThread, let newest = active.first {
        selectedThreadID = newest.id
        isStartingThread = false
      } else if let selectedThreadID,
        !threads.contains(where: { thread in
          thread.id == selectedThreadID
            && (showingArchived || !thread.isArchived)
        })
      {
        self.selectedThreadID = active.first?.id
      }
    }
    .onChange(of: showingArchived) { _, isShowingArchived in
      if !isShowingArchived, selectedThread?.isArchived == true {
        selectedThreadID = activeThreads.first?.id
      }
    }
    .onChange(of: selectedThreadID) { _, _ in
      clearVisibleNotificationTarget()
      synchronizeRecipientWithSelection()
    }
    .onChange(of: model.conversationFocusThreadID) { _, threadID in
      guard
        let threadID,
        activeThreads.contains(where: { $0.id == threadID })
      else { return }
      selectedThreadID = threadID
      model.conversationFocusThreadID = nil
    }
    .task(id: selectedThreadID) {
      guard
        let selectedThreadID,
        let productID = model.selectedProductID
      else { return }
      visibleNotificationProductID = productID
      visibleNotificationThreadID = selectedThreadID
      await model.setOwnerNotificationTargetVisible(
        productID: productID,
        target: OwnerNotificationTarget(
          kind: .conversationThread,
          id: selectedThreadID
        )
      )
      await model.loadProductConversationMessages(threadID: selectedThreadID)
    }
    .onDisappear {
      clearVisibleNotificationTarget()
    }
  }

  private var threadList: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Threads")
          .font(.headline)
        Spacer()
        Button {
          selectedThreadID = nil
          selectedRecipientID = nil
          draft = ""
          chooseDefaultRecipient()
        } label: {
          Label("New chat", systemImage: "square.and.pencil")
        }
        .help("Start a new chat thread")
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        if !archivedThreads.isEmpty {
          Button {
            showingArchived.toggle()
          } label: {
            Label(
              showingArchived ? "Hide archived threads" : "Show archived threads",
              systemImage: showingArchived ? "archivebox.fill" : "archivebox"
            )
            .labelStyle(.iconOnly)
          }
          .help(showingArchived ? "Hide archived threads" : "Show archived threads")
        }
      }
      .padding(.horizontal, 14)
      .frame(height: 48)

      Divider()

      if !activeThreads.isEmpty || (showingArchived && !archivedThreads.isEmpty) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(activeThreads) { thread in
              threadButton(thread)
            }

            if showingArchived, !archivedThreads.isEmpty {
              Text("Archived")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, activeThreads.isEmpty ? 3 : 12)
                .padding(.bottom, 3)

              ForEach(archivedThreads) { thread in
                threadButton(thread)
              }
            }
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
  }

  @ViewBuilder
  private var conversationHeader: some View {
    HStack(spacing: 10) {
      if let thread = selectedThread {
        VStack(alignment: .leading, spacing: 2) {
          Text(thread.subject)
            .font(.headline)
            .lineLimit(1)
          Text("Thread with \(selectedRecipient?.name ?? "team member")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          if thread.isArchived {
            Button("Restore thread", systemImage: "arrow.uturn.backward") {
              restore(thread)
            }
          } else {
            Button(role: .destructive) {
              archive(thread)
            } label: {
              Label {
                Text(archiveThreadTitle)
              } icon: {
                Image(systemName: "archivebox")
                  .foregroundStyle(.red)
              }
            }
            .tint(.red)
            .disabled(conversations.respondingThreadIDs.contains(thread.id))
          }
        } label: {
          Label("Thread actions", systemImage: "ellipsis")
            .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Thread actions")
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text("New thread")
            .font(.headline)
          Text("New threads can run independently.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 48)
  }

  private var conversationTimeline: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if selectedThread != nil {
            ForEach(messages) { message in
              ProductConversationMessageRow(message: message)
            }
          }
          Color.clear
            .frame(height: 1)
            .padding(.bottom, 14)
            .id("product-conversation-bottom")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
      }
      .defaultScrollAnchor(.bottom)
      .overlay {
        if selectedThread == nil {
          ConversationEmptyState(
            detail:
              "Ask about tickets, product knowledge, delivery history, retrospectives, or Git."
          )
        }
      }
      .onChange(of: messages.count) { _, _ in
        Task { @MainActor in
          await Task.yield()
          withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("product-conversation-bottom", anchor: .bottom)
          }
        }
      }
      .onAppear {
        proxy.scrollTo("product-conversation-bottom", anchor: .bottom)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var conversationStatus: some View {
    if let thread = selectedThread, isSelectedThreadResponding {
      ConversationRespondingStatus(
        profile: selectedRecipient,
        fallbackName: "Team member",
        status: "is thinking…",
        activity: conversations.activities[thread.id],
        onStop: {
          model.cancelProductConversation(threadID: thread.id)
        }
      )
    } else if let thread = selectedThread,
      let error = conversations.errorsByThread[thread.id]
    {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text(error)
          .font(.caption)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 38)
      .background(Color.orange.opacity(0.075))
    }
  }

  private var archivedThreadFooter: some View {
    HStack(spacing: 8) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
      Text("This thread is archived.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if let thread = selectedThread {
        Button("Restore thread") {
          restore(thread)
        }
      }
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 48)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
  }

  private var composer: some View {
    TeamConversationComposer(
      profiles: model.profiles,
      recipientID: recipientBinding,
      message: $draft,
      isSending: isStartingThread && selectedThread == nil,
      isResponding: isSelectedThreadResponding,
      sendError: nil,
      onSend: send
    )
  }

  private func threadButton(_ thread: ProductConversationThread) -> some View {
    Button {
      selectedThreadID = thread.id
    } label: {
      ConversationThreadRow(
        thread: thread,
        recipient: model.profiles.first {
          $0.id == thread.recipientProfileID
        },
        isResponding: conversations.respondingThreadIDs.contains(thread.id),
        isSelected: selectedThreadID == thread.id,
        hasUnreadReply: model.ownerNotificationKind(
          productID: thread.productID,
          target: OwnerNotificationTarget(
            kind: .conversationThread,
            id: thread.id
          )
        ) == .newReply
      )
    }
    .buttonStyle(.plain)
    .contextMenu {
      if thread.isArchived {
        Button("Restore thread", systemImage: "arrow.uturn.backward") {
          restore(thread)
        }
      } else {
        Button(role: .destructive) {
          archive(thread)
        } label: {
          Label {
            Text(archiveThreadTitle)
          } icon: {
            Image(systemName: "archivebox")
              .foregroundStyle(.red)
          }
        }
        .tint(.red)
        .disabled(conversations.respondingThreadIDs.contains(thread.id))
      }
    }
  }

  private func clearVisibleNotificationTarget() {
    guard
      let productID = visibleNotificationProductID,
      let threadID = visibleNotificationThreadID
    else { return }
    model.clearOwnerNotificationTargetVisible(
      productID: productID,
      target: OwnerNotificationTarget(kind: .conversationThread, id: threadID)
    )
    visibleNotificationProductID = nil
    visibleNotificationThreadID = nil
  }

  private var recipientBinding: Binding<UUID?> {
    Binding(
      get: { selectedRecipientID ?? selectedThread?.recipientProfileID },
      set: { selectedRecipientID = $0 }
    )
  }

  private func synchronizeRecipientWithSelection() {
    if let selectedThread {
      selectedRecipientID = selectedThread.recipientProfileID
    } else {
      selectedRecipientID = nil
      chooseDefaultRecipient()
    }
  }

  private func chooseDefaultRecipient() {
    guard selectedRecipientID == nil else { return }
    selectedRecipientID =
      model.profiles.first(where: { $0.role == .businessAnalyst })?.id
      ?? model.profiles.first(where: { $0.role == .lead })?.id
      ?? model.profiles.first?.id
  }

  private func send() {
    guard let recipientID = selectedRecipient?.id else { return }
    let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }
    let currentThreadID = selectedThreadID
    if currentThreadID == nil {
      isStartingThread = true
    }
    draft = ""
    Task {
      let resultingThreadID = await model.sendProductConversationMessage(
        threadID: currentThreadID,
        recipientID: recipientID,
        body: message
      )
      if let resultingThreadID {
        selectedThreadID = resultingThreadID
      } else if currentThreadID == nil {
        isStartingThread = false
        draft = message
      }
    }
  }

  private func archive(_ thread: ProductConversationThread) {
    Task {
      guard await model.archiveProductConversation(threadID: thread.id) else {
        return
      }
      if !showingArchived, selectedThreadID == thread.id {
        selectedThreadID = activeThreads.first?.id
      }
    }
  }

  private func restore(_ thread: ProductConversationThread) {
    Task {
      guard await model.restoreProductConversation(threadID: thread.id) else {
        return
      }
      selectedThreadID = thread.id
    }
  }
}

private struct ConversationThreadRow: View {
  let thread: ProductConversationThread
  let recipient: AgentProfile?
  let isResponding: Bool
  let isSelected: Bool
  let hasUnreadReply: Bool
  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(thread.subject)
          .font(.callout.weight(.medium))
          .lineLimit(2)
        Spacer(minLength: 4)
        if hasUnreadReply {
          Circle()
            .fill(Color.purple)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Unread reply")
        }
        if isResponding {
          ProgressView()
            .controlSize(.mini)
        }
      }
      HStack(spacing: 5) {
        Text(recipient?.name ?? "Team member")
        Text("·")
        Text(thread.updatedAt.formatted(date: .omitted, time: .shortened))
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.1)
        : (isHovering ? Color.primary.opacity(0.045) : Color.clear),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .contentShape(RoundedRectangle(cornerRadius: 7))
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
  }
}

private struct ProductConversationMessageRow: View {
  @EnvironmentObject private var model: AppModel
  let message: ProductConversationMessage

  var body: some View {
    TeamConversationMessageBubble(
      authorKind: message.authorKind,
      authorName: message.authorName,
      body: message.body,
      createdAt: message.createdAt,
      authorProfile: model.profiles.first { $0.name == message.authorName }
    )
  }
}

struct CircularProgressRing: View {
  let fraction: Double
  let tint: Color
  var size: CGFloat = 12
  var lineWidth: CGFloat = 2.5

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: min(1, max(0, fraction)))
        .stroke(
          tint,
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
    }
    .frame(width: size, height: size)
  }
}
