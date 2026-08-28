import Foundation
import Testing
import SpeditoTestSupport

@testable import SpeditoCore

@Suite("Codex App Server adapter", .serialized)
struct CodexAdapterTests {
  @Test("Client performs the required initialize handshake in order")
  func initializeHandshake() async throws {
    let transport = RecordingTransport(
      initializeResponse: .object([
        "userAgent": .string("codex-cli/0.144.0-alpha.4"),
        "codexHome": .string("/private/tmp/spedito-codex-home"),
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
    #expect(calls[1].params?["clientInfo"]?["name"]?.stringValue == "spedito")
    #expect(calls[1].params?["capabilities"]?["experimentalApi"]?.boolValue == true)
    #expect(calls[2].method == "initialized")

    await client.disconnect()
    #expect(await transport.wasStopped())
  }

  @Test("Rate limits preserve the dynamic windows reported by App Server")
  func dynamicRateLimitWindows() async throws {
    let transport = RecordingTransport(
      initializeResponse: .object([
        "userAgent": .string("codex-cli/test"),
        "codexHome": .string("/tmp/codex"),
        "platformFamily": .string("unix"),
        "platformOs": .string("macos"),
      ]),
      rateLimitsResponse: .object([
        "rateLimits": .object([
          "primary": .object([
            "usedPercent": .integer(22),
            "windowDurationMins": .integer(10_080),
            "resetsAt": .integer(1_780_000_000),
          ]),
          "secondary": .null,
          "rateLimitReachedType": .null,
        ])
      ])
    )
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let snapshot = try await client.readRateLimits()

    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows[0].id == "primary")
    #expect(snapshot.windows[0].windowDurationMinutes == 10_080)
    #expect(snapshot.windows[0].availablePercent == 78)
    #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_780_000_000))
    #expect(await transport.recordedCalls().last?.method == "account/rateLimits/read")
    await client.disconnect()
  }

  @Test("Rate-limit windows are ordered by duration and clamp percentages")
  func rateLimitWindowOrdering() {
    let snapshot = CodexRateLimitsSnapshot(
      response: .object([
        "rateLimits": .object([
          "primary": .object([
            "usedPercent": .integer(125),
            "windowDurationMins": .integer(10_080),
          ]),
          "secondary": .object([
            "usedPercent": .number(12.5),
            "windowDurationMins": .integer(300),
          ]),
          "rateLimitReachedType": .string("primary"),
        ])
      ])
    )

    #expect(snapshot.windows.map(\.windowDurationMinutes) == [300, 10_080])
    #expect(snapshot.windows.map(\.availablePercent) == [87.5, 0])
    #expect(snapshot.reachedLimitType == "primary")
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

  @Test("Runtime inspection output is parsed without depending on a system install")
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

  @Test("Runtime compatibility depends on capabilities rather than an exact version")
  func runtimeCompatibilityUsesCapabilities() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let executableURL = temporaryDirectory.appendingPathComponent("codex")
    let script = """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "codex-cli 99.4.1"
      else
        echo "request_permissions_tool under development true"
      fi
      """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )

    let descriptor = try CodexRuntimeResolver().resolve(
      candidates: [
        CodexRuntimeCandidate(executableURL: executableURL, source: .custom)
      ]
    )

    #expect(descriptor.version == "99.4.1")
    #expect(descriptor.source == .custom)
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
      workingDirectory: URL(fileURLWithPath: "/private/tmp/spedito-product"),
      developerInstructions: "Act as a BA",
      readOnlyProductDirectory: URL(
        fileURLWithPath: "/private/tmp/spedito-product/.spedito"
      )
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
        == [
          "/private/tmp/spedito-product",
          "/private/tmp/spedito-product/.spedito",
        ]
    )
    #expect(requests[1].params["permissionProfile"] == nil)
    #expect(requests[1].params["sandbox"] == nil)
    #expect(requests[1].params["approvalPolicy"]?.stringValue == "never")
    #expect(requests[2].params["approvalPolicy"] == nil)
    #expect(requests[2].params["outputSchema"] != nil)
    #expect(requests[2].params["summary"]?.stringValue == "concise")
  }

