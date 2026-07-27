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
    #expect(calls[1].params?["capabilities"]?["experimentalApi"]?.boolValue == true)
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
      printf '{"id":1,"result":{"ready":true,"gitLocks":"%s","gitConfig":"%s","gitPager":"%s"}}\n' "$GIT_OPTIONAL_LOCKS" "$GIT_CONFIG_GLOBAL" "$GIT_PAGER"
      IFS= read -r notification
      """#
    let transport = CodexJSONLTransport(
      configuration: .init(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        environmentOverrides: CodexPermissionProfiles.agentProcessEnvironment,
        requestTimeout: .seconds(2)
      )
    )

    try await transport.start()
    let response = try await transport.request(method: "initialize", params: .object([:]))
    #expect(response["ready"] == .bool(true))
    #expect(response["gitLocks"] == .string("0"))
    #expect(response["gitConfig"] == .string("/dev/null"))
    #expect(response["gitPager"] == .string("cat"))
    try await transport.notify(method: "initialized", params: .object([:]))
    await transport.stop()
  }

  @Test("JSONL transport preserves a fragmented response")
  func jsonlFragmentedResponse() async throws {
    let payloadSize = 1_048_576
    let script = #"""
      IFS= read -r request
      printf '{"id":1,"result":{"payload":"'
      head -c 1048576 /dev/zero | tr '\000' x
      printf '","ready":true}}\n'
      """#
    let transport = CodexJSONLTransport(
      configuration: .init(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        requestTimeout: .seconds(5)
      )
    )

    try await transport.start()
    let response = try await transport.request(method: "initialize", params: .object([:]))
    #expect(response["ready"] == .bool(true))
    #expect(response["payload"]?.stringValue?.utf8.count == payloadSize)
    await transport.stop()
  }

  @Test("Pinned runtime version output is parsed without depending on a system install")
  func runtimeVersionParsing() {
    let resolver = CodexRuntimeResolver()
    #expect(resolver.parseVersionOutput("codex-cli 0.144.0-alpha.4\n") == "0.144.0-alpha.4")
    #expect(resolver.parseVersionOutput("\n") == nil)
    #expect(
      resolver.parseEnabledFeatures(
        """
        request_permissions_tool    under development  true
        exec_permission_approvals  under development  false
        """
      ) == ["request_permissions_tool"]
    )
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
    #expect(
      requests[1].params["permissions"]?.stringValue
        == CodexPermissionProfiles.readOnly
    )
    #expect(
      requests[1].params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue)
        == ["/private/tmp/storypointless-product"]
    )
    #expect(requests[1].params["permissionProfile"] == nil)
    #expect(requests[1].params["sandbox"] == nil)
    #expect(requests[1].params["approvalPolicy"]?.stringValue == "never")
    #expect(requests[2].params["approvalPolicy"] == nil)
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

  @Test("Execution turns inherit the thread-scoped delivery profile")
  func workspaceExecutionThread() async throws {
    let transport = SuggestionTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let threadID = try await client.startWorkspaceThread(
      workingDirectory: URL(fileURLWithPath: "/private/tmp/storypointless-product"),
      developerInstructions: "Execute one ticket",
      model: "gpt-5.6-terra",
      readOnlyGitDirectory: URL(
        fileURLWithPath: "/private/tmp/storypointless-canonical-product/.git"
      )
    )
    let turnID = try await client.startStructuredTurn(
      threadID: threadID,
      prompt: "Deliver the ticket",
      effort: "medium",
      outputSchema: CodexTicketExecutor.outputSchema,
      runtimeWorkspaceRoots: [
        URL(fileURLWithPath: "/private/tmp/storypointless-product")
      ]
    )
    let requests = await transport.requests()

    #expect(threadID == "thread-1")
    #expect(turnID == "turn-1")
    #expect(requests.map(\.method) == ["initialize", "thread/start", "turn/start"])
    #expect(
      requests[1].params["permissions"]?.stringValue
        == CodexPermissionProfiles.delivery
    )
    #expect(
      requests[1].params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue)
        == ["/private/tmp/storypointless-product"]
    )
    #expect(requests[1].params["permissionProfile"] == nil)
    #expect(requests[1].params["sandbox"] == nil)
    #expect(requests[1].params["approvalPolicy"]?.stringValue == "on-request")
    #expect(requests[1].params["model"]?.stringValue == "gpt-5.6-terra")
    let deliveryConfig =
      requests[1].params["config"]?["permissions.storypointless-delivery"]
    #expect(
      deliveryConfig?["filesystem"]?[
        "/private/tmp/storypointless-canonical-product/.git"
      ]?.stringValue == "read"
    )
    #expect(
      deliveryConfig?["filesystem"]?[":workspace_roots"]?["."]?.stringValue
        == "write"
    )
    #expect(requests[2].params["permissions"] == nil)
    #expect(
      requests[2].params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue)
        == ["/private/tmp/storypointless-product"]
    )
    #expect(requests[2].params["permissionProfile"] == nil)
  }

  @Test("Persisted Conversations are explicitly resumed with their scoped permissions")
  func persistedThreadsAreResumed() async throws {
    let transport = SuggestionTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let readOnlyThreadID = try await client.resumeReadOnlyThread(
      threadID: "review-thread",
      workingDirectory: URL(fileURLWithPath: "/private/tmp/review-workspace"),
      developerInstructions: "Continue the review",
      allowsApprovals: true
    )
    let workspaceThreadID = try await client.resumeWorkspaceThread(
      threadID: "implementation-thread",
      workingDirectory: URL(fileURLWithPath: "/private/tmp/ticket-workspace"),
      developerInstructions: "Continue the implementation",
      model: "gpt-5.6-terra",
      readOnlyGitDirectory: URL(fileURLWithPath: "/private/tmp/product/.git")
    )
    let requests = await transport.requests()

    #expect(readOnlyThreadID == "review-thread")
    #expect(workspaceThreadID == "implementation-thread")
    #expect(
      requests.map(\.method)
        == ["initialize", "thread/resume", "thread/resume"]
    )
    #expect(requests[1].params["threadId"]?.stringValue == "review-thread")
    #expect(requests[1].params["approvalPolicy"]?.stringValue == "on-request")
    #expect(
      requests[1].params["permissions"]?.stringValue
        == CodexPermissionProfiles.readOnly
    )
    #expect(
      requests[1].params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue)
        == ["/private/tmp/review-workspace"]
    )
    #expect(requests[2].params["threadId"]?.stringValue == "implementation-thread")
    #expect(
      requests[2].params["permissions"]?.stringValue
        == CodexPermissionProfiles.delivery
    )
    #expect(requests[2].params["model"]?.stringValue == "gpt-5.6-terra")
    #expect(
      requests[2].params["config"]?["permissions.storypointless-delivery"]?[
        "filesystem"
      ]?["/private/tmp/product/.git"]?.stringValue == "read"
    )
  }

  @Test("Delivery isolates the ticket while demos retain reviewed runtime reads")
  func managedPermissionProfiles() {
    let arguments = CodexPermissionProfiles.appServerArguments.joined(separator: " ")
    #expect(
      arguments.contains(CodexPermissionProfiles.requestPermissionsFeatureOverride)
    )
    #expect(arguments.contains(#"":minimal"="read""#))
    #expect(arguments.contains(#"":root"="read""#))
    #expect(arguments.contains(#""~/.codex"="deny""#))
    #expect(arguments.contains(#""~/Library/Application Support/StoryPointless"="deny""#))
    #expect(
      arguments.contains(
        #""~/Library/Application Support/StoryPointless/storypointless.sqlite"="deny""#
      )
    )
    #expect(
      !CodexPermissionProfiles.deliveryProfileOverride.contains(
        #""~/Library/Application Support/StoryPointless"="deny""#
      )
    )
    #expect(!CodexPermissionProfiles.deliveryProfileOverride.contains(#"":root"="read""#))
    #expect(arguments.contains(#""localhost"="allow""#))
    #expect(!arguments.contains("openssl.cnf"))
    #expect(!arguments.contains("/opt/homebrew/bin"))

    let demoWorkspace = URL(
      fileURLWithPath: "/Users/example/Library/Caches/StoryPointless/PreviewWorktrees/candidate"
    )
    let scopedArguments = CodexPermissionProfiles.appServerArguments(
      demoWorkspaceRoot: demoWorkspace
    ).joined(separator: " ")
    #expect(scopedArguments.contains(#"workspace_roots={"/Users/example/Library/Caches/StoryPointless/PreviewWorktrees/candidate"=true}"#))
    #expect(!arguments.contains(demoWorkspace.path))
  }

  @Test("Delivery selects Apple developer tools without broadening Git access")
  func managedGitEnvironment() {
    let environment = CodexPermissionProfiles.agentProcessEnvironment(
      developerDirectory: "/Applications/Xcode.app/Contents/Developer",
      inheritedPath: "/usr/bin:/bin"
    )

    #expect(environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
    #expect(
      environment["PATH"]
        == "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core:/usr/bin:/bin"
    )
    #expect(environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
    #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
    #expect(environment["GIT_PAGER"] == "cat")
    #expect(
      CodexPermissionProfiles.agentProcessEnvironment(
        developerDirectory: nil
      )["DEVELOPER_DIR"] == nil
    )
  }

  @Test("Delivery can use its nested ticket root without reading a sibling")
  func deliveryFilesystemBoundary() async throws {
    let codexURL = URL(
      fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"
    )
    guard FileManager.default.isExecutableFile(atPath: codexURL.path) else {
      return
    }
    let applicationSupport = try #require(
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    )
    let boundaryRoot = applicationSupport.appendingPathComponent(
      "StoryPointlessBoundaryTests-\(UUID())",
      isDirectory: true
    )
    let workspace = boundaryRoot
      .appendingPathComponent("Run Worktrees", isDirectory: true)
      .appendingPathComponent("product", isDirectory: true)
      .appendingPathComponent("ticket", isDirectory: true)
    let sibling = boundaryRoot.appendingPathComponent("control-plane.txt")
    defer { try? FileManager.default.removeItem(at: boundaryRoot) }
    try FileManager.default.createDirectory(
      at: workspace,
      withIntermediateDirectories: true
    )
    try Data("ticket\n".utf8).write(
      to: workspace.appendingPathComponent("ticket.txt")
    )
    try Data("private\n".utf8).write(to: sibling)

    let process = Process()
    let output = Pipe()
    process.executableURL = codexURL
    process.arguments = [
      "-c",
      #"default_permissions="\#(CodexPermissionProfiles.delivery)""#,
      "-c",
      CodexPermissionProfiles.deliveryProfileOverride,
      "sandbox",
      "-P",
      CodexPermissionProfiles.delivery,
      "-C",
      workspace.path,
      "/bin/zsh",
      "-c",
      """
      test "$(cat ticket.txt)" = ticket || exit 2
      printf ready > proof.txt || exit 3
      cat "\(sibling.path)" >/dev/null 2>&1 && exit 4
      exit 0
      """,
    ]
    process.currentDirectoryURL = workspace
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    #expect(
      process.terminationStatus == 0,
      Comment(rawValue: String(decoding: data, as: UTF8.self))
    )
    #expect(
      try String(
        contentsOf: workspace.appendingPathComponent("proof.txt"),
        encoding: .utf8
      ) == "ready"
    )
  }

  @Test("Delivery can inspect product Git without changing Git state")
  func deliveryGitBoundary() async throws {
    let codexURL = URL(
      fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"
    )
    guard FileManager.default.isExecutableFile(atPath: codexURL.path) else {
      return
    }
    let applicationSupport = try #require(
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    )
    let boundaryRoot = applicationSupport.appendingPathComponent(
      "StoryPointlessGitBoundaryTests-\(UUID())",
      isDirectory: true
    )
    let repository = boundaryRoot
      .appendingPathComponent("Product Workspaces", isDirectory: true)
      .appendingPathComponent("product", isDirectory: true)
    let worktrees = boundaryRoot
      .appendingPathComponent("Run Worktrees", isDirectory: true)
      .appendingPathComponent("product", isDirectory: true)
    let otherProductGit = boundaryRoot
      .appendingPathComponent("Product Workspaces", isDirectory: true)
      .appendingPathComponent("other-product", isDirectory: true)
      .appendingPathComponent(".git", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: boundaryRoot) }

    try FileManager.default.createDirectory(
      at: repository,
      withIntermediateDirectories: true
    )
    try Data("accepted\n".utf8).write(
      to: repository.appendingPathComponent("product.txt")
    )
    try FileManager.default.createDirectory(
      at: otherProductGit,
      withIntermediateDirectories: true
    )
    try Data("other product\n".utf8).write(
      to: otherProductGit.appendingPathComponent("private-object")
    )

    let manager = GitWorkspaceManager()
    _ = try await manager.ensureRepository(at: repository)
    let ticket = try await manager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: worktrees,
      ticketKey: "T1",
      runID: UUID(),
      authorName: "Delivery agent"
    )
    let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)

    let process = Process()
    let output = Pipe()
    process.executableURL = codexURL
    process.arguments = [
      "-c",
      #"default_permissions="\#(CodexPermissionProfiles.delivery)""#,
      "-c",
      CodexPermissionProfiles.deliveryProfileOverrideValue(
        readOnlyGitDirectory: gitDirectory
      ),
      "sandbox",
      "-P",
      CodexPermissionProfiles.delivery,
      "-C",
      ticket.url.path,
      "/bin/zsh",
      "-c",
      """
      test "$GIT_OPTIONAL_LOCKS" = 0 || exit 2
      test "$GIT_CONFIG_GLOBAL" = /dev/null || exit 3
      test "$GIT_PAGER" = cat || exit 4
      test -n "$DEVELOPER_DIR" || exit 5
      git status --short >/dev/null || exit 6
      git log --oneline -1 >/dev/null || exit 7
      test "$(git show HEAD:product.txt)" = accepted || exit 8
      printf changed >> product.txt || exit 9
      git diff -- product.txt | /usr/bin/grep -q changed || exit 10
      git add product.txt >/dev/null 2>&1 && exit 11
      git diff --cached --quiet || exit 12
      cat "\(otherProductGit.appendingPathComponent("private-object").path)" \
        >/dev/null 2>&1 && exit 13
      exit 0
      """,
    ]
    process.currentDirectoryURL = ticket.url
    process.environment = ProcessInfo.processInfo.environment.merging(
      CodexPermissionProfiles.agentProcessEnvironment
    ) { _, configuredValue in
      configuredValue
    }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let outputText = String(decoding: data, as: UTF8.self)

    #expect(
      process.terminationStatus == 0,
      Comment(rawValue: outputText)
    )
    #expect(!outputText.contains("xcrun_db"), Comment(rawValue: outputText))
    #expect(!outputText.contains("couldn't create cache file"), Comment(rawValue: outputText))
  }

  @Test("Candidate-scoped commands materialize the exact standalone workspace root")
  func candidateScopedManagedCommand() async throws {
    let codexURL = URL(
      fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"
    )
    guard
      FileManager.default.isExecutableFile(atPath: codexURL.path),
      FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/node")
    else {
      return
    }
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "storypointless-scoped-command-\(UUID())",
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: workspace,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: workspace) }

    let executor = CodexWorkspaceCommandExecutor(executableURL: codexURL)
    let result = try await executor.runManagedCommand(
      CodexManagedCommandRequest(
        command: [
          "/opt/homebrew/bin/node",
          "--eval",
          "const fs=require('node:fs');fs.readFileSync('/opt/homebrew/etc/openssl@3/openssl.cnf');fs.writeFileSync('proof.txt','ready');process.stdout.write('ready')",
        ],
        workingDirectory: workspace,
        workspaceRoot: workspace,
        timeoutSeconds: 10
      )
    )

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "ready")
    #expect(
      try String(
        contentsOf: workspace.appendingPathComponent("proof.txt"),
        encoding: .utf8
      ) == "ready"
    )
  }

  @Test("Standalone commands use App Server command exec and the demo profile")
  func managedCommandExec() async throws {
    let transport = ManagedCommandTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let result = try await client.runManagedCommand(
      CodexManagedCommandRequest(
        command: ["python3", "-m", "compileall", "."],
        workingDirectory: URL(fileURLWithPath: "/private/tmp/storypointless-preview"),
        environment: ["TMPDIR": "/private/tmp/storypointless-demo"],
        timeoutSeconds: 30
      )
    )
    let command = try #require(await transport.commandRequest())

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "compiled")
    #expect(command["command"]?.arrayValue?.compactMap(\.stringValue) == [
      "python3", "-m", "compileall", ".",
    ])
    #expect(command["permissionProfile"]?.stringValue == CodexPermissionProfiles.demo)
    #expect(command["timeoutMs"]?.integerValue == 30_000)
  }

  @Test("App Server approval requests can be allowed or denied through the client")
  func interactiveApprovalResponse() async throws {
    let transport = ApprovalTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    let messages = await client.inboundMessages(replayRecent: false)
    let request = CodexServerRequest(
      id: .integer(91),
      method: "item/commandExecution/requestApproval",
      params: .object([
        "threadId": .string("thread-delivery"),
        "turnId": .string("turn-delivery"),
        "itemId": .string("item-command"),
        "command": .string("docker compose up"),
        "cwd": .string("/private/tmp/ticket"),
        "reason": .string("Start the ticket's local database"),
      ])
    )
    await transport.send(request)

    let received = await messages.first { message in
      if case .request = message { return true }
      return false
    }
    guard let received, case .request(let receivedRequest) = received else {
      Issue.record("Expected an approval request")
      return
    }
    let presentation = try CodexAppServerClient.approvalPresentation(for: receivedRequest)
    #expect(presentation.title == "Allow this command?")
    #expect(presentation.detail == "docker compose up")
    #expect(presentation.reason == "Start the ticket's local database")

    let runtimeRequest = CodexServerRequest(
      id: .integer(93),
      method: "item/commandExecution/requestApproval",
      params: .object([
        "threadId": .string("thread-delivery"),
        "turnId": .string("turn-delivery"),
        "itemId": .string("item-runtime"),
        "command": .string("node --test"),
        "cwd": .string("/private/tmp/ticket"),
        "additionalPermissions": .object([
          "fileSystem": .object([
            "entries": .array([
              .object([
                "access": .string("read"),
                "path": .object([
                  "type": .string("path"),
                  "path": .string("/opt/homebrew/bin"),
                ]),
              ]),
              .object([
                "access": .string("read"),
                "path": .object([
                  "type": .string("path"),
                  "path": .string("/opt/homebrew/opt"),
                ]),
              ]),
              .object([
                "access": .string("read"),
                "path": .object([
                  "type": .string("path"),
                  "path": .string("/opt/homebrew/Cellar"),
                ]),
              ])
            ])
          ])
        ]),
        "reason": .string("Run the project tests with its installed Node runtime"),
      ])
    )
    let runtimePresentation = try CodexAppServerClient.approvalPresentation(
      for: runtimeRequest
    )
    #expect(runtimePresentation.detail.contains("node --test"))
    #expect(runtimePresentation.detail.contains("Additional access for this command"))
    #expect(runtimePresentation.detail.contains("Read /opt/homebrew/bin"))
    #expect(runtimePresentation.detail.contains("Read /opt/homebrew/opt"))
    #expect(runtimePresentation.detail.contains("Read /opt/homebrew/Cellar"))

    let sameCapabilityInAnotherTicket = CodexServerRequest(
      id: .integer(94),
      method: "item/commandExecution/requestApproval",
      params: .object([
        "threadId": .string("thread-other-ticket"),
        "turnId": .string("turn-other-ticket"),
        "command": .string("node --test"),
        "cwd": .string("/private/tmp/another-ticket"),
        "additionalPermissions": runtimeRequest.params["additionalPermissions"] ?? .null,
      ])
    )
    let otherTicketPresentation = try CodexAppServerClient.approvalPresentation(
      for: sameCapabilityInAnotherTicket
    )
    #expect(runtimePresentation.signature != otherTicketPresentation.signature)
    #expect(
      runtimePresentation.productGrantSignature
        == otherTicketPresentation.productGrantSignature
    )
    #expect(
      try CodexAppServerClient.productGrantSignature(
        for: runtimeRequest,
        ticketWorkspaceRoot: URL(fileURLWithPath: "/private/tmp/ticket")
      )
        == CodexAppServerClient.productGrantSignature(
          for: sameCapabilityInAnotherTicket,
          ticketWorkspaceRoot: URL(fileURLWithPath: "/private/tmp/another-ticket")
        )
    )
    #expect(
      try CodexAppServerClient.productGrantSignature(
        for: runtimeRequest,
        ticketWorkspaceRoot: URL(fileURLWithPath: "/private/tmp/different-ticket")
      ) == nil
    )

    let fileChangePresentation = try CodexAppServerClient.approvalPresentation(
      for: CodexServerRequest(
        id: .integer(95),
        method: "item/fileChange/requestApproval",
        params: .object([
          "threadId": .string("thread-delivery"),
          "turnId": .string("turn-delivery"),
          "reason": .string("Change a file outside the ticket workspace"),
        ])
      )
    )
    #expect(fileChangePresentation.productGrantSignature == nil)

    try await client.resolveApprovalRequest(receivedRequest, allow: true)
    let response = try #require(await transport.response())
    #expect(response.id == .integer(91))
    #expect(response.result["decision"]?.stringValue == "accept")

    let permissionRequest = CodexServerRequest(
      id: .integer(92),
      method: "item/permissions/requestApproval",
      params: .object([
        "threadId": .string("thread-delivery"),
        "turnId": .string("turn-delivery"),
        "itemId": .string("item-permission"),
        "permissions": .object([
          "network": .object([
            "enabled": .bool(true)
          ])
        ]),
        "reason": .string("Download a declared dependency"),
      ])
    )
    try await client.resolveApprovalRequest(permissionRequest, allow: true)
    let permissionResponse = try #require(await transport.response())
    #expect(permissionResponse.id == .integer(92))
    #expect(permissionResponse.result["scope"]?.stringValue == "turn")
    #expect(permissionResponse.result["permissions"] == permissionRequest.params["permissions"])

    try await client.resolveApprovalRequest(receivedRequest, allow: false)
    let deniedResponse = try #require(await transport.response())
    #expect(deniedResponse.result["decision"]?.stringValue == "decline")
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

  @Test("Interim commentary is not mistaken for the turn's final structured result")
  func interimCommentaryDoesNotCompleteTurn() async throws {
    let transport = ConcurrentTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    async let result = client.waitForFinalAgentMessage(
      threadID: "thread-commentary",
      turnID: "turn-commentary"
    )

    await transport.comment(
      threadID: "thread-commentary",
      turnID: "turn-commentary",
      text: #"{"status":"awaiting_owner","summary":"Work in progress."}"#
    )
    await transport.complete(
      threadID: "thread-commentary",
      turnID: "turn-commentary",
      text: #"{"status":"completed","summary":"Ready for review."}"#
    )

    #expect(
      try await result
        == #"{"status":"completed","summary":"Ready for review."}"#
    )
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
    #expect(suggestions.map(\.reference) == ["S1", "S2", "S3"])
    #expect(suggestions.map(\.type) == [.task, .task, .story])
    #expect(suggestions[2].suggestedRole == .implementer)
    #expect(suggestions[2].dependsOnReferences == ["S1", "S2"])

    let looselyFormatted = #"""
      {"suggestions":[
        {"reference":" t-1 ","title":"Choose provider","type":"task","body":"Compare options","acceptanceCriteria":["Trade-offs are clear"],"role":"business_analyst","priority":"high","rationale":"Defines the contract","dependsOn":[]},
        {"reference":"T 2","title":"Build UI","type":"story","body":"Implement it","acceptanceCriteria":["Forecast is visible"],"role":"implementer","priority":"normal","rationale":"Creates value","dependsOn":["T-1"]}
      ]}
      """#
    let normalized = try CodexTicketSuggestionGenerator.decode(looselyFormatted)
    #expect(normalized.map(\.reference) == ["S1", "S2"])
    #expect(normalized[1].dependsOnReferences == ["S1"])

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

  @Test("Sprint goal generation uses ticket titles and validates a concise result")
  func sprintGoalGeneration() throws {
    let prompt = CodexSprintGoalGenerator.prompt(
      productName: "Field Notes",
      sprintNumber: 4,
      ticketTitles: [
        "Save a draft note",
        "Restore the latest draft after relaunch",
      ]
    )

    #expect(prompt.contains("Save a draft note"))
    #expect(prompt.contains("Restore the latest draft after relaunch"))
    #expect(prompt.contains("Sprint: 4"))
    #expect(
      try CodexSprintGoalGenerator.decode(
        #"{"goal":"  Product Owners can preserve and resume draft notes.  "}"#
      ) == "Product Owners can preserve and resume draft notes"
    )
    #expect(throws: SprintGoalGenerationError.self) {
      try CodexSprintGoalGenerator.decode(#"{"goal":"   "}"#)
    }
    #expect(throws: SprintGoalGenerationError.self) {
      try CodexSprintGoalGenerator.decode(#"{"goal":42}"#)
    }
    #expect(throws: SprintGoalGenerationError.self) {
      try CodexSprintGoalGenerator.decode(
        #"{"goal":"This proposed sprint goal is deliberately longer than eighty characters so validation rejects it"}"#
      )
    }
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
    #expect(plan.ticketSuggestions.map(\.reference) == ["S1", "S2"])
    #expect(plan.ticketSuggestions[1].dependsOnReferences == ["S1"])
  }

  @Test("Epic planning rejects analysis-only plans for delivery outcomes")
  func epicPlanningRequiresDeliveryPath() throws {
    let response = #"""
      {
        "epic": {
          "title": "Forecast jokes",
          "goal": "Customers see an appropriate joke with each forecast.",
          "successCriteria": [
            "Each weather result displays a joke when the provider responds."
          ],
          "constraints": "Use an approved public provider."
        },
        "suggestions": [
          {
            "reference": "S1",
            "title": "Recommend a suitable joke provider",
            "type": "task",
            "body": "Compare public providers and recommend one.",
            "acceptanceCriteria": ["The Product Owner can approve one provider"],
            "role": "business_analyst",
            "priority": "high",
            "rationale": "Delivery needs an approved provider.",
            "dependsOn": []
          }
        ]
      }
      """#

    #expect(throws: TicketSuggestionGenerationError.self) {
      try CodexTicketSuggestionGenerator.decodeEpicPlan(response)
    }
  }

  @Test("Epic planning permits one coherent delivery ticket")
  func epicPlanningPermitsOneCoherentDeliveryTicket() throws {
    let response = #"""
      {
        "epic": {
          "title": "Forecast units",
          "goal": "Customers can choose the temperature unit they understand.",
          "successCriteria": [
            "A customer can switch units and see every displayed temperature update."
          ],
          "constraints": "Keep the preference on the device."
        },
        "suggestions": [
          {
            "reference": "S1",
            "title": "Choose a temperature unit",
            "type": "story",
            "body": "Add the unit preference and apply it throughout the forecast.",
            "acceptanceCriteria": [
              "A customer can switch between Celsius and Fahrenheit",
              "Every displayed temperature uses the selected unit",
              "Automated checks cover conversion and saved preference behaviour"
            ],
            "role": "implementer",
            "priority": "normal",
            "rationale": "One cohesive change delivers and verifies the complete outcome.",
            "dependsOn": []
          }
        ]
      }
      """#

    let plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(response)

    #expect(plan.ticketSuggestions.count == 1)
    #expect(plan.ticketSuggestions[0].suggestedRole == .implementer)
  }

  @Test("Epic planning permits a genuinely decision-only research outcome")
  func epicPlanningPermitsDecisionOnlyOutcome() throws {
    let response = #"""
      {
        "epic": {
          "title": "Select a joke provider",
          "goal": "Choose a safe provider before committing delivery scope.",
          "successCriteria": [
            "An approved recommendation compares terms, reliability, and maintenance ownership."
          ],
          "constraints": "Do not implement the integration yet."
        },
        "suggestions": [
          {
            "reference": "S1",
            "title": "Recommend a suitable joke provider",
            "type": "task",
            "body": "Compare public providers and recommend one.",
            "acceptanceCriteria": ["The Product Owner can approve one provider"],
            "role": "business_analyst",
            "priority": "high",
            "rationale": "The epic is explicitly a provider decision.",
            "dependsOn": []
          }
        ]
      }
      """#

    let plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(response)
    #expect(plan.ticketSuggestions.count == 1)
    #expect(plan.ticketSuggestions[0].suggestedRole == .businessAnalyst)
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
        #expect(prompt.contains("content sources"))
    #expect(prompt.contains("Do not silently defer"))
        #expect(prompt.contains("time-boxed research ticket"))
    #expect(clarification.questions.count == 1)
    #expect(clarification.questions[0].options.count == 2)
    #expect(!clarification.readyToPlan)
    #expect(ready.questions.isEmpty)
    #expect(ready.readyToPlan)
  }

  @Test("Expired epic planning threads resume from the durable owner conversation")
  func epicPlanningRecoveryPrompt() {
    let product = Product(
      name: "Weather",
      vision: "Help customers understand the weather for a chosen location"
    )
    let epic = Epic(
      productID: product.id,
      title: "Saved locations",
      goal: "Let customers return to useful forecasts"
    )
    let question = TicketRefinementQuestion(
      prompt: "Where should saved locations be retained?",
      options: [
        "On this device only (Recommended)",
        "Across signed-in devices",
      ]
    )
    let prompt = CodexEpicClarificationGenerator.recoveryPrompt(
      product: product,
      epic: epic,
      existingItems: [],
      messages: [
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body: "I need to clarify how saved locations persist."
        ),
        EpicPlanningConversationMessage(
          author: .owner,
          body: "",
          answeredQuestions: [
            EpicPlanningAnsweredQuestion(
              question: question,
              selectedOption: "On this device only (Recommended)",
              answer: "On this device only (Recommended)"
            )
          ]
        ),
        EpicPlanningConversationMessage(
          author: .owner,
          body: "@UX Designer Which existing pattern should we reuse?",
          kind: .chat,
          participantName: "UX Designer"
        ),
        EpicPlanningConversationMessage(
          author: .agent,
          body: "Reuse the established compact result row.",
          kind: .chat,
          participantName: "UX Designer"
        ),
      ]
    )

    #expect(prompt.contains("previous Codex thread"))
    #expect(prompt.contains("Let customers return to useful forecasts"))
    #expect(prompt.contains("I need to clarify how saved locations persist."))
    #expect(prompt.contains("Where should saved locations be retained?"))
    #expect(prompt.contains("On this device only (Recommended)"))
    #expect(prompt.contains("Do not repeat resolved questions"))
    #expect(prompt.contains("tickets in this response"))
    #expect(prompt.contains("Constraints for an unnamed"))
    #expect(prompt.contains("authorisation for Business Analyst research"))
    #expect(prompt.contains("let the team choose"))
    #expect(!prompt.contains("Which existing pattern should we reuse?"))
    #expect(!prompt.contains("compact result row"))
  }

  @Test("Interrupted final epic planning reconstructs every durable owner answer")
  func finalEpicPlanRecoveryPrompt() {
    let product = Product(
      name: "Weather",
      vision: "Help customers return to forecasts they care about"
    )
    let epic = Epic(
      productID: product.id,
      title: "Saved places",
      goal: "Customers can reopen forecasts without searching again"
    )
    let question = TicketRefinementQuestion(
      prompt: "How many places can a customer save?",
      options: ["Up to 10 (Recommended)", "No product limit"]
    )
    let prompt = CodexEpicClarificationGenerator.finalPlanRecoveryPrompt(
      product: product,
      epic: epic,
      existingItems: [],
      rejectedSuggestions: [],
      messages: [
        EpicPlanningConversationMessage(
          author: .owner,
          body: "",
          answeredQuestions: [
            EpicPlanningAnsweredQuestion(
              question: question,
              selectedOption: "Up to 10 (Recommended)",
              answer: "Up to 10 (Recommended)"
            )
          ]
        ),
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body: "Ready to plan with browser-only saved data."
        ),
      ]
    )

    #expect(prompt.contains("How many places can a customer save?"))
    #expect(prompt.contains("Up to 10 (Recommended)"))
    #expect(prompt.contains("Ready to plan with browser-only saved data."))
    #expect(prompt.contains("Return the complete epic metadata"))
    #expect(prompt.contains("do not ask the Product Owner to repeat anything"))
  }

  @Test("Epic planning does not turn unresolved owner decisions into discovery tickets")
  func epicPlanningDecisionGuardrails() {
    let product = Product(
      name: "Weather",
      vision: "Help customers understand the weather for a chosen location"
    )
    let epic = Epic(
      productID: product.id,
      title: "Weather jokes",
      goal: "Show an appropriate joke with each forecast"
    )
    let prompt = CodexTicketSuggestionGenerator.epicPrompt(
      product: product,
      epic: epic,
      existingItems: []
    )
    let followUp = CodexEpicClarificationGenerator.followUpPrompt(
      answers: ["Use bundled, curated jokes"]
    )
    let initial = CodexEpicClarificationGenerator.initialPrompt(
      product: product,
      epic: epic,
      existingItems: []
    )
    let finalPlan = CodexEpicClarificationGenerator.finalPlanPrompt(
      product: product,
      epic: epic,
      existingItems: [],
      rejectedSuggestions: []
    )
    let developerInstructions = CodexTicketSuggestionGenerator.developerInstructions(
      productInstructions: "",
      personaInstructions: AgentPersonaDefaults.instructions(for: .businessAnalyst)
    )

    #expect(prompt.contains("invent product decisions"))
    #expect(prompt.contains("explicitly requested research"))
    #expect(prompt.contains("Otherwise create tickets that deliver"))
    #expect(prompt.contains("Research is a prerequisite,"))
    #expect(prompt.contains("trace every epic success criterion"))
    #expect(prompt.contains("do not default to a fixed"))
    #expect(prompt.contains("Make verification explicit in"))
    #expect(prompt.contains("separate design or verification ticket only when"))
    #expect(!prompt.contains("include the downstream experience-design, implementation, and verification"))
    #expect(prompt.contains("separate Business Analyst ticket"))
    #expect(prompt.contains("do not bury source selection"))
    #expect(prompt.contains("implementation-time selection without a separate recommendation"))
    #expect(initial.contains("Business Analyst research ticket"))
    #expect(initial.contains("Do not offer a vague option"))
    #expect(initial.contains("implementation-time selection"))
    #expect(followUp.contains("sources"))
    #expect(followUp.contains("Do not silently"))
    #expect(followUp.contains("Constraints for an unnamed external source"))
    #expect(followUp.contains("let the team choose"))
    #expect(finalPlan.contains("is such authorisation"))
    #expect(finalPlan.contains("Give that work a separate Business Analyst ticket"))
    #expect(finalPlan.contains("inside design or implementation"))
    #expect(finalPlan.contains("Do not force that work into a standard sequence"))
    #expect(finalPlan.contains("using a separate ticket only when"))
    #expect(developerInstructions.contains("constraints alone do not select"))
    #expect(developerInstructions.contains("authorised Business Analyst research"))
    #expect(developerInstructions.contains(#"not "S1 - Choose a provider""#))
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

  @Test("Legacy paused Work log questions retain interactive presentation")
  func legacyPausedWorkLogQuestionPresentation() throws {
    let body = """
      I found two viable providers and need the Product Owner to choose one.

      Question for you: Which provider should downstream delivery use?

      Options:
      - Approve the free provider with visible credit.
      - Select the paid provider with an SLA.
      """

    let presentation = try #require(
      TicketOwnerQuestion.presentation(in: body, structuredQuestion: nil)
    )

    #expect(
      presentation.context
        == "I found two viable providers and need the Product Owner to choose one."
    )
    #expect(presentation.question.prompt == "Which provider should downstream delivery use?")
    #expect(
      presentation.question.options
        == [
          "Approve the free provider with visible credit.",
          "Select the paid provider with an SLA.",
        ]
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
    #expect(instructions.contains("automatic Business Analyst refinement"))
    #expect(instructions.contains("Business Analyst — Business Analyst"))
    #expect(prompt.contains("T-4"))
    #expect(prompt.contains("Why was this colour chosen?"))
    #expect(pausedQuestionPrompt.contains("explanatory question about sprint delivery"))
    #expect(pausedQuestionPrompt.contains("Do not resume implementation"))
    #expect(pausedQuestionPrompt.contains("invalidate a reviewed candidate"))
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

  @Test("Ordinary Epic chat is read-only, single-recipient, and separate from refinement")
  func epicConversation() throws {
    let product = Product(
      name: "Weather",
      vision: "Show weather for a chosen location",
      instructions: "Use UK English."
    )
    let epic = Epic(
      productID: product.id,
      title: "Saved places",
      goal: "Customers can return to forecasts without searching again",
      successCriteria: ["Customers can save and reopen a place"]
    )
    let designer = AgentProfile(
      productID: product.id,
      name: "UX Designer",
      role: .uxDesigner,
      model: "gpt-5.6-sol",
      reasoningEffort: "medium"
    )
    let instructions = CodexEpicConversation.developerInstructions(
      productInstructions: product.instructions,
      personaInstructions: designer.effectiveInstructions,
      recipient: designer
    )
    let prompt = CodexEpicConversation.prompt(
      product: product,
      epic: epic,
      relatedItems: [],
      proposedItems: [],
      previousMessages: [
        EpicPlanningConversationMessage(
          author: .owner,
          body: "@UX Designer Which existing pattern should we reuse?",
          kind: .chat,
          participantID: designer.id,
          participantName: designer.name
        ),
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body: "This governed clarification must not appear as ordinary chat."
        ),
      ],
      ownerMessage: "Would the compact result row work here?"
    )
    let reply = try CodexEpicConversation.decode(
      #"{"message":"Yes. The compact result row fits the current hierarchy."}"#
    )

    #expect(instructions.contains("single team member"))
    #expect(instructions.contains("Do not modify files"))
    #expect(instructions.contains("UX Designer — UX Designer"))
    #expect(instructions.contains("never answers"))
    #expect(prompt.contains("Saved places"))
    #expect(prompt.contains("Which existing pattern should we reuse?"))
    #expect(prompt.contains("Would the compact result row work here?"))
    #expect(!prompt.contains("governed clarification"))
    #expect(reply.message.contains("compact result row"))
    #expect(throws: EpicConversationGenerationError.self) {
      _ = try CodexEpicConversation.decode(#"{"message":" "}"#)
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

  @Test("Ticket execution receives direct prerequisite handoffs and planned dependant contracts")
  func ticketExecutionDependencyHandoffs() {
    let product = Product(
      name: "Content search",
      vision: "Return useful results with suitable supporting content"
    )
    let analyst = AgentProfile(
      productID: product.id,
      name: "Business Analyst",
      role: .businessAnalyst
    )
    let prerequisite = WorkItem(
      productID: product.id,
      key: "T1",
      title: "Approve the source criteria",
      type: .task,
      body: "Agree the privacy and licensing constraints.",
      acceptanceCriteria: ["The permitted data-sharing boundary is recorded"],
      state: .released
    )
    let research = WorkItem(
      productID: product.id,
      key: "T2",
      title: "Recommend a content provider",
      type: .task,
      body: "Compare eligible providers and recommend one.",
      acceptanceCriteria: ["The Product Owner can approve one provider"]
    )
    let implementation = WorkItem(
      productID: product.id,
      key: "T4",
      title: "Integrate the approved provider",
      body: "Build against the provider selected by T2.",
      acceptanceCriteria: [
        "Successful searches display supporting content",
        "Provider failure does not block the primary result",
      ]
    )
    let prerequisiteComment = TicketComment(
      workItemID: prerequisite.id,
      authorKind: .agent,
      authorName: "Business Analyst",
      body: "Completion handoff: Do not send customer search terms to the provider."
    )
    let expiredPermissionComment = TicketComment(
      workItemID: research.id,
      authorKind: .system,
      authorName: "StoryPointless",
      body: "Permission requested: git status\n\nUse Allow or Deny on this ticket."
    )
    let prompt = CodexTicketExecutor.prompt(
      product: product,
      item: research,
      assignee: analyst,
      prerequisites: [prerequisite],
      dependants: [implementation],
      prerequisiteComments: [prerequisite.id: [prerequisiteComment]],
      ticketComments: [expiredPermissionComment],
      knowledgeContext: [],
      existingItems: [prerequisite, research, implementation]
    )
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      personaInstructions: AgentPersonaDefaults.instructions(for: .businessAnalyst),
      assignee: analyst
    )

    #expect(prompt.contains("Planned direct dependant tickets"))
    #expect(prompt.contains("T4 [Backlog, Story]: Integrate the approved provider"))
    #expect(prompt.contains("Build against the provider selected by T2."))
    #expect(prompt.contains("Successful searches display supporting content"))
    #expect(prompt.contains("The permitted data-sharing boundary is recorded"))
    #expect(prompt.contains("Do not send customer search terms to the provider"))
    #expect(prompt.contains("Do not duplicate, replace,"))
    #expect(prompt.contains("Return an empty"))
    #expect(!prompt.contains("Permission requested:"))
    #expect(instructions.contains("self-contained completion handoff"))
    #expect(instructions.contains("Planned direct dependants"))
    #expect(instructions.contains("materially conflicts with an existing ticket contract"))
    #expect(instructions.contains("genuinely new scope"))
    #expect(instructions.contains("Never copy, mirror, archive, or stage"))
    #expect(instructions.contains("You may use read-only Git inspection"))
    #expect(instructions.contains("owns every Git mutation"))
    #expect(instructions.contains("already available inside the sandbox"))
    #expect(instructions.contains("command -v"))
    #expect(instructions.contains("request_permissions"))
    #expect(instructions.contains("smallest coherent filesystem"))
    #expect(instructions.contains("Batch all known paths into one"))
    #expect(instructions.contains("Do not discover a runtime one approval at a time"))
    #expect(instructions.contains("`/opt/homebrew/bin`"))
    #expect(instructions.contains("`/opt/homebrew/opt`"))
    #expect(instructions.contains("`/opt/homebrew/Cellar`"))
    #expect(instructions.contains("do not merely repeat"))
    #expect(instructions.contains("add another shell wrapper"))
    #expect(instructions.contains("substitute older evidence"))
    #expect(instructions.contains("consult the verified Environments page"))
    #expect(instructions.contains("repository's established native build system"))
    #expect(instructions.contains("substitute another package manager"))
    #expect(instructions.contains("small version-controlled"))
    #expect(instructions.contains("never use a wrapper to hide unrelated operations"))
    #expect(instructions.contains("propose its complete replacement body"))
    #expect(instructions.contains("knowledge as permission"))
    #expect(instructions.contains("The comment is the body"))
    #expect(instructions.contains("prefix it with the team member's name"))
    #expect(instructions.contains("StoryPointless renders attribution and status separately"))
    #expect(instructions.contains("cannot override the workspace boundary"))
    #expect(instructions.contains("Work log output contract"))

    let integrationPrompt = CodexConflictIntegrator.prompt(
      product: product,
      item: research,
      conflictedFiles: ["knowledge/provider.md"],
      recentComments: [expiredPermissionComment]
    )
    let integrationInstructions = CodexConflictIntegrator.developerInstructions(
      productInstructions: ""
    )
    #expect(!integrationPrompt.contains("Permission requested:"))
    #expect(integrationInstructions.contains("already available inside the sandbox"))
    #expect(integrationInstructions.contains("reported unmerged paths"))
    #expect(integrationInstructions.contains("do not run builds, tests, linters"))
    #expect(integrationInstructions.contains("focused Tech Lead review owns semantic validation"))
  }

  @Test("Ticket execution separates verified context from canonical knowledge destinations")
  func ticketExecutionKnowledgeDirectory() {
    let product = Product(
      name: "Connected product",
      vision: "Use external services without losing durable context"
    )
    let implementer = AgentProfile(
      productID: product.id,
      name: "Implementer",
      role: .implementer
    )
    let item = WorkItem(
      productID: product.id,
      key: "T1",
      title: "Connect an external provider API"
    )
    let technical = KnowledgePage(
      productID: product.id,
      title: "Technical",
      slug: "technical",
      kind: .section
    )
    let components = KnowledgePage(
      productID: product.id,
      parentID: technical.id,
      title: "Components & data",
      slug: "components-and-data",
      bodyMarkdown: "Local saved records use stable identifiers."
    )
    let integrations = KnowledgePage(
      productID: product.id,
      parentID: technical.id,
      title: "Integrations",
      slug: "integrations"
    )
    let selection = KnowledgeContextSelector.select(
      pages: [technical, components, integrations],
      item: item,
      prerequisites: []
    )

    let prompt = CodexTicketExecutor.prompt(
      product: product,
      item: item,
      assignee: implementer,
      prerequisites: [],
      dependants: [],
      prerequisiteComments: [:],
      ticketComments: [],
      knowledgeContext: selection.referencePages,
      knowledgeDirectory: selection.directoryPages,
      knowledgeDestinationIDs: selection.writablePageIDs
    )
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      personaInstructions: "",
      assignee: implementer
    )

    #expect(prompt.contains("Canonical knowledge directory"))
    #expect(prompt.contains("Technical > Integrations"))
    #expect(prompt.contains("Update allowed; this page is currently empty"))
    #expect(
      prompt.contains(
        "Routing reference only; do not update because its current body was not supplied"
      )
    )
    #expect(!prompt.contains("Add verified knowledge here."))
    #expect(instructions.contains("external providers and APIs belong in"))
    #expect(instructions.contains("Do not update an unrelated writable page"))
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
        "demo":{
          "schemaVersion":1,
          "title":"Location form",
          "preparationCommands":[],
          "launchCommand":{
            "executable":"python3",
            "arguments":["-m","http.server","{{PORT}}","--bind","127.0.0.1"],
            "workingDirectory":".",
            "timeoutSeconds":180
          },
          "portEnvironmentVariable":"PORT",
          "readiness":{"kind":"http","path":"/","timeoutSeconds":30},
          "presentation":{"kind":"browser","path":"/location"}
        },
        "retrospectiveWentWell":["The existing form boundary made validation straightforward."],
        "retrospectiveCouldImprove":[],
        "retrospectiveActions":[
          {
            "body":"Confirm the location form checks pass before requesting review.",
            "destination":"team_practice"
          }
        ],
        "knowledgePageProposals":[],
        "followUpTicketProposals":[]
      }
      """#
    )
    #expect(completed.status == .completed)
    #expect(completed.changedFiles == ["Sources/LocationForm.swift"])
    #expect(completed.demo?.presentation.kind == .browser)
    #expect(completed.retrospectiveActions.first?.destination == .teamPractice)
    #expect(completed.workLogComment.contains("Completion handoff"))
    #expect(completed.workLogComment.contains("Delivery notes"))
    #expect(completed.workLogComment.contains("How to review"))
    #expect(completed.workLogComment.contains("Demo: Location form"))
    #expect(CodexTicketExecutor.outputSchema["required"]?.arrayValue?.contains(.string("demo")) == true)

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
          "knowledgePageProposals":[],
          "followUpTicketProposals":[]
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
          "knowledgePageProposals":[],
          "followUpTicketProposals":[]
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
        "knowledgePageProposals":[],
        "followUpTicketProposals":[]
      }
      """#
    )
    #expect(waiting.status == .awaitingOwner)
    #expect(waiting.options.count == 2)

    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.decode(
        #"{"status":"awaiting_owner","comment":"Need input","question":null,"options":[],"summary":"","changedFiles":[],"tests":[],"knowledgeNotes":[],"reviewInstructions":[],"retrospectiveWentWell":[],"retrospectiveCouldImprove":[],"retrospectiveActions":[],"knowledgePageProposals":[],"followUpTicketProposals":[]}"#
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
    let researchCompleted = try CodexTicketExecutor.decode(
      #"""
      {
        "status":"completed",
        "comment":"I compared the approved provider options.",
        "question":null,
        "options":[],
        "summary":"Open-Meteo is recommended with documented trade-offs.",
        "changedFiles":["docs/provider-recommendation.md"],
        "tests":["Checked every comparison criterion — passed"],
        "knowledgeNotes":["The approved provider requires no API key."],
        "reviewInstructions":["Open the recommendation and inspect the comparison table."],
        "retrospectiveWentWell":[],
        "retrospectiveCouldImprove":[],
        "retrospectiveActions":[],
        "knowledgePageProposals":[],
        "followUpTicketProposals":[
          {
            "reference":"F1",
            "title":"Design provider failure states",
            "type":"task",
            "body":"Design the customer experience when forecast data is unavailable.",
            "acceptanceCriteria":["The Product Owner can review every failure state"],
            "role":"ux_designer",
            "priority":"high",
            "rationale":"The research identified the provider's availability behavior.",
            "dependsOn":[]
          },
          {
            "reference":"F2",
            "title":"Integrate the approved provider",
            "type":"story",
            "body":"Implement forecasts using the approved provider contract.",
            "acceptanceCriteria":["A location displays its current forecast"],
            "role":"implementer",
            "priority":"normal",
            "rationale":"This turns the approved research outcome into customer value.",
            "dependsOn":["F1"]
          }
        ]
      }
      """#
    )
    #expect(researchCompleted.followUpTicketProposals.count == 2)
    #expect(researchCompleted.followUpTicketProposals[1].dependsOnReferences == ["F1"])
    #expect(researchCompleted.workLogComment.contains("Recommended follow-up tickets"))
    try CodexTicketExecutor.validateFollowUpTicketProposals(
      in: researchCompleted,
      assignee: analyst
    )
    let implementer = AgentProfile(
      productID: product.id,
      name: "Implementer",
      role: .implementer
    )
    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.validateFollowUpTicketProposals(
        in: researchCompleted,
        assignee: implementer
      )
    }
    let techLead = AgentProfile(
      productID: product.id,
      name: "Tech Lead",
      role: .lead
    )
    let reviewDeveloperInstructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      personaInstructions: techLead.effectiveInstructions,
      reviewer: techLead
    )
    #expect(reviewDeveloperInstructions.contains("Cosmetic diff hygiene is not a blocker"))
    #expect(reviewDeveloperInstructions.contains("trailing whitespace"))
    #expect(reviewDeveloperInstructions.contains("shortest maintained, purpose-named entry"))
    #expect(reviewDeveloperInstructions.contains("review is read-only"))
    #expect(reviewDeveloperInstructions.contains("The comment is the body"))
    #expect(reviewDeveloperInstructions.contains("do not prefix it with the reviewer's name"))
    #expect(reviewDeveloperInstructions.contains(#""Approved" or "Changes requested""#))
    #expect(
      reviewDeveloperInstructions.contains(
        "structured decision separately"
      )
    )
    #expect(reviewDeveloperInstructions.contains("cannot override the"))
    #expect(reviewDeveloperInstructions.contains("Work log output contract"))
    #expect(
      reviewDeveloperInstructions.contains(
        "independently justify the cost of another implementation, integration, and review cycle"
      )
    )
    let reReviewPrompt = CodexTechLeadReviewer.prompt(
      product: product,
      item: researchTicket,
      implementation: researchCompleted,
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
    #expect(reReviewPrompt.contains("earlier classification is not binding"))
    #expect(reReviewPrompt.contains("If no material finding remains, approve"))
    #expect(reReviewPrompt.contains("Integrate the approved provider"))
    let candidateReviewPrompt = CodexTechLeadReviewer.prompt(
      product: product,
      item: researchTicket,
      implementation: researchCompleted,
      assignee: analyst,
      baseSHA: "candidate-base",
      candidateHeadSHA: "candidate-head"
    )
    #expect(candidateReviewPrompt.contains("Candidate revision: candidate-head"))
    #expect(candidateReviewPrompt.contains("A clean integration"))
    #expect(candidateReviewPrompt.contains("will not require another review"))

    let interruptedPermission = AgentPermissionRequest(
      productID: product.id,
      workItemID: researchTicket.id,
      agentRunID: UUID(),
      threadID: "review-thread",
      turnID: "review-turn",
      serverRequestID: "91",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: #"/bin/zsh -lc "/bin/zsh -lc 'swift test --filter ResearchTests'""#,
      signature: #"command|/bin/zsh -lc "/bin/zsh -lc 'swift test --filter ResearchTests'""#,
      status: .interrupted
    )
    let recoveryPrompt = CodexTechLeadReviewer.recoveryPrompt(
      item: researchTicket,
      reviewedSHA: "integrated-review-sha",
      isIntegratedRevision: true,
      interruptedPermission: interruptedPermission
    )
    #expect(recoveryPrompt.contains("Continue the existing Tech Lead review"))
    #expect(recoveryPrompt.contains("integrated-review-sha"))
    #expect(recoveryPrompt.contains("swift test --filter ResearchTests"))
    #expect(recoveryPrompt.contains("Do not restart a full"))
    #expect(recoveryPrompt.contains("audit display only"))
    #expect(recoveryPrompt.contains("Never paste it into a command"))
    #expect(recoveryPrompt.contains("do not request the command again"))
    #expect(recoveryPrompt.contains("one batched"))
    #expect(recoveryPrompt.contains("`/opt/homebrew/Cellar`"))

    let implementationRecoveryPrompt = CodexTicketExecutor.recoveryPrompt(
      item: researchTicket,
      interruptedPermission: interruptedPermission,
      recentComments: [
        TicketComment(
          workItemID: researchTicket.id,
          authorKind: .owner,
          authorName: "Me",
          body: "Use the provider without sending customer identifiers."
        )
      ]
    )
    #expect(implementationRecoveryPrompt.contains("Continue the existing implementation"))
    #expect(implementationRecoveryPrompt.contains("existing Conversation and ticket workspace"))
    #expect(implementationRecoveryPrompt.contains("swift test --filter ResearchTests"))
    #expect(
      implementationRecoveryPrompt.contains(
        "Use the provider without sending customer identifiers."
      )
    )
    #expect(implementationRecoveryPrompt.contains("Do not restart the ticket"))
    #expect(implementationRecoveryPrompt.contains("audit display only"))
    #expect(implementationRecoveryPrompt.contains("`/bin/zsh -lc`"))
    #expect(implementationRecoveryPrompt.contains("use `request_permissions`"))
    #expect(implementationRecoveryPrompt.contains("one batched"))
    #expect(implementationRecoveryPrompt.contains("`/opt/homebrew/Cellar`"))

    let adoptedBaseline = TicketRevisionBaseline(
      candidateHeadSHA: "candidate-before-conflict",
      integratedSHA: "reviewed-conflict-resolution"
    )
    let baselineRecoveryPrompt = CodexTicketExecutor.recoveryPrompt(
      item: researchTicket,
      interruptedPermission: nil,
      adoptedBaseline: adoptedBaseline
    )
    #expect(baselineRecoveryPrompt.contains("candidate-before-conflict"))
    #expect(baselineRecoveryPrompt.contains("reviewed-conflict-resolution"))
    #expect(baselineRecoveryPrompt.contains("accepted trunk changes"))
    #expect(baselineRecoveryPrompt.contains("Do not undo or recreate this Git handoff"))
    let baselineRevisionPrompt = CodexTicketExecutor.revisionPrompt(
      item: researchTicket,
      reviewer: analyst,
      feedback: "Preserve the accepted provider behavior while correcting attribution.",
      recentComments: [],
      adoptedBaseline: adoptedBaseline
    )
    #expect(baselineRevisionPrompt.contains("reviewed-conflict-resolution"))
    #expect(baselineRevisionPrompt.contains("Treat the current workspace as the source"))

    let interruptedLeafPermission = AgentPermissionRequest(
      productID: product.id,
      workItemID: researchTicket.id,
      agentRunID: UUID(),
      threadID: "implementation-thread",
      turnID: "implementation-turn",
      serverRequestID: "92",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Read /opt/homebrew/opt/llhttp",
      signature: "permissions|/opt/homebrew/opt/llhttp",
      status: .interrupted
    )
    let leafRecoveryPrompt = CodexTicketExecutor.recoveryPrompt(
      item: researchTicket,
      interruptedPermission: interruptedLeafPermission
    )
    #expect(leafRecoveryPrompt.contains("Read /opt/homebrew/opt/llhttp"))
    #expect(leafRecoveryPrompt.contains("do not continue requesting adjacent paths"))
    #expect(leafRecoveryPrompt.contains("one consolidated request"))
    #expect(leafRecoveryPrompt.contains("`/opt/homebrew/bin`"))
    #expect(leafRecoveryPrompt.contains("`/opt/homebrew/opt`"))
    #expect(leafRecoveryPrompt.contains("`/opt/homebrew/Cellar`"))

    var deniedPermission = interruptedPermission
    deniedPermission.status = .denied
    let deniedRecoveryPrompt = CodexTicketExecutor.recoveryPrompt(
      item: researchTicket,
      interruptedPermission: deniedPermission
    )
    #expect(deniedRecoveryPrompt.contains("Product Owner denied"))
    #expect(deniedRecoveryPrompt.contains("Do not reissue the same request"))

    let replacementImplementationPrompt = CodexTicketExecutor.recoveryPrompt(
      item: researchTicket,
      interruptedPermission: nil,
      conversationIsAvailable: false
    )
    #expect(replacementImplementationPrompt.contains("previous Conversation is unavailable"))
    #expect(replacementImplementationPrompt.contains("workspace and its changes"))

    let integration = try CodexConflictIntegrator.decode(
      #"{"status":"awaiting_owner","comment":"The two branches define incompatible defaults.","question":"Which behavior should remain the default?","options":["Use the accepted trunk behavior","Use the ticket behavior"],"summary":"","checks":[]}"#
    )
    #expect(integration.status == .awaitingOwner)
    #expect(integration.workLogComment.contains("Question for you"))
  }

  @Test("Retrospective synthesis consolidates free-text evidence into at most five actions")
  func retrospectiveSynthesis() throws {
    let product = Product(
      name: "Delivery product",
      vision: "Make delivery friction visible"
    )
    let sprint = Sprint(
      productID: product.id,
      number: 7,
      goal: "Learn from delivery",
      state: .completed
    )
    let item = WorkItem(
      productID: product.id,
      key: "T56",
      title: "Deliver saved places",
      state: .released
    )
    let first = RetrospectiveNote(
      productID: product.id,
      sprintID: sprint.id,
      workItemID: item.id,
      authorName: "Implementer",
      category: .suggestedAction,
      body: "Keep the managed JavaScript validation runtime available.",
      isActionCandidate: true,
      actionDestination: .teamPractice,
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let second = RetrospectiveNote(
      productID: product.id,
      sprintID: sprint.id,
      workItemID: item.id,
      authorName: "Implementer",
      category: .suggestedAction,
      body: "Ensure final checks can use the approved JavaScript runtime.",
      isActionCandidate: true,
      actionDestination: .teamPractice,
      createdAt: Date(timeIntervalSince1970: 2)
    )

    let prompt = CodexRetrospectiveSynthesizer.prompt(
      product: product,
      sprint: sprint,
      sourceNotes: [first, second],
      workItems: [item],
      existingActions: [],
      waysOfWorking: ""
    )
    #expect(prompt.contains("Return zero to five actions"))
    #expect(prompt.contains("E1 [Agent action candidate · T56 · Implementer]"))
    #expect(
      CodexRetrospectiveSynthesizer.outputSchema["properties"]?["actions"]?["maxItems"]
        == .integer(5)
    )

    let actions = try CodexRetrospectiveSynthesizer.decode(
      #"""
      {
        "actions":[{
          "body":"Make approved validation tools available before delivery begins.",
          "destination":"team_practice",
          "expectedEffect":"Handoffs include executed checks rather than repeated runtime blockers.",
          "sourceReferences":["E1","E2"]
        }]
      }
      """#,
      sourceNotes: [first, second]
    )
    #expect(actions.count == 1)
    #expect(actions.first?.sourceNoteIDs == [first.id, second.id])

    #expect(throws: RetrospectiveSynthesisGenerationError.self) {
      try CodexRetrospectiveSynthesizer.decode(
        #"""
        {
          "actions":[{
            "body":"Use the validation runtime.",
            "destination":"team_practice",
            "expectedEffect":"Checks can run.",
            "sourceReferences":["E3"]
          }]
        }
        """#,
        sourceNotes: [first, second]
      )
    }
  }
}

private actor ManagedCommandTransport: CodexRPCTransport {
  private let stream = AsyncStream<CodexInboundMessage> { _ in }
  private var commandParams: JSONValue?

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
    case "command/exec":
      commandParams = params
      return .object([
        "exitCode": .integer(0),
        "stdout": .string("compiled"),
        "stderr": .string(""),
      ])
    default:
      throw CodexRPCError(code: -32_601, message: "Unexpected request")
    }
  }

  func notify(method: String, params: JSONValue) {}
  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() {}
  func commandRequest() -> JSONValue? { commandParams }
}

private actor ApprovalTransport: CodexRPCTransport {
  struct Response: Sendable {
    let id: JSONValue
    let result: JSONValue
  }

  private let stream: AsyncStream<CodexInboundMessage>
  private let continuation: AsyncStream<CodexInboundMessage>.Continuation
  private var recordedResponse: Response?

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

  func respond(id: JSONValue, result: JSONValue) {
    recordedResponse = Response(id: id, result: result)
  }

  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() { continuation.finish() }
  func send(_ request: CodexServerRequest) { continuation.yield(.request(request)) }
  func response() -> Response? { recordedResponse }
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
    sendAgentMessage(
      threadID: threadID,
      turnID: turnID,
      phase: "final_answer",
      text: text
    )
  }

  func comment(threadID: String, turnID: String, text: String) {
    sendAgentMessage(
      threadID: threadID,
      turnID: turnID,
      phase: "commentary",
      text: text
    )
  }

  private func sendAgentMessage(
    threadID: String,
    turnID: String,
    phase: String,
    text: String
  ) {
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
              "phase": .string(phase),
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
                "phase": .string("final_answer"),
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
    case "thread/resume":
      guard let threadID = params["threadId"]?.stringValue else {
        throw CodexRPCError(code: -32_602, message: "Missing threadId")
      }
      return .object(["thread": .object(["id": .string(threadID)])])
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
