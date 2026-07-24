import Foundation
import Testing

@testable import StoryPointlessCore

@Suite("Codex App Server adapter", .serialized)
struct CodexAdapterTests {
  @Test("Client performs the required initialize handshake in order")
  func initializeHandshake() async throws {
    let transport = RecordingTransport(
      initializeResponse: .object([
        "userAgent": .string("codex-cli/0.144.0-alpha.4"),
        "codexHome": .string("/private/tmp/storypointless-codex-home"),
        "platformFamily": .string("unix"),
        "platformOs": .string("macos"),
      ])
    )
    let client = CodexAppServerClient(transport: transport)

    let info = try await client.connect()
    let calls = await transport.recordedCalls()

    #expect(info.platformOS == "macos")
    #expect(info.userAgent == "codex-cli/0.144.0-alpha.4")
    #expect(calls.map(\.kind) == [.start, .request, .notification])
    #expect(calls[1].method == "initialize")
    #expect(calls[1].params?["clientInfo"]?["name"]?.stringValue == "storypointless")
    #expect(calls[2].method == "initialized")

    await client.disconnect()
    #expect(await transport.wasStopped())
  }

  @Test("Client rejects a non-macOS runtime and closes the transport")
  func unsupportedPlatformFailsClosed() async {
    let transport = RecordingTransport(
      initializeResponse: .object([
        "userAgent": .string("codex-cli/test"),
        "codexHome": .string("/tmp/codex"),
        "platformFamily": .string("unix"),
        "platformOs": .string("linux"),
      ])
    )
    let client = CodexAppServerClient(transport: transport)

    await #expect(throws: CodexClientError.unsupportedPlatform("linux")) {
      _ = try await client.connect()
    }
    #expect(await transport.wasStopped())
  }

  @Test("JSONL transport correlates a response with its request")
  func jsonlRoundTrip() async throws {
    let script = #"""
      IFS= read -r request
      printf '%s\n' '{"id":1,"result":{"ready":true}}'
      IFS= read -r notification
      """#
    let transport = CodexJSONLTransport(
      configuration: .init(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        requestTimeout: .seconds(2)
      )
    )

    try await transport.start()
    let response = try await transport.request(method: "initialize", params: .object([:]))
    #expect(response["ready"] == .bool(true))
    try await transport.notify(method: "initialized", params: .object([:]))
    await transport.stop()
  }

  @Test("Pinned runtime version output is parsed without depending on a system install")
  func runtimeVersionParsing() {
    let resolver = CodexRuntimeResolver()
    #expect(resolver.parseVersionOutput("codex-cli 0.144.0-alpha.4\n") == "0.144.0-alpha.4")
    #expect(resolver.parseVersionOutput("\n") == nil)
  }

  @Test("JSON values preserve integer request identifiers")
  func jsonValueRoundTrip() throws {
    let original = JSONValue.object([
      "id": .integer(42),
      "params": .array([.string("hello"), .bool(true), .null]),
    ])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == original)
    #expect(decoded["id"]?.integerValue == 42)
  }

  @Test("Missing persisted Codex threads are identifiable for workspace recovery")
  func missingThreadRecoverySignal() {
    #expect(
      CodexRPCError(
        code: -32600,
        message: "thread not found: 019f8f3f-5c53-78c3-a8d3-6d93c733d074"
      ).isThreadNotFound
    )
    #expect(!CodexRPCError(code: -32600, message: "invalid request").isThreadNotFound)
    #expect(!CodexRPCError(code: -32601, message: "thread not found").isThreadNotFound)
  }

  @Test("Structured suggestion turns are read-only and return their final message")
  func structuredSuggestionTurn() async throws {
    let transport = SuggestionTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let threadID = try await client.startReadOnlyThread(
      workingDirectory: URL(fileURLWithPath: "/private/tmp/storypointless-product"),
      developerInstructions: "Act as a BA"
    )
    let turnID = try await client.startStructuredTurn(
      threadID: threadID,
      prompt: "Suggest tickets",
      effort: "medium",
      outputSchema: CodexTicketSuggestionGenerator.outputSchema
    )
    let final = try await client.waitForFinalAgentMessage(threadID: threadID, turnID: turnID)
    let requests = await transport.requests()

    #expect(threadID == "thread-1")
    #expect(turnID == "turn-1")
    #expect(final == #"{"suggestions":[]}"#)
    #expect(requests.map(\.method) == ["initialize", "thread/start", "turn/start"])
    #expect(requests[1].params["sandbox"]?.stringValue == "read-only")
    #expect(requests[1].params["approvalPolicy"]?.stringValue == "never")
    #expect(requests[2].params["outputSchema"] != nil)
    #expect(requests[2].params["summary"]?.stringValue == "concise")
  }

  @Test("Live activity uses concise summaries and action categories, not raw reasoning")
  func liveActivitySummaries() {
    var accumulator = CodexLiveActivityAccumulator()
    let params: [String: JSONValue] = [
      "threadId": .string("thread-1"),
      "turnId": .string("turn-1"),
      "itemId": .string("item-1"),
    ]

    #expect(
      accumulator.consume(
        CodexNotification(
          method: "item/reasoning/textDelta",
          params: .object(params.merging(["delta": .string("private reasoning")]) { _, new in new })
        )
      ) == nil
    )

    let summary = accumulator.consume(
      CodexNotification(
        method: "item/reasoning/summaryTextDelta",
        params: .object(
          params.merging(["delta": .string("**Inspecting provider evidence**")]) { _, new in new }
        )
      )
    )
    #expect(
      summary == .activity(
        CodexLiveActivity(text: "Inspecting provider evidence", kind: .thinking)
      )
    )
    #expect(
      accumulator.consume(
        CodexNotification(
          method: "item/reasoning/summaryTextDelta",
          params: .object(
            params.merging(["delta": .string(" as")]) { _, new in new }
          )
        )
      ) == nil
    )

    let adjacentSummary = accumulator.consume(
      CodexNotification(
        method: "item/reasoning/summaryTextDelta",
        params: .object(
          params.merging(["delta": .string("**Preparing the prototype artefact**")]) {
            _, new in new
          }
        )
      )
    )
    #expect(
      adjacentSummary == .activity(
        CodexLiveActivity(
          text: "Preparing the prototype artefact",
          kind: .thinking
        )
      )
    )

    let fileChange = accumulator.consume(
      CodexNotification(
        method: "item/started",
        params: .object(
          params.merging([
            "item": .object([
              "id": .string("change-1"),
              "type": .string("fileChange"),
            ])
          ]) { _, new in new }
        )
      )
    )
    #expect(
      fileChange == .activity(
        CodexLiveActivity(text: "Updating project files…", kind: .changingFiles)
      )
    )

    #expect(
      accumulator.consume(
        CodexNotification(method: "turn/completed", params: .object(params))
      ) == .turnFinished
    )
  }

  @Test("Execution threads are workspace-write and never hide approval prompts")
  func workspaceExecutionThread() async throws {
    let transport = SuggestionTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let threadID = try await client.startWorkspaceThread(
      workingDirectory: URL(fileURLWithPath: "/private/tmp/storypointless-product"),
      developerInstructions: "Execute one ticket",
      model: "gpt-5.6-terra"
    )
    let requests = await transport.requests()

    #expect(threadID == "thread-1")
    #expect(requests.map(\.method) == ["initialize", "thread/start"])
    #expect(requests[1].params["sandbox"]?.stringValue == "workspace-write")
    #expect(requests[1].params["approvalPolicy"]?.stringValue == "never")
    #expect(requests[1].params["model"]?.stringValue == "gpt-5.6-terra")
  }

  @Test("A hung turn times out and is interrupted")
  func hungTurnIsInterrupted() async throws {
    let transport = HangingTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    await #expect(throws: CodexClientError.turnTimedOut(seconds: 1)) {
      _ = try await client.waitForFinalAgentMessage(
        threadID: "thread-hung",
        turnID: "turn-hung",
        timeout: .milliseconds(20)
      )
    }
    let requests = await transport.requests()
    #expect(
      requests.map(\.method)
        == ["initialize", "thread/read", "thread/read", "turn/interrupt"]
    )
    #expect(requests.last?.params["threadId"]?.stringValue == "thread-hung")
    #expect(requests.last?.params["turnId"]?.stringValue == "turn-hung")
  }

  @Test("A missed completion notification is recovered from durable thread state")
  func missedCompletionIsReconciled() async throws {
    let transport = ReconciledTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let final = try await client.waitForFinalAgentMessage(
      threadID: "thread-recovered",
      turnID: "turn-recovered",
      timeout: .seconds(1),
      reconciliationInterval: .milliseconds(5)
    )

    #expect(final == #"{"message":"Recovered durable result"}"#)
    #expect(await transport.requests().contains("thread/read"))
  }

  @Test("The latest current turn is recovered when the server reports a different turn id")
  func latestCurrentTurnIsReconciled() async throws {
    let transport = LatestTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let final = try await client.waitForFinalAgentMessage(
      threadID: "thread-current",
      turnID: "client-turn-id",
      timeout: .seconds(1),
      reconciliationInterval: .milliseconds(5)
    )

    #expect(final == #"{"message":"Recovered latest result"}"#)
  }

  @Test("A completed turn recovers the final agent message from its item snapshot")
  func completedTurnRecoversFinalMessage() async throws {
    let transport = CompletedTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let final = try await client.waitForFinalAgentMessage(
      threadID: "thread-complete",
      turnID: "turn-complete"
    )

    #expect(final == #"{"message":"Ready to refine.","proposal":null}"#)
  }

  @Test("Concurrent turn waiters each receive the matching final message")
  func concurrentTurnWaitersAreRoutedIndependently() async throws {
    let transport = ConcurrentTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    async let first = client.waitForFinalAgentMessage(
      threadID: "thread-1",
      turnID: "turn-1"
    )
    async let second = client.waitForFinalAgentMessage(
      threadID: "thread-2",
      turnID: "turn-2"
    )

    await transport.complete(
      threadID: "thread-2",
      turnID: "turn-2",
      text: #"{"ticket":"second"}"#
    )
    await transport.complete(
      threadID: "thread-1",
      turnID: "turn-1",
      text: #"{"ticket":"first"}"#
    )

    let responses = try await (first, second)
    #expect(responses.0 == #"{"ticket":"first"}"#)
    #expect(responses.1 == #"{"ticket":"second"}"#)
  }

  @Test("Suggestion decoder validates roles and dependency references")
  func suggestionDecoding() throws {
    let response = #"""
      {"suggestions":[
        {"reference":"T1","title":"Choose provider","type":"task","body":"Compare options","acceptanceCriteria":["Trade-offs are clear"],"role":"business_analyst","priority":"high","rationale":"Defines the contract","dependsOn":[]},
        {"reference":"T2","title":"Prototype","type":"task","body":"Design states","acceptanceCriteria":["Owner can review"],"role":"ux_designer","priority":"high","rationale":"Validates the experience","dependsOn":[]},
        {"reference":"T3","title":"Build UI","type":"story","body":"Implement it","acceptanceCriteria":["Forecast is visible"],"role":"implementer","priority":"normal","rationale":"Creates value","dependsOn":["T1","T2"]}
      ]}
      """#
    let suggestions = try CodexTicketSuggestionGenerator.decode(response)
    #expect(suggestions.count == 3)
    #expect(suggestions.map(\.type) == [.task, .task, .story])
    #expect(suggestions[2].suggestedRole == .implementer)
    #expect(suggestions[2].dependsOnReferences == ["T1", "T2"])

    let looselyFormatted = #"""
      {"suggestions":[
        {"reference":" t-1 ","title":"Choose provider","type":"task","body":"Compare options","acceptanceCriteria":["Trade-offs are clear"],"role":"business_analyst","priority":"high","rationale":"Defines the contract","dependsOn":[]},
        {"reference":"T 2","title":"Build UI","type":"story","body":"Implement it","acceptanceCriteria":["Forecast is visible"],"role":"implementer","priority":"normal","rationale":"Creates value","dependsOn":["T-1"]}
      ]}
      """#
    let normalized = try CodexTicketSuggestionGenerator.decode(looselyFormatted)
    #expect(normalized.map(\.reference) == ["T1", "T2"])
    #expect(normalized[1].dependsOnReferences == ["T1"])

    let minimal = #"{"suggestions":[{"reference":"T1","title":"Ship one bounded outcome","type":"story","body":"Keep the scope coherent","acceptanceCriteria":["The outcome is visible"],"role":"implementer","priority":"normal","rationale":"The product is deliberately small","dependsOn":[]}]}"#
    #expect(try CodexTicketSuggestionGenerator.decode(minimal).count == 1)

    let cyclic = #"{"suggestions":[{"reference":"T1","title":"First","type":"task","body":"First","acceptanceCriteria":["Done"],"role":"implementer","priority":"normal","rationale":"First","dependsOn":["T2"]},{"reference":"T2","title":"Second","type":"task","body":"Second","acceptanceCriteria":["Done"],"role":"implementer","priority":"normal","rationale":"Second","dependsOn":["T1"]}]}"#
    #expect(throws: TicketSuggestionGenerationError.self) {
      try CodexTicketSuggestionGenerator.decode(cyclic)
    }

    let existing = WorkItem(productID: UUID(), key: "T-7", title: "Existing work")
    let crossLinked = #"""
      {"suggestions":[
        {"reference":"T1","title":"Add the missing integration","type":"story","body":"Use the existing contract","acceptanceCriteria":["The integration works"],"role":"implementer","priority":"normal","rationale":"Completes the flow","dependsOn":["T-7"]}
      ]}
      """#
    let crossLinkedSuggestions = try CodexTicketSuggestionGenerator.decode(
      crossLinked,
      existingItems: [existing]
    )
    #expect(crossLinkedSuggestions[0].dependsOnReferences.isEmpty)
    #expect(crossLinkedSuggestions[0].dependsOnExistingWorkItemKeys == ["T-7"])

    let repair = CodexTicketSuggestionGenerator.repairPrompt(
      validationError: "Unknown dependency T-7.",
      existingItems: [existing]
    )
    #expect(repair.contains("Unknown dependency T-7."))
    #expect(repair.contains("T-7"))
    #expect(repair.contains("active backlog keys"))
  }

  @Test("Model catalog exposes only server-advertised efforts")
  func modelCatalog() async throws {
    let transport = SuggestionTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    let models = try await client.listModels()

    #expect(models.count == 1)
    #expect(models[0].model == "gpt-5.6-sol")
    #expect(models[0].displayName == "Sol")
    #expect(models[0].supportedReasoningEfforts.map(\.id) == ["medium", "high"])
  }

  @Test("Epic planning decodes durable outcome metadata and ticket relationships")
  func epicPlanningDecoding() throws {
    let response = #"""
      {
        "epic": {
          "title": "Saved locations",
          "goal": "Customers can return to important forecasts without searching again.",
          "successCriteria": ["A saved location can be opened again"],
          "constraints": "Keep saved data on the device."
        },
        "suggestions": [
          {
            "reference": "T1",
            "title": "Design saved-location states",
            "type": "task",
            "body": "Define empty, saved, and removed states.",
            "acceptanceCriteria": ["The Product Owner can review every state"],
            "role": "ux_designer",
            "priority": "high",
            "rationale": "The interaction needs an agreed direction.",
            "dependsOn": []
          },
          {
            "reference": "T2",
            "title": "Save and reopen a location",
            "type": "story",
            "body": "Implement the approved saved-location experience.",
            "acceptanceCriteria": ["A saved location can be opened again"],
            "role": "implementer",
            "priority": "normal",
            "rationale": "This delivers the customer outcome.",
            "dependsOn": ["T1"]
          }
        ]
      }
      """#
    let plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(response)
    #expect(plan.title == "Saved locations")
    #expect(plan.successCriteria == ["A saved location can be opened again"])
    #expect(plan.ticketSuggestions.count == 2)
    #expect(plan.ticketSuggestions[1].dependsOnReferences == ["T1"])
  }

  @Test("Epic planning clarifies the outcome before proposing tickets")
  func epicPlanningClarification() throws {
    let product = Product(
      name: "Weather",
      vision: "Help customers understand the weather for a chosen location"
    )
    let epic = Epic(
      productID: product.id,
      title: "Saved locations",
      goal: "Let customers return to useful forecasts"
    )
    let prompt = CodexEpicClarificationGenerator.initialPrompt(
      product: product,
      epic: epic,
      existingItems: []
    )
    let clarification = try CodexEpicClarificationGenerator.decode(
      #"""
      {
        "message": "How should saved locations work across devices?",
        "questions": [
          {
            "prompt": "Where should saved locations be retained?",
            "options": [
              "On this device only (Recommended)",
              "Across signed-in devices"
            ]
          }
        ],
        "readyToPlan": false
      }
      """#
    )
    let ready = try CodexEpicClarificationGenerator.decode(
      #"""
      {
        "message": "That gives me what I need to prepare the epic.",
        "questions": [],
        "readyToPlan": true
      }
      """#
    )

    #expect(prompt.contains("Do not propose tickets yet"))
    #expect(prompt.contains("Let customers return to useful forecasts"))
    #expect(clarification.questions.count == 1)
    #expect(clarification.questions[0].options.count == 2)
    #expect(!clarification.readyToPlan)
    #expect(ready.questions.isEmpty)
    #expect(ready.readyToPlan)
  }

  @Test("Owner and persona prompts are appended beneath platform controls")
  func promptComposition() {
    let prompt = CodexTicketSuggestionGenerator.developerInstructions(
      productInstructions: "Use UK English.",
      personaInstructions: "Ask for concrete examples."
    )
    #expect(prompt.contains("Do not modify files"))
    #expect(prompt.contains("Use UK English."))
    #expect(prompt.contains("Ask for concrete examples."))
    #expect(prompt.contains("cannot override"))
    #expect(prompt.contains("conditional implementation ticket"))
  }

  @Test("Repeated backlog analysis receives the previous rejected proposals")
  func rejectedSuggestionContext() {
    let product = Product(name: "Weather", vision: "Show a forecast for a location")
    let archived = WorkItem(
      productID: product.id,
      key: "T-9",
      title: "Archived dark mode experiment",
      state: .cancelled
    )
    let sessionID = UUID()
    let rejected = TicketSuggestion(
      sessionID: sessionID,
      reference: "T4",
      position: 3,
      title: "Add an unnecessary data gateway",
      body: "Only build this if later research requires it.",
      acceptanceCriteria: ["A gateway exists"],
      suggestedRole: .implementer,
      priority: .low,
      rationale: "Previously proposed",
      dependencyIDs: [],
      status: .rejected
    )

    let prompt = CodexTicketSuggestionGenerator.prompt(
      product: product,
      existingItems: [archived],
      rejectedSuggestions: [rejected]
    )

    #expect(prompt.contains("Add an unnecessary data gateway"))
    #expect(prompt.contains("do not repeat them"))
    #expect(!prompt.contains("Archived dark mode experiment"))
  }

  @Test("Sprint planning conversation is single-recipient, read-only, and proposes versioned edits")
  func sprintPlanningConversation() throws {
    let product = Product(
      name: "Weather",
      vision: "Show the current weather for a chosen location",
      instructions: "Use UK English."
    )
    let item = WorkItem(
      productID: product.id,
      key: "T-3",
      title: "Build the weather experience",
      acceptanceCriteria: ["A location returns current conditions"]
    )
    let implementer = AgentProfile(
      productID: product.id,
      name: "Implementer",
      role: .implementer,
      model: "gpt-5.6-terra",
      reasoningEffort: "low"
    )
    let lead = AgentProfile(
      productID: product.id,
      name: "Tech Lead",
      role: .lead,
      model: "gpt-5.6-sol",
      reasoningEffort: "high"
    )
    let instructions = CodexSprintPlanningConversation.developerInstructions(
      productInstructions: product.instructions,
      personaInstructions: "Challenge unclear delivery assumptions.",
      recipient: lead
    )
    let snapshot = SprintPlanningTicketSnapshot(
      version: item.version,
      title: item.title,
      type: item.type,
      body: item.body,
      acceptanceCriteria: item.acceptanceCriteria,
      priority: item.priority
    )
    let prompt = CodexSprintPlanningConversation.prompt(
      product: product,
      itemKey: item.key,
      snapshot: snapshot,
      prerequisites: [],
      sprintItems: [item],
      proposedAssignee: implementer,
      previousComments: [],
      ownerMessage: "Can you make the acceptance criteria more testable?"
    )
    let reply = try CodexSprintPlanningConversation.decode(
      #"{"message":"I suggest making the visible result explicit.","proposal":{"baseVersion":1,"title":"Build the weather experience","type":"story","body":"","acceptanceCriteria":["Selecting a valid location displays current conditions"],"priority":"normal","rationale":"This is directly observable."}}"#
    )

    #expect(instructions.contains("single team member"))
    #expect(instructions.contains("Tech Lead — Tech Lead"))
    #expect(instructions.contains("do not modify files"))
    #expect(instructions.contains("live, ticket-scoped"))
    #expect(instructions.contains("one to four"))
    #expect(instructions.contains("ask at most"))
    #expect(instructions.contains("one focused question"))
    #expect(instructions.contains("Use UK English."))
    #expect(prompt.contains("T-3"))
    #expect(prompt.contains("Implementer (Implementer, gpt-5.6-terra, low effort)"))
    #expect(prompt.contains("Can you make the acceptance criteria more testable?"))
    #expect(reply.proposal?.baseVersion == 1)
    #expect(reply.proposal?.acceptanceCriteria.count == 1)
    #expect(reply.ticketCommentBody.contains("Proposed ticket changes"))
  }

  @Test("A visible ticket draft can be used for chat without discarding saved metadata")
  func ticketDraftConversationContext() {
    let productID = UUID()
    let item = WorkItem(
      productID: productID,
      key: "T-7",
      title: "Saved title",
      body: "Saved context",
      acceptanceCriteria: ["Saved criterion"],
      priority: .normal,
      rank: 4,
      customFields: ["Area": "Customer experience"],
      version: 3
    )
    let draft = SprintPlanningTicketSnapshot(
      version: item.version,
      title: "Accepted AI title",
      type: .story,
      body: "Accepted AI context",
      acceptanceCriteria: ["Accepted AI criterion"],
      priority: .high
    )

    let conversationItem = draft.applying(to: item)

    #expect(conversationItem.title == "Accepted AI title")
    #expect(conversationItem.body == "Accepted AI context")
    #expect(conversationItem.acceptanceCriteria == ["Accepted AI criterion"])
    #expect(conversationItem.priority == .high)
    #expect(conversationItem.id == item.id)
    #expect(conversationItem.productID == productID)
    #expect(conversationItem.key == "T-7")
    #expect(conversationItem.rank == 4)
    #expect(conversationItem.customFields == ["Area": "Customer experience"])
    #expect(conversationItem.version == 3)
  }

  @Test("Ticket refinement is read-only, versioned, and validates related ticket keys")
  func ticketRefinement() throws {
    let product = Product(
      name: "Weather",
      vision: "Show weather for a location",
      instructions: "Use UK English."
    )
    let item = WorkItem(
      productID: product.id,
      key: "T-2",
      title: "Weather search"
    )
    let prerequisite = WorkItem(
      productID: product.id,
      key: "T-1",
      title: "Choose a weather data provider",
      type: .task
    )
    let archived = WorkItem(
      productID: product.id,
      key: "T-9",
      title: "Archived dark mode experiment",
      state: .cancelled
    )
    let instructions = CodexTicketRefinementGenerator.developerInstructions(
      productInstructions: product.instructions,
      personaInstructions: "Keep the Product Owner in control."
    )
    let prompt = CodexTicketRefinementGenerator.prompt(
      product: product,
      item: item,
      existingItems: [prerequisite, archived, item],
      dependencies: [],
      conversation: [
        TicketComment(
          workItemID: item.id,
          authorKind: .owner,
          authorName: "Me",
          body: "@Business Analyst Customers should confirm ambiguous locations."
        )
      ]
    )
    let reply = try CodexTicketRefinementGenerator.decode(
      """
      {
        "message": "I found one prerequisite and made the outcome testable.",
        "proposal": {
          "baseVersion": 1,
          "title": "Search for a location and show its current weather",
          "type": "story",
          "body": "Let a customer resolve a location before requesting current conditions.",
          "acceptanceCriteria": ["A valid location displays current conditions"],
          "priority": "normal",
          "rationale": "The revised contract makes the visible outcome explicit.",
          "dependencies": [
            {"ticketKey": "T-1", "reason": "The provider establishes the data contract."}
          ],
          "potentialDuplicates": [],
          "splitRecommendation": null,
          "missingQuestions": []
        }
      }
      """,
      currentItem: item,
      validRelatedItems: [prerequisite, item]
    )

    #expect(instructions.contains("analysis only"))
    #expect(instructions.contains("or apply changes"))
    #expect(instructions.contains("Use UK English."))
    #expect(prompt.contains("exact saved version 1"))
    #expect(prompt.contains("T-1"))
    #expect(!prompt.contains("Archived dark mode experiment"))
    #expect(prompt.contains("Customers should confirm ambiguous locations."))
    #expect(reply.proposal.baseVersion == 1)
    #expect(reply.proposal.dependencies.map(\.ticketKey) == ["T-1"])
    #expect(reply.proposal.missingQuestions.isEmpty)
    #expect(reply.ticketCommentBody == reply.message)

    let clarification = try CodexTicketRefinementGenerator.decode(
      """
      {
        "message": "I need one product decision before proposing changes.",
        "proposal": {
          "baseVersion": 1,
          "title": "A premature changed title",
          "type": "task",
          "body": "Requires Product Owner confirmation.",
          "acceptanceCriteria": ["A premature criterion"],
          "priority": "urgent",
          "rationale": "Wait for the owner.",
          "dependencies": [
            {"ticketKey": "T-1", "reason": "A premature dependency."}
          ],
          "potentialDuplicates": [],
          "splitRecommendation": null,
          "missingQuestions": [
            {
              "prompt": "How should ambiguous locations be handled?",
              "options": [
                "Ask the customer to choose",
                "Use the closest match automatically"
              ]
            }
          ]
        }
      }
      """,
      currentItem: item,
      validRelatedItems: [prerequisite, item]
    )
    #expect(clarification.proposal.title == item.title)
    #expect(clarification.proposal.type == item.type)
    #expect(clarification.proposal.body == item.body)
    #expect(clarification.proposal.acceptanceCriteria == item.acceptanceCriteria)
    #expect(clarification.proposal.priority == item.priority)
    #expect(clarification.proposal.dependencies.isEmpty)
    #expect(clarification.proposal.missingQuestions.first?.options.count == 2)
    #expect(clarification.ticketCommentBody.contains("How should ambiguous locations"))
    #expect(!clarification.ticketCommentBody.contains("I need one product decision"))

    let sparseClarification = try CodexTicketRefinementGenerator.decode(
      """
      {
        "message": "",
        "proposal": {
          "baseVersion": 1,
          "title": "",
          "type": "task",
          "body": "A premature changed context.",
          "acceptanceCriteria": ["A premature criterion"],
          "priority": "urgent",
          "rationale": "",
          "dependencies": [
            {"ticketKey": "T-9", "reason": ""}
          ],
          "potentialDuplicates": [
            {"ticketKey": "T-9", "reason": ""}
          ],
          "splitRecommendation": "Split this ticket.",
          "missingQuestions": [
            {
              "prompt": "How should ambiguous locations be handled?",
              "options": [
                "Ask the customer to choose",
                "Use the closest match automatically"
              ]
            }
          ]
        }
      }
      """,
      currentItem: item,
      validRelatedItems: [prerequisite, archived, item]
    )
    #expect(sparseClarification.message == "I need your input before I can complete this review.")
    #expect(sparseClarification.proposal.title == item.title)
    #expect(sparseClarification.proposal.rationale.contains("Clarification is needed"))
    #expect(sparseClarification.proposal.dependencies.isEmpty)
    #expect(sparseClarification.proposal.potentialDuplicates.isEmpty)
    #expect(sparseClarification.proposal.splitRecommendation == nil)

    let sparseProposal = try CodexTicketRefinementGenerator.decode(
      """
      {
        "message": "",
        "proposal": {
          "baseVersion": 1,
          "title": "",
          "type": "story",
          "body": "Let a customer search for weather.",
          "acceptanceCriteria": ["A search returns a visible result"],
          "priority": "normal",
          "rationale": "",
          "dependencies": [],
          "potentialDuplicates": [],
          "splitRecommendation": null,
          "missingQuestions": []
        }
      }
      """,
      currentItem: item,
      validRelatedItems: [prerequisite, item]
    )
    #expect(sparseProposal.message.contains("prepared the suggested changes"))
    #expect(sparseProposal.proposal.title == item.title)
    #expect(sparseProposal.proposal.rationale.contains("independently verifiable"))

    #expect(throws: TicketRefinementGenerationError.self) {
      _ = try CodexTicketRefinementGenerator.decode(
        """
        {
          "message": "This dependency does not exist.",
          "proposal": {
            "baseVersion": 1,
            "title": "Weather search",
            "type": "story",
            "body": "",
            "acceptanceCriteria": [],
            "priority": "normal",
            "rationale": "Invalid edge.",
            "dependencies": [
              {"ticketKey": "T-9", "reason": "Archived work."}
            ],
            "potentialDuplicates": [],
            "splitRecommendation": null,
            "missingQuestions": []
          }
        }
        """,
        currentItem: item,
        validRelatedItems: [prerequisite, archived, item]
      )
    }
  }

  @Test("Persisted refinement questions retain their clickable options")
  func persistedRefinementQuestions() {
    let reply = TicketRefinementReply(
      message: "",
      proposal: TicketRefinementProposal(
        baseVersion: 1,
        title: "Add a cat joke",
        type: .story,
        body: "",
        acceptanceCriteria: [],
        priority: .normal,
        rationale: "",
        dependencies: [],
        potentialDuplicates: [],
        splitRecommendation: nil,
        missingQuestions: [
          TicketRefinementQuestion(
            prompt: "Where should the cat joke appear?",
            options: [
              "On the main weather screen",
              "On an error or empty state",
              "As a separate optional feature",
            ]
          )
        ]
      )
    )

    #expect(
      TicketRefinementQuestion.parseTicketCommentBody(reply.ticketCommentBody)
        == reply.proposal.missingQuestions
    )
    #expect(
      TicketRefinementQuestion.parseTicketCommentBody(
        """
        The ticket is ready.
        • Context is present
        • Criteria are testable
        """
      ).isEmpty
    )
  }

  @Test("Ordinary ticket chat is concise, single-recipient, and can propose versioned edits")
  func ticketConversation() throws {
    let product = Product(
      name: "Weather",
      vision: "Show weather for a chosen location",
      instructions: "Use UK English."
    )
    let item = WorkItem(
      productID: product.id,
      key: "T-4",
      title: "Support dark mode",
      body: "Follow the approved visual direction."
    )
    let analyst = AgentProfile(
      productID: product.id,
      name: "Business Analyst",
      role: .businessAnalyst,
      model: "gpt-5.6-terra",
      reasoningEffort: "medium"
    )
    let instructions = CodexTicketConversation.developerInstructions(
      productInstructions: product.instructions,
      personaInstructions: analyst.effectiveInstructions,
      recipient: analyst
    )
    let prompt = CodexTicketConversation.prompt(
      product: product,
      item: item,
      prerequisites: [],
      previousComments: [],
      ownerMessage: "Why was this colour chosen?"
    )
    let pausedQuestionPrompt = CodexTicketConversation.prompt(
      product: product,
      item: item,
      prerequisites: [],
      previousComments: [],
      ownerMessage: "What is blocking approval?",
      allowsProposal: false
    )
    let reply = try CodexTicketConversation.decode(
      #"{"message":"The supplied ticket does not record a rationale for that colour. The UX Designer may be the better person to confirm it.","proposal":null}"#,
      currentItem: item
    )
    let proposalReply = try CodexTicketConversation.decode(
      """
      {
        "message": "Blue provides the clearest contrast with the current surface palette, so I suggest recording it.",
        "proposal": {
          "baseVersion": 1,
          "title": "Support dark mode",
          "type": "story",
          "body": "Follow the approved visual direction. Use blue for the primary dark-mode accent.",
          "acceptanceCriteria": ["The primary dark-mode action uses the approved blue accent"],
          "priority": "normal",
          "rationale": "The conversation established a concrete visual choice."
        }
      }
      """,
      currentItem: item
    )

    #expect(instructions.contains("single team member"))
    #expect(instructions.contains("Do not modify files"))
    #expect(instructions.contains("Refine with AI"))
    #expect(instructions.contains("Business Analyst — Business Analyst"))
    #expect(prompt.contains("T-4"))
    #expect(prompt.contains("Why was this colour chosen?"))
    #expect(pausedQuestionPrompt.contains("explanatory question about paused sprint work"))
    #expect(pausedQuestionPrompt.contains("Do not resume implementation"))
    #expect(reply.message.contains("does not record a rationale"))
    #expect(reply.proposal == nil)
    #expect(proposalReply.proposal?.baseVersion == item.version)
    #expect(proposalReply.proposal?.body.contains("blue") == true)
    #expect(proposalReply.ticketCommentBody.contains("No changes were applied automatically"))
    #expect(throws: TicketConversationGenerationError.self) {
      _ = try CodexTicketConversation.decode(
        #"{"message":"  ","proposal":null}"#,
        currentItem: item
      )
    }
  }

  @Test("Common persona templates have stable unique identities")
  func personaTemplates() {
    let templates = PersonaTemplate.common
    #expect(Set(templates.map(\.id)).count == templates.count)
    #expect(templates.contains { $0.name == "Security Auditor" && $0.capability == .reviewer })
    #expect(templates.contains { $0.name == "SEO Expert" })
    #expect(templates.contains { $0.name == "Product Marketing Expert" })
  }

  @Test("Knowledge approval feature flag is opt-in")
  func knowledgeApprovalFeatureFlag() {
    let key = StoryPointlessFeatureFlags.requireKnowledgeApprovalEnvironmentKey
    #expect(
      !StoryPointlessFeatureFlags.requiresKnowledgeApproval(environment: [:])
    )
    #expect(
      StoryPointlessFeatureFlags.requiresKnowledgeApproval(environment: [key: "1"])
    )
    #expect(
      StoryPointlessFeatureFlags.requiresKnowledgeApproval(environment: [key: "true"])
    )
    #expect(
      !StoryPointlessFeatureFlags.requiresKnowledgeApproval(environment: [key: "false"])
    )
  }

  @Test("Ticket execution and Tech Lead review results are validated")
  func ticketExecutionResults() throws {
    let completed = try CodexTicketExecutor.decode(
      #"""
      {
        "status":"completed",
        "comment":"Implemented the location form.",
        "question":null,
        "options":[],
        "summary":"The form validates and submits a location.",
        "changedFiles":["Sources/LocationForm.swift"],
        "tests":["swift test — passed"],
        "knowledgeNotes":["Location input is normalized before lookup."],
        "reviewInstructions":["Open the location form, enter London, and confirm the forecast appears."],
        "retrospectiveWentWell":["The existing form boundary made validation straightforward."],
        "retrospectiveCouldImprove":[],
        "retrospectiveActions":[
          {
            "body":"Confirm the location form checks pass before requesting review.",
            "destination":"team_practice"
          }
        ],
        "knowledgePageProposals":[]
      }
      """#
    )
    #expect(completed.status == .completed)
    #expect(completed.changedFiles == ["Sources/LocationForm.swift"])
    #expect(completed.retrospectiveActions.first?.destination == .teamPractice)
    #expect(completed.workLogComment.contains("Delivery notes"))
    #expect(completed.workLogComment.contains("How to review"))

    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.decode(
        #"""
        {
          "status":"completed",
          "comment":"Implemented the location form.",
          "question":null,
          "options":[],
          "summary":"The form validates and submits a location.",
          "changedFiles":["Sources/LocationForm.swift"],
          "tests":["swift test — passed"],
          "knowledgeNotes":[],
          "reviewInstructions":[],
          "retrospectiveWentWell":[],
          "retrospectiveCouldImprove":[],
          "retrospectiveActions":[],
          "knowledgePageProposals":[]
        }
        """#
      )
    }
    #expect(
      CodexTicketExecutor.repairPrompt(validationError: "No artefact.")
        .contains("Do not merely rewrite the JSON")
    )

    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.decode(
        #"""
        {
          "status":"completed",
          "comment":"I inspected the requirements.",
          "question":null,
          "options":[],
          "summary":"Inspection started.",
          "changedFiles":[],
          "tests":[],
          "knowledgeNotes":[],
          "reviewInstructions":[],
          "retrospectiveWentWell":[],
          "retrospectiveCouldImprove":[],
          "retrospectiveActions":[],
          "knowledgePageProposals":[]
        }
        """#
      )
    }

    let waiting = try CodexTicketExecutor.decode(
      #"""
      {
        "status":"awaiting_owner",
        "comment":"I need the provider choice before continuing.",
        "question":"Which weather provider should I integrate?",
        "options":["Open-Meteo","WeatherKit"],
        "summary":"",
        "changedFiles":[],
        "tests":[],
        "knowledgeNotes":[],
        "reviewInstructions":[],
        "retrospectiveWentWell":[],
        "retrospectiveCouldImprove":[],
        "retrospectiveActions":[],
        "knowledgePageProposals":[]
      }
      """#
    )
    #expect(waiting.status == .awaitingOwner)
    #expect(waiting.options.count == 2)

    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.decode(
        #"{"status":"awaiting_owner","comment":"Need input","question":null,"options":[],"summary":"","changedFiles":[],"tests":[],"knowledgeNotes":[],"reviewInstructions":[],"retrospectiveWentWell":[],"retrospectiveCouldImprove":[],"retrospectiveActions":[],"knowledgePageProposals":[]}"#
      )
    }

    let review = try CodexTechLeadReviewer.decode(
      #"{"decision":"changes_requested","comment":"One issue remains.","findings":["Handle the empty response."],"retrospectiveWentWell":[],"retrospectiveCouldImprove":["The empty response case was missed."],"retrospectiveActions":[]}"#
    )
    #expect(review.decision == .changesRequested)
    #expect(review.workLogComment.contains("Handle the empty response."))

    #expect(throws: TechLeadReviewGenerationError.changesRequestedWithoutFinding) {
      try CodexTechLeadReviewer.decode(
        #"{"decision":"changes_requested","comment":"I cannot approve yet.","findings":[],"retrospectiveWentWell":[],"retrospectiveCouldImprove":[],"retrospectiveActions":[]}"#
      )
    }

    let product = Product(name: "Weather", vision: "Help people inspect the forecast.")
    let analyst = AgentProfile(
      productID: product.id,
      name: "Business Analyst",
      role: .businessAnalyst
    )
    let researchTicket = WorkItem(
      productID: product.id,
      key: "T-1",
      title: "Choose a weather provider",
      type: .task,
      acceptanceCriteria: ["A supported provider is recommended with rationale."]
    )
    let reReviewPrompt = CodexTechLeadReviewer.prompt(
      product: product,
      item: researchTicket,
      implementation: completed,
      assignee: analyst,
      reviewCycle: 1,
      priorReviewFeedback: "Clarify the usage assumption.",
      recentComments: [
        TicketComment(
          workItemID: researchTicket.id,
          authorKind: .owner,
          authorName: "Me",
          body: "Assume a small non-commercial demo."
        )
      ]
    )
    #expect(reReviewPrompt.contains("focused re-review 1"))
    #expect(reReviewPrompt.contains("Business Analyst — Business Analyst"))
    #expect(reReviewPrompt.contains("Assume a small non-commercial demo."))
    #expect(reReviewPrompt.contains("Do not restart a full review"))

    let integration = try CodexConflictIntegrator.decode(
      #"{"status":"awaiting_owner","comment":"The two branches define incompatible defaults.","question":"Which behavior should remain the default?","options":["Use the accepted trunk behavior","Use the ticket behavior"],"summary":"","checks":[]}"#
    )
    #expect(integration.status == .awaitingOwner)
    #expect(integration.workLogComment.contains("Question for you"))
  }
}

private actor ConcurrentTurnTransport: CodexRPCTransport {
  private let stream: AsyncStream<CodexInboundMessage>
  private let continuation: AsyncStream<CodexInboundMessage>.Continuation

  init() {
    let pair = AsyncStream<CodexInboundMessage>.makeStream()
    stream = pair.stream
    continuation = pair.continuation
  }

  func start() {}

  func request(method: String, params: JSONValue) throws -> JSONValue {
    guard method == "initialize" else {
      throw CodexRPCError(code: -32_601, message: "Unexpected request")
    }
    return .object([
      "userAgent": .string("codex-cli/test"),
      "codexHome": .string("/private/tmp/codex"),
      "platformFamily": .string("unix"),
      "platformOs": .string("macos"),
    ])
  }

  func notify(method: String, params: JSONValue) {}
  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() { continuation.finish() }

  func complete(threadID: String, turnID: String, text: String) {
    continuation.yield(
      .notification(
        CodexNotification(
          method: "item/completed",
          params: .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
            "item": .object([
              "id": .string("message-\(turnID)"),
              "type": .string("agentMessage"),
              "text": .string(text),
            ]),
          ])
        )
      )
    )
  }
}

private actor HangingTurnTransport: CodexRPCTransport {
  struct Request: Sendable {
    let method: String
    let params: JSONValue
  }

  private var recorded: [Request] = []
  private let stream: AsyncStream<CodexInboundMessage>
  private let continuation: AsyncStream<CodexInboundMessage>.Continuation

  init() {
    let pair = AsyncStream<CodexInboundMessage>.makeStream()
    stream = pair.stream
    continuation = pair.continuation
  }

  func start() {}

  func request(method: String, params: JSONValue) throws -> JSONValue {
    recorded.append(Request(method: method, params: params))
    switch method {
    case "initialize":
      return .object([
        "userAgent": .string("codex-cli/test"),
        "codexHome": .string("/private/tmp/codex"),
        "platformFamily": .string("unix"),
        "platformOs": .string("macos"),
      ])
    case "turn/interrupt":
      return .object([:])
    default:
      throw CodexRPCError(code: -32_601, message: "Unexpected request")
    }
  }

  func notify(method: String, params: JSONValue) {}
  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() { continuation.finish() }
  func requests() -> [Request] { recorded }
}

private actor SuggestionTransport: CodexRPCTransport {
  struct Request: Sendable {
    let method: String
    let params: JSONValue
  }

  private var recorded: [Request] = []
  private let stream: AsyncStream<CodexInboundMessage>

  init() {
    stream = AsyncStream { continuation in
      continuation.yield(
        .notification(
          CodexNotification(
            method: "item/completed",
            params: .object([
              "threadId": .string("thread-1"),
              "turnId": .string("turn-1"),
              "item": .object([
                "id": .string("item-1"),
                "type": .string("agentMessage"),
                "text": .string(#"{"suggestions":[]}"#),
              ]),
            ])
          )
        )
      )
      continuation.finish()
    }
  }

  func start() {}

  func request(method: String, params: JSONValue) throws -> JSONValue {
    recorded.append(Request(method: method, params: params))
    switch method {
    case "initialize":
      return .object([
        "userAgent": .string("codex-cli/test"),
        "codexHome": .string("/private/tmp/codex"),
        "platformFamily": .string("unix"),
        "platformOs": .string("macos"),
      ])
    case "thread/start":
      return .object(["thread": .object(["id": .string("thread-1")])])
    case "turn/start":
      return .object(["turn": .object(["id": .string("turn-1")])])
    case "model/list":
      return .object([
        "data": .array([
          .object([
            "id": .string("sol"),
            "model": .string("gpt-5.6-sol"),
            "displayName": .string("Sol"),
            "description": .string("Detail and polish"),
            "hidden": .bool(false),
            "isDefault": .bool(true),
            "defaultReasoningEffort": .string("medium"),
            "supportedReasoningEfforts": .array([
              .object([
                "reasoningEffort": .string("medium"),
                "description": .string("Balanced"),
              ]),
              .object([
                "reasoningEffort": .string("high"),
                "description": .string("Deeper reasoning"),
              ]),
            ]),
          ])
        ]),
        "nextCursor": .null,
      ])
    default:
      throw CodexRPCError(code: -32_601, message: "Unexpected request")
    }
  }

  func notify(method: String, params: JSONValue) {}
  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() {}
  func requests() -> [Request] { recorded }
}

private actor CompletedTurnTransport: CodexRPCTransport {
  private let stream: AsyncStream<CodexInboundMessage>

  init() {
    stream = AsyncStream { continuation in
      continuation.yield(
        .notification(
          CodexNotification(
            method: "turn/completed",
            params: .object([
              "threadId": .string("thread-complete"),
              "turn": .object([
                "id": .string("turn-complete"),
                "status": .string("completed"),
                "items": .array([
                  .object([
                    "id": .string("message-complete"),
                    "type": .string("agentMessage"),
                    "text": .string(#"{"message":"Ready to refine.","proposal":null}"#),
                  ])
                ]),
              ]),
            ])
          )
        )
      )
      continuation.finish()
    }
  }

  func start() {}

  func request(method: String, params: JSONValue) throws -> JSONValue {
    guard method == "initialize" else {
      throw CodexRPCError(code: -32_601, message: "Unexpected request")
    }
    return .object([
      "userAgent": .string("codex-cli/test"),
      "codexHome": .string("/private/tmp/codex"),
      "platformFamily": .string("unix"),
      "platformOs": .string("macos"),
    ])
  }

  func notify(method: String, params: JSONValue) {}
  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() {}
}

private actor ReconciledTurnTransport: CodexRPCTransport {
  private var recorded: [String] = []
  private let stream = AsyncStream<CodexInboundMessage> { _ in }

  func start() {}

  func request(method: String, params: JSONValue) throws -> JSONValue {
    recorded.append(method)
    switch method {
    case "initialize":
      return .object([
        "userAgent": .string("codex-cli/test"),
        "codexHome": .string("/private/tmp/codex"),
        "platformFamily": .string("unix"),
        "platformOs": .string("macos"),
      ])
    case "thread/read":
      return .object([
        "thread": .object([
          "id": .string("thread-recovered"),
          "turns": .array([
            .object([
              "id": .string("turn-recovered"),
              "status": .string("completed"),
              "items": .array([
                .object([
                  "id": .string("message-recovered"),
                  "type": .string("agentMessage"),
                  "phase": .string("final_answer"),
                  "text": .string(#"{"message":"Recovered durable result"}"#),
                ])
              ]),
            ])
          ]),
        ])
      ])
    default:
      throw CodexRPCError(code: -32_601, message: "Unexpected request")
    }
  }

  func notify(method: String, params: JSONValue) {}
  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() {}
  func requests() -> [String] { recorded }
}

private actor LatestTurnTransport: CodexRPCTransport {
  private let stream = AsyncStream<CodexInboundMessage> { _ in }

  func start() {}

  func request(method: String, params: JSONValue) throws -> JSONValue {
    switch method {
    case "initialize":
      return .object([
        "userAgent": .string("codex-cli/test"),
        "codexHome": .string("/private/tmp/codex"),
        "platformFamily": .string("unix"),
        "platformOs": .string("macos"),
      ])
    case "thread/read":
      return .object([
        "thread": .object([
          "id": .string("thread-current"),
          "turns": .array([
            .object([
              "id": .string("server-turn-id"),
              "status": .string("completed"),
              "startedAt": .integer(Int64(Date().addingTimeInterval(-10).timeIntervalSince1970)),
              "items": .array([
                .object([
                  "id": .string("message-current"),
                  "type": .string("agentMessage"),
                  "phase": .string("final_answer"),
                  "text": .string(#"{"message":"Recovered latest result"}"#),
                ])
              ]),
            ])
          ]),
        ])
      ])
    default:
      throw CodexRPCError(code: -32_601, message: "Unexpected request")
    }
  }

  func notify(method: String, params: JSONValue) {}
  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() {}
}

private actor RecordingTransport: CodexRPCTransport {
  struct Call: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      case start
      case request
      case notification
    }

    let kind: Kind
    let method: String?
    let params: JSONValue?
  }

  private let initializeResponse: JSONValue
  private let stream: AsyncStream<CodexInboundMessage>
  private var calls: [Call] = []
  private var stopped = false

  init(initializeResponse: JSONValue) {
    self.initializeResponse = initializeResponse
    stream = AsyncStream { continuation in
      continuation.finish()
    }
  }

  func start() {
    calls.append(Call(kind: .start, method: nil, params: nil))
  }

  func request(method: String, params: JSONValue) throws -> JSONValue {
    calls.append(Call(kind: .request, method: method, params: params))
    guard method == "initialize" else {
      throw CodexRPCError(code: -32_601, message: "Unexpected request")
    }
    return initializeResponse
  }

  func notify(method: String, params: JSONValue) {
    calls.append(Call(kind: .notification, method: method, params: params))
  }

  func inboundMessages() -> AsyncStream<CodexInboundMessage> {
    stream
  }

  func stop() {
    stopped = true
  }

  func recordedCalls() -> [Call] {
    calls
  }

  func wasStopped() -> Bool {
    stopped
  }
}