  @Test("Plain turns omit an output schema and can use ephemeral threads")
  func plainEphemeralTurn() async throws {
    let transport = SuggestionTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let threadID = try await client.startReadOnlyThread(
      workingDirectory: URL(fileURLWithPath: "/private/tmp/spedito-product"),
      developerInstructions: "Answer one chat question",
      ephemeral: true
    )
    _ = try await client.startTurn(
      threadID: threadID,
      prompt: "How does search work?",
      effort: "low"
    )
    let requests = await transport.requests()

    #expect(requests.map(\.method) == ["initialize", "thread/start", "turn/start"])
    #expect(requests[1].params["ephemeral"]?.boolValue == true)
    #expect(requests[2].params["outputSchema"] == nil)
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
      summary
        == .activity(
          CodexLiveActivity(text: "Inspecting provider evidence", kind: .inspecting)
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
      adjacentSummary
        == .activity(
          CodexLiveActivity(
            text: "Preparing the prototype artefact",
            kind: .thinking
          )
        )
    )

    let longSummaryParams = params.merging(["itemId": .string("item-long")]) { _, new in new }
    let longSummary = accumulator.consume(
      CodexNotification(
        method: "item/reasoning/summaryTextDelta",
        params: .object(
          longSummaryParams.merging([
            "delta": .string(String(repeating: "Reviewing repository evidence ", count: 7))
          ]) { _, new in new }
        )
      )
    )
    let latestLongSummary = accumulator.consume(
      CodexNotification(
        method: "item/reasoning/summaryTextDelta",
        params: .object(
          longSummaryParams.merging([
            "delta": .string("Confirming the relative launch paths.")
          ]) { _, new in new }
        )
      )
    )
    #expect(longSummary != latestLongSummary)
    if case .activity(let latestActivity) = latestLongSummary {
      #expect(latestActivity.text.hasPrefix("…"))
      #expect(latestActivity.text.hasSuffix("Confirming the relative launch paths."))
      #expect(latestActivity.text.count <= 150)
    } else {
      Issue.record("Expected the latest supported reasoning summary")
    }

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
      fileChange
        == .activity(
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
      workingDirectory: URL(fileURLWithPath: "/private/tmp/spedito-product"),
      developerInstructions: "Execute one ticket",
      model: "gpt-5.6-terra",
      readOnlyGitDirectory: URL(
        fileURLWithPath: "/private/tmp/spedito-canonical-product/.git"
      ),
      writableTransientStorageRoots: [
        URL(fileURLWithPath: "/private/var/folders/example/T"),
        URL(fileURLWithPath: "/private/var/folders/example/C"),
        URL(fileURLWithPath: "/Users/example/Library/Caches"),
      ]
    )
    let turnID = try await client.startStructuredTurn(
      threadID: threadID,
      prompt: "Deliver the ticket",
      effort: "medium",
      outputSchema: CodexTicketExecutor.outputSchema(deliveryDemoPolicy: .anyKind),
      runtimeWorkspaceRoots: [
        URL(fileURLWithPath: "/private/tmp/spedito-product")
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
        == ["/private/tmp/spedito-product"]
    )
    #expect(requests[1].params["permissionProfile"] == nil)
    #expect(requests[1].params["sandbox"] == nil)
    #expect(requests[1].params["approvalPolicy"]?.stringValue == "on-request")
    #expect(requests[1].params["model"]?.stringValue == "gpt-5.6-terra")
    let deliveryConfig =
      requests[1].params["config"]?["permissions.spedito-delivery"]
    #expect(
      deliveryConfig?["filesystem"]?[
        "/private/tmp/spedito-canonical-product/.git"
      ]?.stringValue == "read"
    )
    #expect(
      deliveryConfig?["filesystem"]?[
        "/private/tmp/spedito-canonical-product/.spedito"
      ]?.stringValue == "read"
    )
    #expect(
      deliveryConfig?["filesystem"]?[":workspace_roots"]?["."]?.stringValue
        == "write"
    )
    #expect(
      deliveryConfig?["filesystem"]?["/private/var/folders/example/T"]?.stringValue
        == "write"
    )
    #expect(
      deliveryConfig?["filesystem"]?["/private/var/folders/example/C"]?.stringValue
        == "write"
    )
    #expect(
      deliveryConfig?["filesystem"]?["/Users/example/Library/Caches"]?.stringValue
        == "write"
    )
    #expect(requests[2].params["permissions"] == nil)
    #expect(
      requests[2].params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue)
        == ["/private/tmp/spedito-product"]
    )
    #expect(requests[2].params["permissionProfile"] == nil)
  }

  @Test("Persisted conversations are explicitly resumed with their scoped permissions")
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
      readOnlyGitDirectory: URL(fileURLWithPath: "/private/tmp/product/.git"),
      writableTransientStorageRoots: [
        URL(fileURLWithPath: "/private/var/folders/resumed/T"),
        URL(fileURLWithPath: "/Users/example/Library/Caches"),
      ]
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
      requests[2].params["config"]?["permissions.spedito-delivery"]?[
        "filesystem"
      ]?["/private/tmp/product/.git"]?.stringValue == "read"
    )
    #expect(
      requests[2].params["config"]?["permissions.spedito-delivery"]?[
        "filesystem"
      ]?["/private/tmp/product/.spedito"]?.stringValue == "read"
    )
    #expect(
      requests[2].params["config"]?["permissions.spedito-delivery"]?[
        "filesystem"
      ]?["/private/var/folders/resumed/T"]?.stringValue == "write"
    )
  }

  @Test("macOS transient storage roots are canonical, bounded, and de-duplicated")
  func macOSStorageRootNormalization() {
    let roots = CodexPermissionProfiles.normalizedStorageRoots(
      darwinTemporaryDirectory: URL(fileURLWithPath: "/var/folders/example/T/"),
      darwinCacheDirectory: URL(fileURLWithPath: "/var/folders/example/C/"),
      foundationCacheDirectory: URL(fileURLWithPath: "/Users/example/Library/Caches/")
    ).map(\.path)

    #expect(
      roots == [
        "/private/var/folders/example/T",
        "/private/var/folders/example/C",
        "/Users/example/Library/Caches",
      ])
    #expect(
      CodexPermissionProfiles.normalizedStorageRoots(
        darwinTemporaryDirectory: URL(fileURLWithPath: "/"),
        darwinCacheDirectory: URL(fileURLWithPath: "/private/tmp/cache"),
        foundationCacheDirectory: URL(fileURLWithPath: "/private/tmp/cache/.")
      ).map(\.path) == ["/private/tmp/cache"]
    )
    #expect(
      CodexPermissionProfiles.managedDemoTransientStorageRoots(
        from: roots.map { URL(fileURLWithPath: $0, isDirectory: true) },
        protectedStorageRoots: [
          URL(
            fileURLWithPath:
              "/Users/example/Library/Caches/Spedito/PreviewWorktrees",
            isDirectory: true
          )
        ]
      ).map(\.path) == [
        "/private/var/folders/example/T",
        "/private/var/folders/example/C",
      ]
    )
  }

  @Test("Delivery isolates the ticket while demos retain reviewed runtime reads")
  func managedPermissionProfiles() throws {
    let arguments = CodexPermissionProfiles.appServerArguments.joined(separator: " ")
    #expect(
      arguments.contains(CodexPermissionProfiles.requestPermissionsFeatureOverride)
    )
    #expect(arguments.contains(#"":minimal"="read""#))
    #expect(arguments.contains(#"":root"="read""#))
    #expect(arguments.contains(#""~/.codex"="deny""#))
    #expect(arguments.contains(#""~/Library/Application Support/Spedito"="deny""#))
    #expect(
      arguments.contains(
        #""~/Library/Application Support/Spedito/spedito.sqlite"="deny""#
      )
    )
    #expect(
      arguments.contains(
        #""~/Library/Application Support/StoryPointless/storypointless.sqlite"="deny""#
      )
    )
    #expect(
      !CodexPermissionProfiles.deliveryProfileOverride.contains(
        #""~/Library/Application Support/Spedito"="deny""#
      )
    )
    #expect(!CodexPermissionProfiles.deliveryProfileOverride.contains(#"":root"="read""#))
    #expect(arguments.contains(#""localhost"="allow""#))
    #expect(!arguments.contains("openssl.cnf"))
    #expect(!arguments.contains("/opt/homebrew/bin"))

    let demoWorkspace = URL(
      fileURLWithPath: "/Users/example/Library/Caches/Spedito/PreviewWorktrees/candidate"
    )
    let scopedArguments = CodexPermissionProfiles.appServerArguments(
      demoWorkspaceRoot: demoWorkspace,
      writableTransientStorageRoots: [
        URL(fileURLWithPath: "/private/var/folders/example/T"),
        URL(fileURLWithPath: "/private/var/folders/example/C"),
        URL(fileURLWithPath: "/Users/example/Library/Caches"),
      ]
    )
    let demoOverride = try #require(
      scopedArguments.first { $0.hasPrefix("permissions.spedito-demo=") }
    )
    let deliveryOverride = try #require(
      scopedArguments.first { $0.hasPrefix("permissions.spedito-delivery=") }
    )
    #expect(
      demoOverride.contains(
        #"workspace_roots={"/Users/example/Library/Caches/Spedito/PreviewWorktrees/candidate"=true}"#
      ))
    #expect(demoOverride.contains(#""/private/var/folders/example/T"="write""#))
    #expect(demoOverride.contains(#""/private/var/folders/example/C"="write""#))
    #expect(!demoOverride.contains(#""/Users/example/Library/Caches"="write""#))
    #expect(deliveryOverride.contains(#""/Users/example/Library/Caches"="write""#))
    let protectedPreviewRoot =
      CodexPermissionProfiles.protectedSpeditoDeliveryStorageRoots.first {
        $0.path.contains("/Library/Caches/Spedito/PreviewWorktrees")
      }
    #expect(
      protectedPreviewRoot.map {
        !demoOverride.contains(#""\#($0.path)"="deny""#)
          && deliveryOverride.contains(#""\#($0.path)"="deny""#)
      } == true
    )
    #expect(!arguments.contains(demoWorkspace.path))

    let deliveryConfig = CodexPermissionProfiles.deliveryThreadConfiguration(
      readOnlyGitDirectory: URL(fileURLWithPath: "/private/tmp/product/.git"),
      writableTransientStorageRoots: [
        URL(fileURLWithPath: "/Users/example/Library/Caches")
      ],
      protectedStorageRoots: [
        URL(fileURLWithPath: "/Users/example/Library/Caches/Spedito/PreviewWorktrees")
      ]
    )
    #expect(
      deliveryConfig["permissions.spedito-delivery"]?["filesystem"]?[
        "/Users/example/Library/Caches"
      ]?.stringValue == "write"
    )
    #expect(
      deliveryConfig["permissions.spedito-delivery"]?["filesystem"]?[
        "/Users/example/Library/Caches/Spedito/PreviewWorktrees"
      ]?.stringValue == "deny"
    )
  }

  @Test("Delivery selects Apple developer tools without broadening Git access")
  func managedGitEnvironment() {
    let environment = CodexPermissionProfiles.agentProcessEnvironment(
      inherited: [
        "PATH": "/usr/bin:/bin",
        "HOME": "/tmp/home",
        "GH_TOKEN": "secret",
      ],
      developerDirectory: "/Applications/Xcode.app/Contents/Developer"
    )

    #expect(environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
    #expect(
      environment["PATH"]
        == "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core:/usr/bin:/bin"
    )
    #expect(environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
    #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
    #expect(environment["GIT_PAGER"] == "cat")
    #expect(environment["GH_TOKEN"] == nil)
    #expect(
      CodexPermissionProfiles.agentProcessEnvironment(
        inherited: [:],
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
      "SpeditoBoundaryTests-\(UUID())",
      isDirectory: true
    )
    let workspace =
      boundaryRoot
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

  @Test("Delivery can read product Git and context without changing either")
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
      "SpeditoGitBoundaryTests-\(UUID())",
      isDirectory: true
    )
    let repository =
      boundaryRoot
      .appendingPathComponent("Product Workspaces", isDirectory: true)
      .appendingPathComponent("product", isDirectory: true)
    let worktrees =
      boundaryRoot
      .appendingPathComponent("Run Worktrees", isDirectory: true)
      .appendingPathComponent("product", isDirectory: true)
    let otherProductGit =
      boundaryRoot
      .appendingPathComponent("Product Workspaces", isDirectory: true)
      .appendingPathComponent("other-product", isDirectory: true)
      .appendingPathComponent(".git", isDirectory: true)
    let productControl = repository.appendingPathComponent(
      ProductStoreRegistry.controlDirectoryName,
      isDirectory: true
    )
    let otherProductControl =
      otherProductGit
      .deletingLastPathComponent()
      .appendingPathComponent(
        ProductStoreRegistry.controlDirectoryName,
        isDirectory: true
      )
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
    try FileManager.default.createDirectory(
      at: productControl,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: otherProductControl,
      withIntermediateDirectories: true
    )
    try Data("other product\n".utf8).write(
      to: otherProductGit.appendingPathComponent("private-object")
    )
    try Data("active context\n".utf8).write(
      to: productControl.appendingPathComponent("context.txt")
    )
    try Data("other context\n".utf8).write(
      to: otherProductControl.appendingPathComponent("context.txt")
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
        readOnlyGitDirectory: gitDirectory,
        readOnlyProductDirectory: productControl
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
      test "$(cat "\(productControl.appendingPathComponent("context.txt").path)")" \
        = "active context" || exit 14
      printf changed >> "\(productControl.appendingPathComponent("context.txt").path)" \
        >/dev/null 2>&1 && exit 15
      cat "\(otherProductControl.appendingPathComponent("context.txt").path)" \
        >/dev/null 2>&1 && exit 16
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

  @Test("Delivery can write transient roots without crossing into preview storage")
  func deliveryTransientStorageBoundary() async throws {
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
    let workspace = applicationSupport.appendingPathComponent(
      "SpeditoTransientBoundaryTests-\(UUID())",
      isDirectory: true
    )
    let transientDirectories = CodexPermissionProfiles.macOSUserTransientStorageRoots
      .enumerated()
      .map { index, root in
        root.appendingPathComponent(
          "SpeditoTransientBoundaryTests-\(index)-\(UUID())",
          isDirectory: true
        )
      }
    let previewRoot = try #require(
      CodexPermissionProfiles.protectedSpeditoDeliveryStorageRoots.first {
        $0.path.contains("/Library/Caches/Spedito/PreviewWorktrees")
      }
    )
    let protectedPreview = previewRoot.appendingPathComponent(
      "SpeditoTransientBoundaryTests-\(UUID())",
      isDirectory: true
    )
    defer {
      try? FileManager.default.removeItem(at: workspace)
      for directory in transientDirectories {
        try? FileManager.default.removeItem(at: directory)
      }
      try? FileManager.default.removeItem(at: protectedPreview)
    }
    try FileManager.default.createDirectory(
      at: workspace,
      withIntermediateDirectories: true
    )
    for directory in transientDirectories {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    }
    try FileManager.default.createDirectory(
      at: protectedPreview,
      withIntermediateDirectories: true
    )

    let transientChecks = transientDirectories.indices.map { index in
      #"printf ready > "$SPEDITO_TRANSIENT_\#(index)/proof.txt" || exit \#(10 + index)"#
    }
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
      (transientChecks + [
        #"printf blocked > "$SPEDITO_PROTECTED_PREVIEW/proof.txt" 2>/dev/null && exit 30"#,
        "exit 0",
      ]).joined(separator: "\n"),
    ]
    process.currentDirectoryURL = workspace
    var environment = ProcessInfo.processInfo.environment
    for (index, directory) in transientDirectories.enumerated() {
      environment["SPEDITO_TRANSIENT_\(index)"] = directory.path
    }
    environment["SPEDITO_PROTECTED_PREVIEW"] = protectedPreview.path
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    #expect(
      process.terminationStatus == 0,
      Comment(rawValue: String(decoding: data, as: UTF8.self))
    )
    for directory in transientDirectories {
      #expect(
        try String(
          contentsOf: directory.appendingPathComponent("proof.txt"),
          encoding: .utf8
        ) == "ready"
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: protectedPreview.appendingPathComponent("proof.txt").path
      )
    )
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
    let previewRoot = try #require(
      CodexPermissionProfiles.protectedSpeditoDeliveryStorageRoots.first {
        $0.path.contains("/Library/Caches/Spedito/PreviewWorktrees")
      }
    )
    let workspace = previewRoot.appendingPathComponent(
      "spedito-scoped-command-\(UUID())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: workspace,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: workspace) }

    let executor = CodexWorkspaceCommandExecutor(executableURL: codexURL)
    let nestedBuildDirectory =
      workspace
      .appendingPathComponent(".build", isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
    let mkdirResult = try await executor.runManagedCommand(
      CodexManagedCommandRequest(
        command: ["/bin/mkdir", "-p", nestedBuildDirectory.path],
        workingDirectory: workspace,
        workspaceRoot: workspace,
        timeoutSeconds: 10
      )
    )
    #expect(
      mkdirResult.exitCode == 0,
      Comment(rawValue: mkdirResult.combinedOutput)
    )
    #expect(
      FileManager.default.fileExists(atPath: nestedBuildDirectory.path)
    )

    let result = try await executor.runManagedCommand(
      CodexManagedCommandRequest(
        command: [
          "/opt/homebrew/bin/node",
          "--eval",
          "const fs=require('node:fs');fs.readFileSync('/opt/homebrew/etc/openssl@3/openssl.cnf');fs.writeFileSync('.build/tmp/proof.txt','ready');process.stdout.write('ready')",
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
        contentsOf: nestedBuildDirectory.appendingPathComponent("proof.txt"),
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
        workingDirectory: URL(fileURLWithPath: "/private/tmp/spedito-preview"),
        environment: ["TMPDIR": "/private/tmp/spedito-demo"],
        timeoutSeconds: 30
      )
    )
    let command = try #require(await transport.commandRequest())

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "compiled")
    #expect(
      command["command"]?.arrayValue?.compactMap(\.stringValue) == [
        "python3", "-m", "compileall", ".",
      ])
    #expect(command["permissionProfile"]?.stringValue == CodexPermissionProfiles.demo)
    #expect(command["timeoutMs"]?.integerValue == 30_000)
  }

  /// A live pilot run asked the product owner to allow "Network access" for a
  /// capability the agent described as localhost-only. The saved grant already
  /// distinguished the two, so the broader wording appeared where consent is
  /// given and the narrower one only where it is recorded.
  @Test("A scoped network request is not worded as full network access")
  func scopedNetworkApprovalSaysItIsRestricted() throws {
    func presentationDetail(network: JSONValue) throws -> String {
      try CodexAppServerClient.approvalPresentation(
        for: CodexServerRequest(
          id: .integer(1),
          method: "item/permissions/requestApproval",
          params: .object([
            "threadId": .string("thread-permissions"),
            "turnId": .string("turn-permissions"),
            "permissions": .object(["network": network]),
          ])
        )
      ).detail
    }

    let unrestricted = JSONValue.object(["enabled": .bool(true)])
    #expect(try presentationDetail(network: unrestricted) == "Network access")
    #expect(AgentPermissionGrantPolicy.isUnrestrictedNetwork(unrestricted))

    let loopbackOnly = JSONValue.object([
      "enabled": .bool(true),
      "allowedHosts": .array([.string("127.0.0.1")]),
    ])
    #expect(try presentationDetail(network: loopbackOnly) == "Restricted network access")
    #expect(!AgentPermissionGrantPolicy.isUnrestrictedNetwork(loopbackOnly))

    // A refused capability still says nothing about the network.
    #expect(
      try presentationDetail(network: .object(["enabled": .bool(false)]))
        == "Codex requested access outside the ticket workspace."
    )
  }

  /// A live native macOS run left two tickets reporting a working agent for
  /// fifty minutes after their turns had already finished. The turn's wait
  /// suspends its inactivity timeout while the turn is awaiting an approval, and
  /// the flag that says so was cleared only after the response was delivered
  /// successfully. One failed delivery therefore left the turn waiting with
  /// nothing left to time it out.
  @Test("A failed approval response still releases the turn's inactivity timeout")
  func failedApprovalResponseReleasesTheTurn() async throws {
    let transport = ApprovalTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    let messages = await client.inboundMessages(replayRecent: false)
    let request = CodexServerRequest(
      id: .integer(7),
      method: "item/permissions/requestApproval",
      params: .object([
        "threadId": .string("thread-hang"),
        "turnId": .string("turn-hang"),
        "permissions": .object(["network": .object(["enabled": .bool(true)])]),
      ])
    )
    await transport.send(request)
    let received = await messages.first { if case .request = $0 { return true } else { return false } }
    guard case .request(let approval)? = received else {
      Issue.record("Expected an approval request")
      return
    }

    await transport.failNextRespond(
      with: CodexRPCError(code: -32_000, message: "The response could not be delivered.")
    )
    await #expect(throws: (any Error).self) {
      try await client.resolveApprovalRequest(approval, allow: false)
    }

    // The turn is no longer awaiting anything, so its inactivity window applies
    // and the wait ends by itself rather than hanging.
    let started = ContinuousClock.now
    await #expect(throws: (any Error).self) {
      _ = try await client.waitForFinalAgentMessage(
        threadID: "thread-hang",
        turnID: "turn-hang",
        timeout: .seconds(1),
        reconciliationInterval: .seconds(30),
        totalTimeout: .seconds(20)
      )
    }
    #expect(ContinuousClock.now - started < .seconds(10))
  }

  /// Two live runs hung exactly this way. Their turns had finished, every
  /// permission request in the product database had reached a terminal status,
  /// and the board reported a working agent for the remaining fifty minutes of
  /// the run — because an entry in the client's own pending-approval map
  /// suspended the only timeout that could have ended the wait.
  ///
  /// The client's map is transient operation state. Whether the product owner
  /// owes a decision is durable domain state, and an unbounded wait has to rest
  /// on the durable answer.
  @Test("A pending approval the database does not know about cannot suspend a turn forever")
  func staleApprovalFlagDoesNotSuspendTheTurn() async throws {
    func waitWithOwnerDecision(outstanding: Bool) async -> Duration {
      let transport = ApprovalTransport()
      let client = CodexAppServerClient(transport: transport)
      _ = try? await client.connect()
      let messages = await client.inboundMessages(replayRecent: false)
      await transport.send(
        CodexServerRequest(
          id: .integer(11),
          method: "item/permissions/requestApproval",
          params: .object([
            "threadId": .string("thread-stale"),
            "turnId": .string("turn-stale"),
            "permissions": .object(["network": .object(["enabled": .bool(true)])]),
          ])
        )
      )
      // Routing the request is what registers it, and nothing ever resolves it.
      _ = await messages.first {
        if case .request = $0 { return true } else { return false }
      }

      let started = ContinuousClock.now
      _ = try? await client.waitForFinalAgentMessage(
        threadID: "thread-stale",
        turnID: "turn-stale",
        timeout: .seconds(1),
        reconciliationInterval: .seconds(30),
        totalTimeout: .seconds(6),
        ownerDecisionIsOutstanding: { outstanding }
      )
      return ContinuousClock.now - started
    }

    // Nothing in the database is waiting on the owner, so the turn's inactivity
    // window applies and the wait ends by itself instead of hanging.
    #expect(await waitWithOwnerDecision(outstanding: false) < .seconds(4))

    // And a turn the owner really does owe an answer on still waits. Cutting
    // that short would fail runs that are behaving correctly.
    #expect(await waitWithOwnerDecision(outstanding: true) > .seconds(4))
  }

  /// A live run put this on a product owner's screen: "The delivery agent
  /// returned an invalid execution result: The demo could not be prepared
  /// safely: the demo artifact path is incomplete." Three layers of
  /// implementation detail and nothing they can act on.
  @Test("A delivery failure reaches the owner as one explanation, not a chain")
  func deliveryFailuresAreOwnerFacing() {
    let chained = TicketExecutionGenerationError.invalidResponse(
      DemoLaunchValidationError.invalid("the demo artifact path is incomplete")
        .localizedDescription
    )

    // The detail is still there for the repair prompt and the log.
    #expect(chained.localizedDescription.contains("demo artifact path is incomplete"))

    let owner = chained.ownerFacingDescription
    #expect(!owner.contains("execution result"))
    #expect(!owner.contains("artifact path"))
    #expect(owner.components(separatedBy: ": ").count == 1)
    #expect(owner.contains("Retry the work"))

    // An error with no owner-facing form still says something rather than
    // nothing, so adopting this stays incremental.
    struct Plain: Error, LocalizedError {
      var errorDescription: String? { "Something went wrong." }
    }
    #expect(Plain().ownerFacingDescription == "Something went wrong.")
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
              ]),
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

  @Test("Native file-change approvals are declined before application routing")
  func nativeFileChangeApprovalIsNotRouted() async throws {
    let transport = ApprovalTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    let messages = await client.inboundMessages(replayRecent: false)
    let fileChangeRequest = CodexServerRequest(
      id: .integer(96),
      method: "item/fileChange/requestApproval",
      params: .object([
        "threadId": .string("thread-delivery"),
        "turnId": .string("turn-delivery"),
        "itemId": .string("item-file-change"),
        "reason": .string("Change a file outside the ticket workspace"),
      ])
    )
    let structuredPermissionRequest = CodexServerRequest(
      id: .integer(97),
      method: "item/permissions/requestApproval",
      params: .object([
        "threadId": .string("thread-delivery"),
        "turnId": .string("turn-delivery"),
        "itemId": .string("item-permission"),
        "permissions": .object([
          "fileSystem": .object([
            "entries": .array([
              .object([
                "access": .string("write"),
                "path": .object([
                  "type": .string("path"),
                  "path": .string("/Users/example/.config/example/settings.json"),
                ]),
              ])
            ])
          ])
        ]),
        "reason": .string("Apply the product owner's requested global setting"),
      ])
    )

    await transport.send(fileChangeRequest)
    await transport.send(structuredPermissionRequest)

    let firstRoutedRequest = await messages.first { message in
      if case .request = message { return true }
      return false
    }
    guard case .request(let routedRequest) = firstRoutedRequest else {
      Issue.record("Expected the structured permission request")
      return
    }
    #expect(routedRequest.id == .integer(97))
    #expect(routedRequest.method == "item/permissions/requestApproval")
    let response = try #require(await transport.response())
    #expect(response.id == .integer(96))
    #expect(response.result["decision"]?.stringValue == "decline")
  }

  @Test("An inactive turn times out and is interrupted")
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

  @Test("Matching turn activity restarts the inactivity timeout")
  func turnActivityRestartsTimeout() async throws {
    let transport = ConcurrentTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    async let result = client.waitForFinalAgentMessage(
      threadID: "thread-active",
      turnID: "turn-active",
      timeout: .seconds(1)
    )

    try await Task.sleep(for: .milliseconds(400))
    await transport.comment(
      threadID: "thread-active",
      turnID: "turn-active",
      text: "Inspecting supplied ticket context."
    )
    try await Task.sleep(for: .milliseconds(700))
    await transport.complete(
      threadID: "thread-active",
      turnID: "turn-active",
      text: #"{"message":"Completed after more than the original timeout."}"#
    )

    #expect(
      try await result
        == #"{"message":"Completed after more than the original timeout."}"#
    )
  }

  @Test("A total turn timeout is not extended by activity")
  func totalTurnTimeoutIsNotExtended() async throws {
    let transport = ConcurrentTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()

    let result = Task {
      try await client.waitForFinalAgentMessage(
        threadID: "thread-total-timeout",
        turnID: "turn-total-timeout",
        timeout: .seconds(1),
        totalTimeout: .milliseconds(50)
      )
    }

    try await Task.sleep(for: .milliseconds(20))
    await transport.comment(
      threadID: "thread-total-timeout",
      turnID: "turn-total-timeout",
      text: "Still working."
    )

    await #expect(throws: CodexClientError.turnTimedOut(seconds: 1)) {
      _ = try await result.value
    }
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
    let transport = ScriptedCodexTransport(
      responses: [
        .init(
          method: "initialize",
          result: .object([
            "userAgent": .string("codex-cli/test"),
            "codexHome": .string("/private/tmp/codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
          ])
        )
      ],
      inboundMessages: [
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
      ]
    )
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

  @Test("A final-answer item does not finish the waiter before its turn completes")
  func finalAnswerWaitsForTurnCompletion() async throws {
    let transport = ConcurrentTurnTransport()
    let client = CodexAppServerClient(transport: transport)
    let completion = CompletionProbe()
    _ = try await client.connect()

    let waiter = Task {
      let result = try await client.waitForFinalAgentMessage(
        threadID: "thread-ordering",
        turnID: "turn-ordering"
      )
      await completion.markFinished()
      return result
    }

    let expected = #"{"status":"awaiting_owner","question":"Choose one"}"#
    await transport.completeMessageOnly(
      threadID: "thread-ordering",
      turnID: "turn-ordering",
      text: expected
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await completion.isFinished))

    await transport.finishTurn(
      threadID: "thread-ordering",
      turnID: "turn-ordering"
    )

    #expect(try await waiter.value == expected)
    #expect(await completion.isFinished)
  }

  @Test("Suggestion decoder validates roles and dependency references")
  func suggestionDecoding() throws {
    let response = #"""
      {
        "environmentAssessment":{
          "readiness":"sufficient",
          "rationale":"The verified environment covers the proposed executable work.",
          "foundationTicketReference":null
        },
        "suggestions":[
        {"reference":"T1","title":"Choose provider","type":"task","body":"Compare options","acceptanceCriteria":["Trade-offs are clear"],"role":"business_analyst","priority":"high","rationale":"Defines the contract","dependsOn":[],"environmentRelationship":"independent"},
        {"reference":"T2","title":"Prototype","type":"task","body":"Design states","acceptanceCriteria":["Owner can review"],"role":"ux_designer","priority":"high","rationale":"Validates the experience","dependsOn":[],"environmentRelationship":"independent"},
        {"reference":"T3","title":"Build UI","type":"story","body":"Implement it","acceptanceCriteria":["Forecast is visible"],"role":"implementer","priority":"normal","rationale":"Creates value","dependsOn":["T1","T2"],"environmentRelationship":"requires"}
        ]
      }
      """#
    let suggestions = try CodexTicketSuggestionGenerator.decode(response)
    #expect(suggestions.count == 3)
    #expect(suggestions.map(\.reference) == ["S1", "S2", "S3"])
    #expect(suggestions.map(\.type) == [.task, .task, .story])
    #expect(suggestions[2].suggestedRole == .implementer)
    #expect(suggestions[2].dependsOnReferences == ["S1", "S2"])
    #expect(suggestions[2].environmentRelationship == .requires)

    let looselyFormatted = #"""
      {
        "environmentAssessment":{
          "readiness":"sufficient",
          "rationale":"The verified environment covers the work.",
          "foundationTicketReference":null
        },
        "suggestions":[
        {"reference":" t-1 ","title":"Choose provider","type":"task","body":"Compare options","acceptanceCriteria":["Trade-offs are clear"],"role":"business_analyst","priority":"high","rationale":"Defines the contract","dependsOn":[],"environmentRelationship":"independent"},
        {"reference":"T 2","title":"Build UI","type":"story","body":"Implement it","acceptanceCriteria":["Forecast is visible"],"role":"implementer","priority":"normal","rationale":"Creates value","dependsOn":["T-1"],"environmentRelationship":"requires"}
        ]
      }
      """#
    let normalized = try CodexTicketSuggestionGenerator.decode(looselyFormatted)
    #expect(normalized.map(\.reference) == ["S1", "S2"])
    #expect(normalized[1].dependsOnReferences == ["S1"])

    let minimal =
      #"{"environmentAssessment":{"readiness":"sufficient","rationale":"The verified environment covers the work.","foundationTicketReference":null},"suggestions":[{"reference":"T1","title":"Ship one bounded outcome","type":"story","body":"Keep the scope coherent","acceptanceCriteria":["The outcome is visible"],"role":"implementer","priority":"normal","rationale":"The product is deliberately small","dependsOn":[],"environmentRelationship":"requires"}]}"#
    #expect(try CodexTicketSuggestionGenerator.decode(minimal).count == 1)

    let cyclic =
      #"{"environmentAssessment":{"readiness":"not_required","rationale":"These tasks need no executable environment.","foundationTicketReference":null},"suggestions":[{"reference":"T1","title":"First","type":"task","body":"First","acceptanceCriteria":["Done"],"role":"implementer","priority":"normal","rationale":"First","dependsOn":["T2"],"environmentRelationship":"independent"},{"reference":"T2","title":"Second","type":"task","body":"Second","acceptanceCriteria":["Done"],"role":"implementer","priority":"normal","rationale":"Second","dependsOn":["T1"],"environmentRelationship":"independent"}]}"#
    #expect(throws: TicketSuggestionGenerationError.self) {
      try CodexTicketSuggestionGenerator.decode(cyclic)
    }

    let foundationWithoutDependency =
      #"{"environmentAssessment":{"readiness":"foundation_required","rationale":"The product has no delivery environment.","foundationTicketReference":"T1"},"suggestions":[{"reference":"T1","title":"Build the first feature","type":"story","body":"Build it without establishing the missing environment.","acceptanceCriteria":["The feature works"],"role":"implementer","priority":"normal","rationale":"Delivers value.","dependsOn":[],"environmentRelationship":"requires"}]}"#
    #expect(throws: TicketSuggestionGenerationError.self) {
      try CodexTicketSuggestionGenerator.decode(foundationWithoutDependency)
    }

    let existing = WorkItem(productID: UUID(), key: "T-7", title: "Existing work")
    let crossLinked = #"""
      {
        "environmentAssessment":{
          "readiness":"sufficient",
          "rationale":"The existing foundation covers the work.",
          "foundationTicketReference":null
        },
        "suggestions":[
        {"reference":"T1","title":"Add the missing integration","type":"story","body":"Use the existing contract","acceptanceCriteria":["The integration works"],"role":"implementer","priority":"normal","rationale":"Completes the flow","dependsOn":["T-7"],"environmentRelationship":"requires"}
        ]
      }
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
    let developerInstructions = CodexSprintGoalGenerator.developerInstructions
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
    #expect(developerInstructions.contains("Use only the supplied ticket titles"))
    #expect(!developerInstructions.contains("INTERNAL ROLE GUIDANCE"))
    #expect(!developerInstructions.contains("LIVE PRODUCT CONTEXT"))
    #expect(CodexSprintGoalGenerator.totalTimeout == .seconds(15))
    #expect(
      CodexSprintGoalGenerator.lightestReasoningEffort(
        supportedEfforts: ["medium", "high"],
        fallback: "high"
      ) == "medium"
    )
    #expect(
      CodexSprintGoalGenerator.lightestReasoningEffort(
        supportedEfforts: ["high", "low", "medium"],
        fallback: "high"
      ) == "low"
    )
    #expect(
      CodexSprintGoalGenerator.lightestReasoningEffort(
        supportedEfforts: [],
        fallback: "high"
      ) == "high"
    )
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
          "constraints": "Keep saved data on the device.",
          "environmentAssessment": {
            "readiness": "sufficient",
            "rationale": "The verified web environment covers this work.",
            "foundationTicketReference": null
          }
        },
        "suggestions": [
          {
            "reference": "T1",
            "title": "Design saved-location states",
            "type": "task",
            "body": "Define empty, saved, and removed states.",
            "acceptanceCriteria": ["The product owner can review every state"],
            "role": "ux_designer",
            "priority": "high",
            "rationale": "The interaction needs an agreed direction.",
            "dependsOn": [],
            "environmentRelationship": "independent"
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
            "dependsOn": ["T1"],
            "environmentRelationship": "requires"
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
    #expect(plan.environmentAssessment.readiness == .sufficient)
  }

  @Test("Epic planning validates a missing environment and its dependency path")
  func epicPlanningEnvironmentFoundation() throws {
    let response = #"""
      {
        "epic": {
          "title": "First runnable forecast",
          "goal": "Customers can search for a place and see its forecast.",
          "successCriteria": ["The forecast can be built, tested, demonstrated, and reviewed locally"],
          "constraints": "Use the simplest suitable web stack.",
          "environmentAssessment": {
            "readiness": "foundation_required",
            "rationale": "The product has no verified build, test, local-run, or demo environment.",
            "foundationTicketReference": "T2"
          }
        },
        "suggestions": [
          {
            "reference": "T1",
            "title": "Recommend the technical foundation",
            "type": "task",
            "body": "Compare the authorised stack and hosting choices.",
            "acceptanceCriteria": ["The product owner can approve one recommendation"],
            "role": "business_analyst",
            "priority": "high",
            "rationale": "A material stack choice needs authorised evidence.",
            "dependsOn": [],
            "environmentRelationship": "independent"
          },
          {
            "reference": "T2",
            "title": "Establish the delivery environment",
            "type": "task",
            "body": "Create the approved toolchain and stable repository entry points.",
            "acceptanceCriteria": [
              "Build, test, local-run, and demo commands pass in the delivery sandbox",
              "Run-private caches and required capabilities are verified",
              "The Environments product knowledge article records the complete contract"
            ],
            "role": "implementer",
            "priority": "high",
            "rationale": "Future delivery needs one reusable environment.",
            "dependsOn": ["T1"],
            "environmentRelationship": "establishes"
          },
          {
            "reference": "T3",
            "title": "Design the forecast journey",
            "type": "task",
            "body": "Produce a neutral review artefact.",
            "acceptanceCriteria": ["The product owner can review the journey"],
            "role": "ux_designer",
            "priority": "normal",
            "rationale": "The neutral artefact can proceed in parallel.",
            "dependsOn": [],
            "environmentRelationship": "independent"
          },
          {
            "reference": "T4",
            "title": "Deliver the forecast",
            "type": "story",
            "body": "Implement the agreed journey in the established environment.",
            "acceptanceCriteria": ["The managed demo shows a forecast"],
            "role": "implementer",
            "priority": "normal",
            "rationale": "This delivers the customer outcome.",
            "dependsOn": ["T2", "T3"],
            "environmentRelationship": "requires"
          }
        ]
      }
      """#

    let plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(response)

    #expect(plan.environmentAssessment.readiness == .foundationRequired)
    #expect(plan.environmentAssessment.foundationTicketReference == "S2")
    #expect(plan.ticketSuggestions[1].environmentRelationship == .establishes)
    #expect(plan.ticketSuggestions[3].dependsOnReferences.contains("S2"))

    let missingDependency = response.replacingOccurrences(
      of: #""dependsOn": ["T2", "T3"]"#,
      with: #""dependsOn": ["T3"]"#
    )
    #expect(throws: TicketSuggestionGenerationError.self) {
      try CodexTicketSuggestionGenerator.decodeEpicPlan(missingDependency)
    }
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
          "constraints": "Use an approved public provider.",
          "environmentAssessment": {
            "readiness": "not_required",
            "rationale": "The proposed plan contains research only.",
            "foundationTicketReference": null
          }
        },
        "suggestions": [
          {
            "reference": "S1",
            "title": "Recommend a suitable joke provider",
            "type": "task",
            "body": "Compare public providers and recommend one.",
            "acceptanceCriteria": ["The product owner can approve one provider"],
            "role": "business_analyst",
            "priority": "high",
            "rationale": "Delivery needs an approved provider.",
            "dependsOn": [],
            "environmentRelationship": "independent"
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
          "constraints": "Keep the preference on the device.",
          "environmentAssessment": {
            "readiness": "sufficient",
            "rationale": "The existing app environment covers this change.",
            "foundationTicketReference": null
          }
        },
        "suggestions": [
          {
            "reference": "S1",
            "title": "Choose a temperature unit",
            "type": "story",
            "body": "Add the unit preference and apply it throughout the forecast.",
            "acceptanceCriteria": [
              "A customer can switch between Celsius and Fahrenheit",
              "Every displayed temperature uses the chosen Celsius or Fahrenheit unit",
              "Automated checks cover conversion and saved preference behaviour"
            ],
            "role": "implementer",
            "priority": "normal",
            "rationale": "One cohesive change delivers and verifies the complete outcome.",
            "dependsOn": [],
            "environmentRelationship": "requires"
          }
        ]
      }
      """#

    let plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(response)

    #expect(plan.ticketSuggestions.count == 1)
    #expect(plan.ticketSuggestions[0].suggestedRole == .implementer)
  }

  @Test("Epic planning rejects vague decision placeholders without dependency provenance")
  func epicPlanningRequiresDecisionProvenance() throws {
    let response = #"""
      {
        "epic": {
          "title": "Forecast details",
          "goal": "Customers can understand a seven-day forecast.",
          "successCriteria": ["Every forecast day shows useful weather information."],
          "constraints": "",
          "environmentAssessment": {
            "readiness": "sufficient",
            "rationale": "The existing app environment covers this change.",
            "foundationTicketReference": null
          }
        },
        "suggestions": [
          {
            "reference": "DESIGN",
            "title": "Define forecast details",
            "type": "story",
            "body": "Define the visible weather details.",
            "acceptanceCriteria": ["The review artefact names each visible detail"],
            "role": "ux_designer",
            "priority": "normal",
            "rationale": "The visual contract is independently reviewable.",
            "dependsOn": [],
            "environmentRelationship": "independent"
          },
          {
            "reference": "BUILD",
            "title": "Build the forecast",
            "type": "story",
            "body": "Build the reviewed forecast.",
            "acceptanceCriteria": ["Each day shows the agreed core weather information"],
            "role": "implementer",
            "priority": "normal",
            "rationale": "This delivers the owner-facing outcome.",
            "dependsOn": ["DESIGN"],
            "environmentRelationship": "requires"
          }
        ]
      }
      """#
    #expect(throws: TicketSuggestionGenerationError.self) {
      try CodexTicketSuggestionGenerator.decodeEpicPlan(response)
    }

    let explicit = response.replacingOccurrences(
      of: "the agreed core weather information",
      with: "the details specified by DESIGN"
    )
    let plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(explicit)
    #expect(plan.ticketSuggestions[1].dependsOnReferences == ["S1"])
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
          "constraints": "Do not implement the integration yet.",
          "environmentAssessment": {
            "readiness": "not_required",
            "rationale": "This epic delivers a decision document rather than executable product work.",
            "foundationTicketReference": null
          }
        },
        "suggestions": [
          {
            "reference": "S1",
            "title": "Recommend a suitable joke provider",
            "type": "task",
            "body": "Compare public providers and recommend one.",
            "acceptanceCriteria": ["The product owner can approve one provider"],
            "role": "business_analyst",
            "priority": "high",
            "rationale": "The epic is explicitly a provider decision.",
            "dependsOn": [],
            "environmentRelationship": "independent"
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
      name: "Weather"
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
    #expect(prompt.contains("verified Environments knowledge"))
    #expect(prompt.contains("non-technical owner"))
    #expect(prompt.contains("complete answer; never offer a placeholder"))
    #expect(prompt.contains("choose Other and describe it"))
    #expect(prompt.contains("exactly one selection per question"))
    #expect(prompt.contains("Restate the full outcome in every option"))
    #expect(clarification.questions.count == 1)
    #expect(clarification.questions[0].options.count == 2)
    #expect(!clarification.readyToPlan)
    #expect(ready.questions.isEmpty)
    #expect(ready.readyToPlan)
  }

  @Test("Expired epic planning threads resume from the durable owner conversation")
  func epicPlanningRecoveryPrompt() {
    let product = Product(
      name: "Weather"
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
          body: "@UX designer Which existing pattern should we reuse?",
          kind: .chat,
          participantName: "UX designer"
        ),
        EpicPlanningConversationMessage(
          author: .agent,
          body: "Reuse the established compact result row.",
          kind: .chat,
          participantName: "UX designer"
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
    #expect(prompt.contains("authorisation for business analyst research"))
    #expect(prompt.contains("let the team choose"))
    #expect(prompt.contains("Other text field"))
    #expect(prompt.contains("never “I’ll provide”"))
    #expect(prompt.contains("complete resulting scope"))
    #expect(prompt.contains("must not compound"))
    #expect(!prompt.contains("Which existing pattern should we reuse?"))
    #expect(!prompt.contains("compact result row"))
  }

  @Test("Interrupted final epic planning reconstructs every durable owner answer")
  func finalEpicPlanRecoveryPrompt() {
    let product = Product(
      name: "Weather"
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
    #expect(prompt.contains("do not ask the product owner to repeat anything"))
  }

  @Test("Epic planning does not turn unresolved owner decisions into discovery tickets")
  func epicPlanningDecisionGuardrails() {
    let product = Product(
      name: "Weather"
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
      customInstructions: ""
    )

    #expect(prompt.contains("Do not invent product"))
    #expect(prompt.contains("decisions or disguise"))
    #expect(prompt.contains("explicitly requested research"))
    #expect(prompt.contains("Otherwise create tickets that deliver"))
    #expect(prompt.contains("Research is a prerequisite,"))
    #expect(prompt.contains("Every acceptance"))
    #expect(prompt.contains("cite that exact ticket reference"))
    #expect(prompt.contains("trace every epic success criterion"))
    #expect(prompt.contains("do not default to a fixed"))
    #expect(prompt.contains("Make verification explicit in"))
    #expect(prompt.contains("separate design or verification ticket only when"))
    #expect(
      !prompt.contains("include the downstream experience-design, implementation, and verification")
    )
    #expect(prompt.contains("separate business analyst ticket"))
    #expect(prompt.contains("do not bury source selection"))
    #expect(prompt.contains("implementation-time selection without a separate recommendation"))
    #expect(prompt.contains("epic.environmentAssessment"))
    #expect(prompt.contains("foundation_required"))
    #expect(prompt.contains("run-private temporary and cache locations"))
    #expect(initial.contains("business analyst research ticket"))
    #expect(initial.contains("Do not offer a vague option"))
    #expect(initial.contains("implementation-time selection"))
    #expect(initial.contains("verified Environments knowledge"))
    #expect(initial.contains("non-technical owner"))
    #expect(initial.contains("creates no research ticket"))
    #expect(initial.contains("choose Other and describe it"))
    #expect(initial.contains("already stated in the outcome is resolved"))
    #expect(initial.contains("ask nothing"))
    #expect(initial.contains("readyToPlan to true with an empty questions array"))
    #expect(followUp.contains("sources"))
    #expect(followUp.contains("Do not silently"))
    #expect(followUp.contains("Constraints for an unnamed external source"))
    #expect(followUp.contains("let the team choose"))
    #expect(followUp.contains("Every choice must be a complete answer"))
    #expect(followUp.contains("without a research ticket"))
    #expect(followUp.contains("select only one option"))
    #expect(followUp.contains("incremental labels"))
    #expect(followUp.contains("owner-observable"))
    #expect(followUp.contains("generic"))
    #expect(finalPlan.contains("is such authorisation"))
    #expect(finalPlan.contains("Give that work a separate business analyst ticket"))
    #expect(finalPlan.contains("inside design or implementation"))
    #expect(finalPlan.contains("Do not force that work into a standard sequence"))
    #expect(finalPlan.contains("using a separate ticket only when"))
    #expect(finalPlan.contains("environment-establishment task"))
    #expect(finalPlan.contains("every ticket that needs it depend on it"))
    #expect(developerInstructions.contains("constraints alone do not select"))
    #expect(developerInstructions.contains("authorised business analyst research"))
    #expect(developerInstructions.contains("foundation task"))
    #expect(developerInstructions.contains("verified Environments"))
    #expect(developerInstructions.contains(#"not "S1 - Choose a provider""#))
  }

  @Test("[D20] Research receives active scope and cannot duplicate covered work")
  func d20ResearchPromptIncludesActiveScopeAndExcludesHistory() {
    let product = Product(name: "Provider decision")
    let analyst = AgentProfile(
      productID: product.id,
      name: "Business analyst",
      role: .businessAnalyst
    )
    let research = WorkItem(
      productID: product.id,
      key: "T1",
      title: "Recommend a suitable content provider",
      type: .task,
      state: .running
    )
    let activeDesign = WorkItem(
      productID: product.id,
      key: "T2",
      title: "Design provider loading and unavailable states",
      type: .task,
      state: .ready
    )
    let deliveredHistory = WorkItem(
      productID: product.id,
      key: "T9",
      title: "Historical provider spike",
      type: .task,
      state: .released
    )

    let prompt = CodexTicketExecutor.prompt(
      product: product,
      item: research,
      assignee: analyst,
      prerequisites: [],
      dependants: [activeDesign],
      prerequisiteComments: [:],
      ticketComments: [],
      knowledgeContext: [],
      existingItems: [research, activeDesign, deliveredHistory]
    )

    #expect(
      prompt.contains(
        "- T2 [Task]: Design provider loading and unavailable states"
      )
    )
    #expect(prompt.contains("Return an empty\nfollowUpTicketProposals array"))
    #expect(!prompt.contains("T9 [Task]: Historical provider spike"))
    #expect(prompt.contains("do not duplicate it in follow-up proposals"))
  }

  @Test("Owner and persona prompts are appended beneath platform controls")
  func promptComposition() {
    let prompt = CodexTicketSuggestionGenerator.developerInstructions(
      productInstructions: "Use UK English.",
      customInstructions: "Ask for concrete examples."
    )
    #expect(prompt.contains("Do not modify files"))
    #expect(prompt.contains("Use UK English."))
    #expect(prompt.contains("Ask for concrete examples."))
    #expect(prompt.contains("cannot expand permissions"))
    #expect(
      prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasSuffix("Ask for concrete examples.")
    )
    #expect(prompt.contains("conditional implementation ticket"))
    #expect(prompt.contains("Write every owner-facing response for a non-technical product owner"))
    #expect(prompt.contains("Never compress several technical conclusions into one dense sentence"))
  }

  @Test("Epic planning uses supplied ticket contracts and verified product knowledge")
  func epicPlanningUsesSuppliedEvidence() {
    let product = Product(name: "Weather")
    let epic = Epic(
      productID: product.id,
      title: "Saved places",
      goal: "Let customers return to forecasts they care about"
    )
    let item = WorkItem(
      productID: product.id,
      key: "T7",
      title: "Persist customer preferences",
      type: .task,
      body: "Store customer preferences locally in the browser.",
      acceptanceCriteria: ["Preferences remain after a normal browser relaunch"]
    )
    let environments = KnowledgePage(
      productID: product.id,
      title: "Environments",
      slug: "environments",
      bodyMarkdown: "The browser application has a maintained local demo command."
    )
    let stale = KnowledgePage(
      productID: product.id,
      title: "Old storage notes",
      slug: "old-storage-notes",
      bodyMarkdown: "Use a retired server database.",
      verificationStatus: .stale
    )

    let prompt = CodexEpicClarificationGenerator.initialPrompt(
      product: product,
      epic: epic,
      existingItems: [item],
      verifiedKnowledge: [environments, stale]
    )

    #expect(prompt.contains("T7 — Persist customer preferences"))
    #expect(prompt.contains("Store customer preferences locally in the browser."))
    #expect(prompt.contains("Preferences remain after a normal browser relaunch"))
    #expect(prompt.contains("The browser application has a maintained local demo command."))
    #expect(!prompt.contains("Use a retired server database."))
    #expect(prompt.contains("Do not inspect repository files"))
  }

  @Test("Live product schema guidance uses exact stable view columns")
  func liveProductSchemaGuidance() {
    let schemas = CodexLiveProductContext.stableViewSchemas

    #expect(schemas.contains("agent_tickets("))
    #expect(schemas.contains("item_key"))
    #expect(schemas.contains("acceptance_criteria_json"))
    #expect(schemas.contains("agent_verified_knowledge("))
    #expect(schemas.contains("delivery_kind"))
    #expect(!schemas.contains("ticket_key"))
  }

  @Test("Repeated backlog analysis receives the previous rejected proposals")
  func rejectedSuggestionContext() {
    let product = Product(name: "Weather")
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
    #expect(prompt.contains("top-level environmentAssessment"))
    #expect(prompt.contains("foundationTicketReference"))
    #expect(prompt.contains("every requires ticket"))
  }

  @Test("Sprint planning conversation is single-recipient, read-only, and proposes versioned edits")
  func sprintPlanningConversation() throws {
    let product = Product(
      name: "Weather",
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
      name: "Tech lead",
      role: .lead,
      model: "gpt-5.6-sol",
      reasoningEffort: "high"
    )
    let instructions = CodexSprintPlanningConversation.developerInstructions(
      productInstructions: product.instructions,
      customInstructions: "Challenge unclear delivery assumptions.",
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
    #expect(instructions.contains("Tech lead — Tech lead"))
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
      customInstructions: "Keep the product owner in control."
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
          body: "@Business analyst Customers should confirm ambiguous locations."
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
          "role": "ux_designer",
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
    #expect(instructions.contains("version-checked refinement result"))
    #expect(instructions.contains("verified Environments knowledge"))
    #expect(instructions.contains("splitRecommendation"))
    #expect(instructions.contains("non-technical product owner"))
    #expect(instructions.contains("Every option must itself be a complete answer"))
    #expect(instructions.contains("choose Other and describe it"))
    #expect(instructions.contains("self-contained description of the complete"))
    #expect(instructions.contains("restate the full outcome"))
    #expect(instructions.contains("Use UK English."))
    #expect(prompt.contains("exact saved version 1"))
    #expect(prompt.contains("T-1"))
    #expect(!prompt.contains("Archived dark mode experiment"))
    #expect(prompt.contains("Customers should confirm ambiguous locations."))
    #expect(reply.proposal.baseVersion == 1)
    #expect(reply.proposal.suggestedRole == .uxDesigner)
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
          "body": "Requires product owner confirmation.",
          "acceptanceCriteria": ["A premature criterion"],
          "priority": "urgent",
          "role": "implementer",
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
          "role": "implementer",
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
          "role": "implementer",
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
    #expect(sparseProposal.message.contains("completed the ticket refinement"))
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
            "role": "implementer",
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

  @Test("Legacy paused work log questions retain interactive presentation")
  func legacyPausedWorkLogQuestionPresentation() throws {
    let body = """
      I found two viable providers and need the product owner to choose one.

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
        == "I found two viable providers and need the product owner to choose one."
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
      name: "Business analyst",
      role: .businessAnalyst,
      model: "gpt-5.6-terra",
      reasoningEffort: "medium"
    )
    let instructions = CodexTicketConversation.developerInstructions(
      productInstructions: product.instructions,
      customInstructions: analyst.customInstructionText,
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
    #expect(instructions.contains("automatic business analyst refinement"))
    #expect(instructions.contains("Business analyst — Business analyst"))
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

  @Test("Ordinary epic chat is read-only, single-recipient, and separate from refinement")
  func epicConversation() throws {
    let product = Product(
      name: "Weather",
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
      name: "UX designer",
      role: .uxDesigner,
      model: "gpt-5.6-sol",
      reasoningEffort: "medium"
    )
    let instructions = CodexEpicConversation.developerInstructions(
      productInstructions: product.instructions,
      customInstructions: designer.customInstructionText,
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
          body: "@UX designer Which existing pattern should we reuse?",
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
    #expect(instructions.contains("UX designer — UX designer"))
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

  @Test("Agent role defaults pin terra with evidence-gated efforts")
  func agentRoleDefaults() {
    let expected: [(AgentRole, String)] = [
      (.businessAnalyst, "medium"),
      (.uxDesigner, "medium"),
      (.lead, "medium"),
      (.implementer, "medium"),
      (.frontendEngineer, "medium"),
      (.backendEngineer, "high"),
      (.reviewer, "high"),
      (.qualityAssurance, "high"),
      (.knowledgeCurator, "medium"),
    ]

    for (role, effort) in expected {
      let configuration = AgentPersonaDefaults.configuration(for: role)
      #expect(configuration.model == "gpt-5.6-terra")
      #expect(configuration.effort == effort)
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
    let key = SpeditoFeatureFlags.requireKnowledgeApprovalEnvironmentKey
    #expect(
      !SpeditoFeatureFlags.requiresKnowledgeApproval(environment: [:])
    )
    #expect(
      SpeditoFeatureFlags.requiresKnowledgeApproval(environment: [key: "1"])
    )
    #expect(
      SpeditoFeatureFlags.requiresKnowledgeApproval(environment: [key: "true"])
    )
    #expect(
      !SpeditoFeatureFlags.requiresKnowledgeApproval(environment: [key: "false"])
    )
  }

  @Test("Ticket execution receives direct prerequisite handoffs and planned dependant contracts")
  func ticketExecutionDependencyHandoffs() {
    let product = Product(
      name: "Content search"
    )
    let analyst = AgentProfile(
      productID: product.id,
      name: "Business analyst",
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
      acceptanceCriteria: ["The product owner can approve one provider"]
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
      authorName: "Business analyst",
      body: "Completion handoff: Do not send customer search terms to the provider."
    )
    let expiredPermissionComment = TicketComment(
      workItemID: research.id,
      authorKind: .system,
      authorName: "Spedito",
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
      customInstructions: "",
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
    #expect(instructions.contains("DELIVERY MODE: RESEARCH AND DECISION SUPPORT"))
    #expect(instructions.contains("self-contained completion handoff"))
    #expect(instructions.contains("planned direct dependants"))
    #expect(instructions.contains("accepted ticket contract"))
    #expect(instructions.contains("genuinely new scope"))
    #expect(instructions.contains("Never copy"))
    #expect(instructions.contains("You may inspect Git"))
    #expect(instructions.contains("owns every Git mutation"))
    #expect(instructions.contains("noninteractive environment"))
    #expect(instructions.contains("command -v"))
    #expect(instructions.contains("request_permissions"))
    #expect(instructions.contains("smallest coherent"))
    #expect(instructions.contains("Batch all known paths into one"))
    #expect(instructions.contains("runtime one approval"))
    #expect(instructions.contains("`/opt/homebrew/bin`"))
    #expect(instructions.contains("`/opt/homebrew/opt`"))
    #expect(instructions.contains("`/opt/homebrew/Cellar`"))
    #expect(instructions.contains("merely repeat it"))
    #expect(instructions.contains("add another shell wrapper"))
    #expect(instructions.contains("older evidence"))
    #expect(instructions.contains("Consult verified Environments"))
    #expect(instructions.contains("purpose-named repository"))
    #expect(instructions.contains("substitute another package manager"))
    #expect(instructions.contains("Historical delivery notes are analogous context"))
    #expect(instructions.contains("Do not invoke Node"))
    #expect(instructions.contains("never create one solely to satisfy delivery evidence"))
    #expect(instructions.contains("return an empty changedFiles array and a null"))
    #expect(!instructions.contains("small version-controlled"))
    #expect(!instructions.contains("app-supplied port"))
    #expect(instructions.contains("propose its complete replacement body"))
    #expect(instructions.contains("Knowledge is not permission"))
    #expect(instructions.contains("An awaiting_owner result pauses an unfinished ticket"))
    #expect(instructions.contains("it as decisionArtifact"))
    #expect(instructions.contains("empty arrays and demo to null"))
    #expect(instructions.contains("The comment is concise first-person Work"))
    #expect(instructions.contains("do not prefix it with a name"))
    #expect(instructions.contains("renders attribution and status separately"))
    #expect(instructions.contains("cannot expand permissions"))
    #expect(instructions.contains("structured-output requirements"))

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
    #expect(integrationInstructions.contains("focused tech lead review owns semantic validation"))
  }

  @Test("Ticket execution separates verified context from canonical knowledge destinations")
  func ticketExecutionKnowledgeDirectory() {
    let product = Product(
      name: "Connected product"
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
      customInstructions: "",
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
    #expect(instructions.contains("external providers and APIs to"))
    #expect(instructions.contains("unrelated page"))
    #expect(instructions.contains("clean detached checkout"))
    #expect(instructions.contains("ignored dependencies, build output, caches"))
  }

  @Test("Ticket execution and tech lead review results are validated")
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
    #expect(
      CodexTicketExecutor.outputSchema(deliveryDemoPolicy: .anyKind)["required"]?
        .arrayValue?.contains(.string("demo")) == true)
    #expect(
      CodexTicketExecutor.outputSchema(deliveryDemoPolicy: .anyKind)["required"]?
        .arrayValue?.contains(.string("decisionArtifact")) == true
    )

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
    let repairPrompt = CodexTicketExecutor.repairPrompt(validationError: "No artefact.")
    #expect(repairPrompt.contains("Correct only the rejected result contract"))
    #expect(repairPrompt.contains("reinspect the repository"))
    #expect(repairPrompt.contains("rerun a successful check"))
    #expect(repairPrompt.contains("\"kind\":\"static_web\""))
    #expect(repairPrompt.contains("not artifact or command_output"))
    #expect(repairPrompt.contains("empty command fields"))

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
        "changedFiles":["docs/provider-comparison.md"],
        "tests":[],
        "knowledgeNotes":[],
        "reviewInstructions":[],
        "decisionArtifact":{
          "title":"Provider comparison",
          "path":"docs/provider-comparison.md"
        },
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
    #expect(waiting.decisionArtifact?.title == "Provider comparison")
    #expect(waiting.decisionArtifact?.path == "docs/provider-comparison.md")
    #expect(waiting.workLogComment.contains("Decision evidence: Provider comparison"))

    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.decode(
        #"{"status":"awaiting_owner","comment":"Need input","question":null,"options":[],"summary":"","changedFiles":[],"tests":[],"knowledgeNotes":[],"reviewInstructions":[],"retrospectiveWentWell":[],"retrospectiveCouldImprove":[],"retrospectiveActions":[],"knowledgePageProposals":[],"followUpTicketProposals":[]}"#
      )
    }

    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.decode(
        #"""
        {
          "status":"awaiting_owner",
          "comment":"I need the retention decision before publishing this recommendation.",
          "question":"May the provider retain request logs for 90 days?",
          "options":["Allow documented provider retention","Require zero external retention"],
          "summary":"",
          "changedFiles":["docs/provider-comparison.md"],
          "tests":["Checked the provider documentation"],
          "knowledgeNotes":[],
          "reviewInstructions":[],
          "decisionArtifact":{
            "title":"Provider comparison",
            "path":"docs/provider-comparison.md"
          },
          "demo":null,
          "retrospectiveWentWell":[],
          "retrospectiveCouldImprove":[],
          "retrospectiveActions":[],
          "knowledgePageProposals":[{
            "operation":"create",
            "targetPageID":null,
            "parentPageID":"12873963-2926-4196-9D71-BE98DE05721D",
            "title":"Provider recommendation",
            "proposedBodyMarkdown":"Open-Meteo is conditionally recommended.",
            "rationale":"Reuse the research."
          }],
          "followUpTicketProposals":[]
        }
        """#
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

    let product = Product(name: "Weather")
    let analyst = AgentProfile(
      productID: product.id,
      name: "Business analyst",
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
        "changedFiles":[],
        "tests":["Checked every comparison criterion — passed"],
        "knowledgeNotes":["The approved provider requires no API key."],
        "reviewInstructions":["Review the completion handoff and proposed Product knowledge."],
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
            "acceptanceCriteria":["The product owner can review every failure state"],
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
    #expect(researchCompleted.changedFiles.isEmpty)
    #expect(researchCompleted.demo == nil)
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
      name: "Tech lead",
      role: .lead
    )
    let reviewDeveloperInstructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      customInstructions: techLead.customInstructionText,
      reviewer: techLead
    )
    #expect(reviewDeveloperInstructions.contains("Cosmetic diff hygiene is not a blocker"))
    #expect(reviewDeveloperInstructions.contains("trailing"))
    #expect(reviewDeveloperInstructions.contains("single read-only inspection"))
    #expect(reviewDeveloperInstructions.contains("Do not build, test, lint"))
    #expect(reviewDeveloperInstructions.contains("Do not browse the web"))
    #expect(reviewDeveloperInstructions.contains("Do not request broader"))
    #expect(reviewDeveloperInstructions.contains("Treat reported checks as delivery evidence"))
    #expect(!CodexTechLeadReviewer.allowsApprovals)
    #expect(reviewDeveloperInstructions.contains("The comment is attributed work log prose"))
    #expect(reviewDeveloperInstructions.contains("do not prefix it"))
    #expect(reviewDeveloperInstructions.contains(#""Approved", or "Changes requested""#))
    #expect(
      reviewDeveloperInstructions.contains(
        "structured decision separately"
      )
    )
    #expect(reviewDeveloperInstructions.contains("cannot expand permissions"))
    #expect(reviewDeveloperInstructions.contains("structured-output requirements"))
    #expect(
      reviewDeveloperInstructions.contains(
        "independently justify another implementation, integration, and review cycle"
      )
    )
    let reReviewPrompt = CodexTechLeadReviewer.prompt(
      product: product,
      item: researchTicket,
      implementation: researchCompleted,
      knowledgePageProposals: [],
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
    #expect(reReviewPrompt.contains("Business analyst — Business analyst"))
    #expect(reReviewPrompt.contains("Assume a small non-commercial demo."))
    #expect(reReviewPrompt.contains("Do not restart a full review"))
    #expect(reReviewPrompt.contains("earlier classification is not binding"))
    #expect(reReviewPrompt.contains("If no material finding remains, approve"))
    #expect(reReviewPrompt.contains("Integrate the approved provider"))
    let integratedReviewPrompt = CodexTechLeadReviewer.prompt(
      product: product,
      item: researchTicket,
      implementation: researchCompleted,
      knowledgePageProposals: [],
      assignee: analyst,
      baseSHA: "candidate-base",
      candidateHeadSHA: "candidate-head",
      integratedSHA: "integrated-head"
    )
    #expect(integratedReviewPrompt.contains("Immutable integrated revision under review"))
    #expect(integratedReviewPrompt.contains("Integrated revision: integrated-head"))
    #expect(integratedReviewPrompt.contains("latest accepted local trunk"))
    #expect(integratedReviewPrompt.contains("verified GitHub default-branch head"))
    #expect(integratedReviewPrompt.contains("exact integrated result once"))
    #expect(integratedReviewPrompt.contains("Do not reproduce delivery"))
    #expect(integratedReviewPrompt.contains("Do not run checks, launch the product or demo"))

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
    #expect(recoveryPrompt.contains("Continue the existing tech lead review"))
    #expect(recoveryPrompt.contains("integrated-review-sha"))
    #expect(recoveryPrompt.contains("Do not restart a full"))
    #expect(recoveryPrompt.contains("earlier version of the review contract"))
    #expect(recoveryPrompt.contains("obsolete for"))
    #expect(recoveryPrompt.contains("Do not reissue it"))
    #expect(recoveryPrompt.contains("run or repeat checks"))
    #expect(recoveryPrompt.contains("request permissions"))
    #expect(!recoveryPrompt.contains("swift test --filter ResearchTests"))

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
    #expect(implementationRecoveryPrompt.contains("existing conversation and ticket workspace"))
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
    #expect(implementationRecoveryPrompt.contains("treat it as a failed check"))
    #expect(implementationRecoveryPrompt.contains("provide testing infrastructure"))
    #expect(implementationRecoveryPrompt.contains("reproduce the application lifecycle"))

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
    #expect(baselineRevisionPrompt.contains("missing evidence remains implementation work"))
    #expect(baselineRevisionPrompt.contains("treat it as a failed check"))
    #expect(baselineRevisionPrompt.contains("failed check as a product limitation"))

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
    #expect(leafRecoveryPrompt.contains("Do not continue"))
    #expect(leafRecoveryPrompt.contains("one at a time"))
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
    #expect(deniedRecoveryPrompt.contains("product owner denied"))
    #expect(deniedRecoveryPrompt.contains("Do not reissue the same request"))

    let replacementImplementationPrompt = CodexTicketExecutor.recoveryPrompt(
      item: researchTicket,
      interruptedPermission: nil,
      conversationIsAvailable: false
    )
    #expect(replacementImplementationPrompt.contains("previous conversation is unavailable"))
    #expect(replacementImplementationPrompt.contains("workspace and its changes"))

    let integration = try CodexConflictIntegrator.decode(
      #"{"status":"awaiting_owner","comment":"The two branches define incompatible defaults.","question":"Which behavior should remain the default?","options":["Use the accepted trunk behavior","Use the ticket behavior"],"summary":"","checks":[]}"#
    )
    #expect(integration.status == .awaitingOwner)
    #expect(integration.workLogComment.contains("Question for you"))
  }

  @Test("Tech lead review receives complete candidate-bound proposal contracts")
  func techLeadReviewCandidateContext() {
    let product = Product(name: "Weather")
    let item = WorkItem(
      productID: product.id,
      key: "T1",
      title: "Establish the delivery environment",
      body: "Create and document the reusable local environment.",
      acceptanceCriteria: ["Verified Environments product knowledge is updated."]
    )
    let implementer = AgentProfile(
      productID: product.id,
      name: "Implementer",
      role: .implementer
    )
    let candidateID = UUID()
    let environmentsPageID = UUID()
    let proposedBody = """
      ## Supported toolchain

      Run `swift test` from the repository root.
      """
    let proposalDraft = KnowledgePageProposalDraft(
      operation: .update,
      targetPageID: environmentsPageID,
      title: "Environments",
      proposedBodyMarkdown: proposedBody,
      rationale: "Records the verified delivery environment."
    )
    let implementation = TicketExecutionResult(
      status: .completed,
      comment: "I verified the environment and prepared its canonical guidance.",
      question: nil,
      options: [],
      summary: "The reusable build, test, and demo environment is ready.",
      changedFiles: ["Package.swift"],
      tests: ["swift test — passed"],
      knowledgeNotes: ["No production credentials are required."],
      reviewInstructions: ["Open the managed demo and confirm the starter appears."],
      retrospectiveWentWell: ["This retrospective detail must stay out of review context."],
      retrospectiveCouldImprove: [],
      retrospectiveActions: [],
      knowledgePageProposals: [proposalDraft],
      followUpTicketProposals: [
        FollowUpTicketProposalDraft(
          reference: "F1",
          title: "Verify the unavailable state",
          type: .task,
          body: "Exercise the product when forecast data cannot be retrieved.",
          acceptanceCriteria: ["The retry path is verified without losing the selected place."],
          suggestedRole: .qualityAssurance,
          priority: .high,
          rationale: "The provider can be temporarily unavailable.",
          dependsOnReferences: ["T3"]
        )
      ]
    )
    let proposal = KnowledgePageProposal(
      productID: product.id,
      sprintID: UUID(),
      workItemID: item.id,
      candidateRevisionID: candidateID,
      operation: .update,
      targetPageID: environmentsPageID,
      basePageTitle: "Environments",
      basePageBodyMarkdown: "Earlier verified environment guidance.",
      title: "Environments",
      proposedBodyMarkdown: proposedBody,
      rationale: "Records the verified delivery environment."
    )

    let prompt = CodexTechLeadReviewer.prompt(
      product: product,
      item: item,
      implementation: implementation,
      knowledgePageProposals: [proposal],
      assignee: implementer,
      baseSHA: "candidate-base",
      candidateHeadSHA: "candidate-head"
    )

    #expect(prompt.contains(implementation.comment))
    #expect(prompt.contains(proposal.id.uuidString))
    #expect(prompt.contains(candidateID.uuidString))
    #expect(prompt.contains(environmentsPageID.uuidString))
    #expect(prompt.contains("Earlier verified environment guidance."))
    #expect(prompt.contains(proposedBody))
    #expect(
      prompt.contains("`agent_verified_knowledge` contains accepted canonical knowledge only"))
    #expect(prompt.contains("Do not require a pending proposal to be"))
    #expect(prompt.contains("Exercise the product when forecast data cannot be retrieved."))
    #expect(prompt.contains("The retry path is verified without losing the selected place."))
    #expect(prompt.contains("Priority: High"))
    #expect(prompt.contains("Depends on proposed references: T3"))
    #expect(!prompt.contains("This retrospective detail must stay out of review context."))

    let localOutcome = TicketExecutionResult(
      status: .completed,
      comment: "I compared the supported providers.",
      question: nil,
      options: [],
      summary: "Open-Meteo is recommended with documented limitations.",
      changedFiles: [],
      tests: ["Checked every accepted comparison criterion — passed"],
      knowledgeNotes: ["No API key is required."],
      reviewInstructions: ["Review the recommendation and evidence in the Work log."],
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: []
    )
    let localPrompt = CodexTechLeadReviewer.prompt(
      product: product,
      item: item,
      implementation: localOutcome,
      knowledgePageProposals: [],
      assignee: AgentProfile(
        productID: product.id,
        name: "Business analyst",
        role: .businessAnalyst
      ),
      deliveryKind: .localOutcome
    )
    #expect(localPrompt.contains("Immutable local outcome under review"))
    #expect(localPrompt.contains("No repository files or Git revision are part of this delivery"))
    #expect(localPrompt.contains("Reported changed files:\nNo repository files changed."))
    #expect(!localPrompt.contains("Inspect the exact immutable workspace"))
  }

  @Test("Retrospective synthesis consolidates free-text evidence into at most five actions")
  func retrospectiveSynthesis() throws {
    let product = Product(
      name: "Delivery product"
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
    let ownerIdea = RetrospectiveNote(
      productID: product.id,
      sprintID: sprint.id,
      authorName: "Product owner",
      category: .suggestedAction,
      body: "Surface runtime readiness before delivery begins.",
      isActionCandidate: true,
      createdAt: Date(timeIntervalSince1970: 3)
    )

    let prompt = CodexRetrospectiveSynthesizer.prompt(
      product: product,
      sprint: sprint,
      sourceNotes: [first, second, ownerIdea],
      workItems: [item],
      existingActions: [],
      waysOfWorking: ""
    )
    #expect(prompt.contains("Return zero to five actions"))
    #expect(prompt.contains("E1 [Agent action candidate · T56 · Implementer]"))
    #expect(
      prompt.contains(
        "E3 [Product owner action candidate · Sprint · Product owner]"
      )
    )
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
      sourceNotes: [first, second, ownerIdea]
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
            "sourceReferences":["E4"]
          }]
        }
        """#,
        sourceNotes: [first, second, ownerIdea]
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
  private var respondFailure: Error?

  init() {
    let pair = AsyncStream<CodexInboundMessage>.makeStream()
    stream = pair.stream
    continuation = pair.continuation
  }

  func failNextRespond(with error: Error) { respondFailure = error }

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

  func respond(id: JSONValue, result: JSONValue) throws {
    if let respondFailure {
      self.respondFailure = nil
      throw respondFailure
    }
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
    finishTurn(threadID: threadID, turnID: turnID, text: text)
  }

  func completeMessageOnly(threadID: String, turnID: String, text: String) {
    sendAgentMessage(
      threadID: threadID,
      turnID: turnID,
      phase: "final_answer",
      text: text
    )
  }

  func finishTurn(threadID: String, turnID: String, text: String? = nil) {
    let items: [JSONValue] =
      text.map {
        [
          .object([
            "id": .string("message-\(turnID)"),
            "type": .string("agentMessage"),
            "phase": .string("final_answer"),
            "text": .string($0),
          ])
        ]
      } ?? []
    continuation.yield(
      .notification(
        CodexNotification(
          method: "turn/completed",
          params: .object([
            "threadId": .string(threadID),
            "turn": .object([
              "id": .string(turnID),
              "status": .string("completed"),
              "items": .array(items),
            ]),
          ])
        )
      )
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

private actor CompletionProbe {
  private(set) var isFinished = false

  func markFinished() {
    isFinished = true
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
      continuation.yield(
        .notification(
          CodexNotification(
            method: "turn/completed",
            params: .object([
              "threadId": .string("thread-1"),
              "turn": .object([
                "id": .string("turn-1"),
                "status": .string("completed"),
                "items": .array([
                  .object([
                    "id": .string("item-1"),
                    "type": .string("agentMessage"),
                    "phase": .string("final_answer"),
                    "text": .string(#"{"suggestions":[]}"#),
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
  private let rateLimitsResponse: JSONValue?
  private let stream: AsyncStream<CodexInboundMessage>
  private var calls: [Call] = []
  private var stopped = false

  init(initializeResponse: JSONValue, rateLimitsResponse: JSONValue? = nil) {
    self.initializeResponse = initializeResponse
    self.rateLimitsResponse = rateLimitsResponse
    stream = AsyncStream { continuation in
      continuation.finish()
    }
  }

  func start() {
    calls.append(Call(kind: .start, method: nil, params: nil))
  }

  func request(method: String, params: JSONValue) throws -> JSONValue {
    calls.append(Call(kind: .request, method: method, params: params))
    if method == "initialize" {
      return initializeResponse
    }
    if method == "account/rateLimits/read", let rateLimitsResponse {
      return rateLimitsResponse
    }
    throw CodexRPCError(code: -32_601, message: "Unexpected request")
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
