import Foundation
import Testing

@testable import SpeditoCore

@Suite("Saved agent access policy")
struct AgentPermissionGrantPolicyTests {
  @Test("Structured product grants are canonical across path ordering and duplicate fields")
  func canonicalStructuredGrant() throws {
    let forward = permissionValue(
      paths: ["/opt/homebrew/bin", "/opt/homebrew/opt"],
      includesNetwork: true
    )
    let reversed = permissionValue(
      paths: ["/opt/homebrew/opt", "/opt/homebrew/bin"],
      includesNetwork: true
    )

    let forwardPresentation = try permissionPresentation(for: forward)
    let reversedPresentation = try permissionPresentation(for: reversed)
    #expect(forwardPresentation.signature != reversedPresentation.signature)
    #expect(
      forwardPresentation.productGrantSignature
        == reversedPresentation.productGrantSignature
    )
  }

  @Test("Restricted network consent fails closed while unrestricted consent covers it")
  func restrictedNetworkCoverage() throws {
    let productID = UUID()
    let restrictedPermissions = JSONValue.object([
      "fileSystem": .null,
      "network": .object([
        "enabled": .bool(true),
        "domains": .object(["example.com": .string("allow")]),
      ]),
    ])
    let unrestrictedGrant = legacyPermissionGrant(
      productID: productID,
      permissions: permissionValue(paths: [], includesNetwork: true)
    )
    let restrictedGrant = legacyPermissionGrant(
      productID: productID,
      permissions: restrictedPermissions
    )
    let unrestrictedRequest = try #require(
      try productSignature(for: permissionValue(paths: [], includesNetwork: true))
    )
    let restrictedRequest = try #require(try productSignature(for: restrictedPermissions))

    #expect(
      !AgentPermissionGrantPolicy.covers(
        productGrantSignature: unrestrictedRequest,
        kind: .permissions,
        grants: [restrictedGrant]
      )
    )
    #expect(
      AgentPermissionGrantPolicy.covers(
        productGrantSignature: restrictedRequest,
        kind: .permissions,
        grants: [unrestrictedGrant]
      )
    )
  }

  @Test("Saved structured grants jointly cover equivalent and narrower requests")
  func structuredCoverage() throws {
    let productID = UUID()
    let runtime = legacyPermissionGrant(
      productID: productID,
      permissions: permissionValue(
        paths: ["/opt/homebrew/bin", "/opt/homebrew/opt", "/opt/homebrew/Cellar"]
      )
    )
    let openssl = legacyPermissionGrant(
      productID: productID,
      permissions: permissionValue(paths: ["/opt/homebrew/etc/openssl@3"])
    )
    let network = legacyPermissionGrant(
      productID: productID,
      permissions: permissionValue(paths: [], includesNetwork: true)
    )
    let requested = permissionValue(
      paths: [
        "/opt/homebrew/etc/openssl@3",
        "/opt/homebrew/Cellar",
        "/opt/homebrew/bin",
        "/opt/homebrew/opt",
      ],
      includesNetwork: true
    )
    let signature = try #require(try productSignature(for: requested))

    #expect(
      AgentPermissionGrantPolicy.covers(
        productGrantSignature: signature,
        kind: .permissions,
        grants: [runtime, openssl, network]
      )
    )

    let narrower = try #require(
      try productSignature(for: permissionValue(paths: ["/opt/homebrew/bin"]))
    )
    #expect(
      AgentPermissionGrantPolicy.covers(
        productGrantSignature: narrower,
        kind: .permissions,
        grants: [runtime]
      )
    )

    let missing = try #require(
      try productSignature(for: permissionValue(paths: ["/usr/local/bin"]))
    )
    #expect(
      !AgentPermissionGrantPolicy.covers(
        productGrantSignature: missing,
        kind: .permissions,
        grants: [runtime, openssl, network]
      )
    )
  }

  @Test("Saved commands retain exact matching semantics")
  func commandCoverageIsExact() {
    let grant = AgentPermissionGrant(
      productID: UUID(),
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "python3 -m http.server 8765",
      signature: "item/commandExecution/requestApproval|exact-command"
    )

    #expect(
      AgentPermissionGrantPolicy.covers(
        productGrantSignature: grant.signature,
        kind: .command,
        grants: [grant]
      )
    )
    #expect(
      !AgentPermissionGrantPolicy.covers(
        productGrantSignature: "item/commandExecution/requestApproval|similar-command",
        kind: .command,
        grants: [grant]
      )
    )
  }

  @Test("The writable ticket workspace and current-turn access jointly cover a request")
  func activeRunCoverage() throws {
    let productID = UUID()
    let workItemID = UUID()
    let runID = UUID()
    let turnID = "turn-current"
    let workspace = URL(fileURLWithPath: "/private/tmp/spedito/ticket")
    let hostTemporaryDirectory = "/private/var/folders/example/T"
    let previouslyAllowed = permissionValue(
      readPaths: ["/Applications/Xcode.app", hostTemporaryDirectory],
      writePaths: [hostTemporaryDirectory]
    )
    let previousSignature = try #require(
      try productSignature(for: previouslyAllowed)
    )
    let previousRequest = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: turnID,
      serverRequestID: "request-1",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Read Xcode and use its temporary cache",
      signature: "request-1-signature",
      productGrantSignature: previousSignature,
      status: .allowed
    )
    let repeated = permissionValue(
      readPaths: [
        "/Applications/Xcode.app",
        hostTemporaryDirectory,
        workspace.appendingPathComponent(".run-private").path,
      ],
      writePaths: [hostTemporaryDirectory]
    )
    let repeatedSignature = try #require(try productSignature(for: repeated))

    #expect(
      AgentPermissionGrantPolicy.coversActiveRunRequest(
        productGrantSignature: repeatedSignature,
        kind: .permissions,
        turnID: turnID,
        ticketWorkspaceRoot: workspace,
        requests: [previousRequest]
      )
    )
    #expect(
      !AgentPermissionGrantPolicy.coversActiveRunRequest(
        productGrantSignature: repeatedSignature,
        kind: .permissions,
        turnID: "turn-later",
        ticketWorkspaceRoot: workspace,
        requests: [previousRequest]
      )
    )
  }

  @Test("Workspace coverage excludes siblings and standardized escape paths")
  func ticketWorkspaceCoverageIsBounded() throws {
    let workspace = URL(fileURLWithPath: "/private/tmp/spedito/ticket")
    let inside = try #require(
      try productSignature(
        for: permissionValue(
          paths: [workspace.appendingPathComponent(".run-private/cache").path]
        )
      )
    )
    let sibling = try #require(
      try productSignature(
        for: permissionValue(paths: ["/private/tmp/spedito/ticket-other/cache"])
      )
    )
    let escaped = try #require(
      try productSignature(
        for: permissionValue(paths: ["/private/tmp/spedito/ticket/../other/cache"])
      )
    )
    let transient = try #require(
      try productSignature(
        for: permissionValue(paths: ["/private/var/folders/example/T/tool/cache"])
      )
    )
    let transientParent = try #require(
      try productSignature(
        for: permissionValue(paths: ["/private/var/folders/example"])
      )
    )

    #expect(
      AgentPermissionGrantPolicy.coversActiveRunRequest(
        productGrantSignature: inside,
        kind: .permissions,
        turnID: "turn",
        ticketWorkspaceRoot: workspace,
        requests: []
      )
    )
    #expect(
      AgentPermissionGrantPolicy.coversActiveRunRequest(
        productGrantSignature: transient,
        kind: .permissions,
        turnID: "turn",
        ticketWorkspaceRoot: workspace,
        writableTransientStorageRoots: [
          URL(fileURLWithPath: "/private/var/folders/example/T")
        ],
        requests: []
      )
    )
    #expect(
      !AgentPermissionGrantPolicy.coversActiveRunRequest(
        productGrantSignature: transientParent,
        kind: .permissions,
        turnID: "turn",
        ticketWorkspaceRoot: workspace,
        writableTransientStorageRoots: [
          URL(fileURLWithPath: "/private/var/folders/example/T")
        ],
        requests: []
      )
    )
    for signature in [sibling, escaped] {
      #expect(
        !AgentPermissionGrantPolicy.coversActiveRunRequest(
          productGrantSignature: signature,
          kind: .permissions,
          turnID: "turn",
          ticketWorkspaceRoot: workspace,
          requests: []
        )
      )
    }
  }

  @Test("Delivery requests cannot cross into Spedito-owned execution storage")
  func protectedSpeditoStorageIsRejected() throws {
    let workspace = URL(
      fileURLWithPath: "/Users/example/Library/Application Support/Spedito/Run Worktrees/product/t2"
    )
    let runWorktrees = URL(
      fileURLWithPath: "/Users/example/Library/Application Support/Spedito/Run Worktrees"
    )
    let previews = URL(
      fileURLWithPath: "/Users/example/Library/Caches/Spedito/PreviewWorktrees"
    )
    let ownStorage = try #require(
      try productSignature(
        for: permissionValue(paths: [workspace.appendingPathComponent(".run-private").path])
      )
    )
    let siblingStorage = try #require(
      try productSignature(
        for: permissionValue(paths: [runWorktrees.appendingPathComponent("product/t3").path])
      )
    )
    let previewStorage = try #require(
      try productSignature(
        for: permissionValue(paths: [previews.appendingPathComponent("candidate").path])
      )
    )
    let broadCacheStorage = try #require(
      try productSignature(
        for: permissionValue(paths: ["/Users/example/Library/Caches"])
      )
    )

    #expect(
      !AgentPermissionGrantPolicy.requestsProtectedSpeditoStorage(
        productGrantSignature: ownStorage,
        kind: .permissions,
        ticketWorkspaceRoot: workspace,
        protectedStorageRoots: [runWorktrees, previews]
      )
    )
    for signature in [siblingStorage, previewStorage, broadCacheStorage] {
      #expect(
        AgentPermissionGrantPolicy.requestsProtectedSpeditoStorage(
          productGrantSignature: signature,
          kind: .permissions,
          ticketWorkspaceRoot: workspace,
          protectedStorageRoots: [runWorktrees, previews]
        )
      )
    }
  }

  @Test("Settings group effective capabilities while preserving exact commands")
  func effectiveAccessGroups() {
    let productID = UUID()
    let runtime = legacyPermissionGrant(
      productID: productID,
      permissions: permissionValue(paths: ["/opt/homebrew/bin", "/opt/homebrew/opt"])
    )
    let overlapping = legacyPermissionGrant(
      productID: productID,
      permissions: permissionValue(
        paths: ["/opt/homebrew/opt", "/opt/homebrew/etc/openssl@3"],
        includesNetwork: true
      )
    )
    let command = AgentPermissionGrant(
      productID: productID,
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "python3 -m http.server 8765",
      signature: "item/commandExecution/requestApproval|exact-command"
    )

    let groups = AgentPermissionGrantPolicy.savedAccessGroups(
      for: [runtime, overlapping, command]
    )
    #expect(groups.count == 2)
    #expect(groups[0].kind == .capabilities)
    #expect(Set(groups[0].grantIDs) == [runtime.id, overlapping.id])
    #expect(groups[0].detail.contains("Network access"))
    #expect(groups[0].detail.components(separatedBy: "/opt/homebrew/opt").count == 2)
    #expect(groups[1].kind == .command)
    #expect(groups[1].detail == command.detail)
  }

  @Test("Delivery guidance explains saved consent without claiming it is active")
  func savedAccessAgentContext() {
    let productID = UUID()
    let grant = legacyPermissionGrant(
      productID: productID,
      permissions: permissionValue(
        paths: ["/opt/homebrew/bin"],
        includesNetwork: true
      )
    )
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: productID,
        name: "Implementer",
        role: .implementer
      ),
      savedPermissionGrants: [grant]
    )

    #expect(instructions.contains("SAVED PRODUCT ACCESS"))
    #expect(instructions.contains("Network access"))
    #expect(instructions.contains("Read /opt/homebrew/bin"))
    #expect(instructions.contains("Saved consent is not active sandbox access"))
    #expect(instructions.contains("request the smallest coherent matching"))
  }

  private func permissionValue(
    paths: [String],
    includesNetwork: Bool = false
  ) -> JSONValue {
    permissionValue(
      readPaths: paths,
      writePaths: [],
      includesNetwork: includesNetwork
    )
  }

  private func permissionValue(
    readPaths: [String],
    writePaths: [String],
    includesNetwork: Bool = false
  ) -> JSONValue {
    let entries =
      readPaths.map { path in
        JSONValue.object([
          "access": .string("read"),
          "path": .object([
            "path": .string(path),
            "type": .string("path"),
          ]),
        ])
      }
      + writePaths.map { path in
        JSONValue.object([
          "access": .string("write"),
          "path": .object([
            "path": .string(path),
            "type": .string("path"),
          ]),
        ])
      }
    return .object([
      "fileSystem": entries.isEmpty
        ? .null
        : .object([
          "entries": .array(entries),
          "read": .array(readPaths.map(JSONValue.string)),
          "write": .array(writePaths.map(JSONValue.string)),
        ]),
      "network": includesNetwork
        ? .object(["enabled": .bool(true)])
        : .null,
    ])
  }

  private func productSignature(for permissions: JSONValue) throws -> String? {
    try permissionPresentation(for: permissions).productGrantSignature
  }

  private func permissionPresentation(
    for permissions: JSONValue
  ) throws -> CodexApprovalPresentation {
    try CodexAppServerClient.approvalPresentation(
      for: CodexServerRequest(
        id: .integer(1),
        method: "item/permissions/requestApproval",
        params: .object([
          "threadId": .string("thread"),
          "turnId": .string("turn"),
          "permissions": permissions,
        ])
      )
    )
  }

  private func legacyPermissionGrant(
    productID: UUID,
    permissions: JSONValue
  ) -> AgentPermissionGrant {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(permissions)) ?? Data()
    return AgentPermissionGrant(
      productID: productID,
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Legacy structured access",
      signature:
        "item/permissions/requestApproval|\(String(decoding: data, as: UTF8.self))"
    )
  }
}
