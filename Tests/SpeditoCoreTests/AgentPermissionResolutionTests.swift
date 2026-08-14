import Foundation
import Testing

@testable import SpeditoCore

@Suite("Agent permission resolution")
struct AgentPermissionResolutionTests {
  @Test("A persistence failure sends no permission response")
  func persistenceFailureFailsClosed() async {
    let request = permissionRequest()
    let persistence = PermissionPersistenceFake(
      requests: [request],
      failure: .prepare
    )
    let responder = PermissionResponderFake()
    let resolver = AgentPermissionResolver(
      persistence: persistence,
      responder: responder
    )

    await #expect(throws: AgentPermissionResolutionError.self) {
      _ = try await resolver.resolve(
        request: request,
        serverRequest: serverRequest(),
        intent: .allowOncePendingDelivery
      )
    }

    #expect(await responder.responses().isEmpty)
    #expect(await persistence.request(id: request.id)?.status == .pending)
  }

  @Test("A transport failure preserves intent and rolls back new product access")
  func transportFailureIsRecoverable() async {
    let request = permissionRequest(productGrantSignature: "product-grant")
    let persistence = PermissionPersistenceFake(requests: [request])
    let responder = PermissionResponderFake(fails: true)
    let resolver = AgentPermissionResolver(
      persistence: persistence,
      responder: responder
    )
    let grant = AgentPermissionGrant(
      productID: request.productID,
      sourceRequestID: request.id,
      method: request.method,
      kind: request.kind,
      title: request.title,
      detail: request.detail,
      signature: "product-grant"
    )

    await #expect(throws: AgentPermissionResolutionError.self) {
      _ = try await resolver.resolve(
        request: request,
        serverRequest: serverRequest(),
        intent: .allowProductPendingDelivery,
        productGrant: grant
      )
    }

    #expect(await responder.responses() == [true])
    #expect(
      await persistence.request(id: request.id)?.status
        == .allowProductPendingDelivery
    )
    #expect(await persistence.activeGrants().isEmpty)
  }

  @Test("An acknowledgement write failure retains the delivered decision intent")
  func acknowledgementFailureRetainsIntent() async {
    let request = permissionRequest()
    let persistence = PermissionPersistenceFake(
      requests: [request],
      failure: .acknowledge
    )
    let responder = PermissionResponderFake()
    let resolver = AgentPermissionResolver(
      persistence: persistence,
      responder: responder
    )

    await #expect(throws: AgentPermissionResolutionError.self) {
      _ = try await resolver.resolve(
        request: request,
        serverRequest: serverRequest(),
        intent: .denyPendingDelivery
      )
    }

    #expect(await responder.responses() == [false])
    #expect(
      await persistence.request(id: request.id)?.status
        == .denyPendingDelivery
    )
  }

  @Test("A recovered decision remains non-actionable until redelivery")
  func recoveredDecisionDoesNotAskAgain() async throws {
    let request = permissionRequest(status: .interrupted)
    let persistence = PermissionPersistenceFake(requests: [request])
    let responder = PermissionResponderFake()
    let resolver = AgentPermissionResolver(
      persistence: persistence,
      responder: responder
    )

    let result = try await resolver.resolve(
      request: request,
      serverRequest: nil,
      intent: .allowOncePendingDelivery
    )

    #expect(result.request.status == .allowOncePendingDelivery)
    #expect(!result.request.status.needsOwnerDecision)
    #expect(!result.responseDelivered)
    #expect(await responder.responses().isEmpty)
  }

  @Test("Repeated delivery reuses one durable request identity")
  func repeatedDeliveryIsIdempotent() async throws {
    let request = permissionRequest()
    let persistence = PermissionPersistenceFake(requests: [request])
    let responder = PermissionResponderFake()
    let resolver = AgentPermissionResolver(
      persistence: persistence,
      responder: responder
    )

    _ = try await resolver.resolve(
      request: request,
      serverRequest: serverRequest(),
      intent: .allowOncePendingDelivery
    )
    _ = try await resolver.resolve(
      request: request,
      serverRequest: serverRequest(),
      intent: .allowOncePendingDelivery
    )

    #expect(await responder.responses() == [true, true])
    #expect(await persistence.requestCount() == 1)
    #expect(await persistence.request(id: request.id)?.status == .allowed)
  }

  @Test("Every grant-covered server request retains its own audit record")
  func rememberedGrantUseIsAuditablePerRequest() async throws {
    let first = permissionRequest(serverRequestID: "request-1")
    let second = permissionRequest(serverRequestID: "request-2")
    let persistence = PermissionPersistenceFake(requests: [first, second])
    let responder = PermissionResponderFake()
    let resolver = AgentPermissionResolver(
      persistence: persistence,
      responder: responder
    )

    for request in [first, second] {
      _ = try await resolver.resolve(
        request: request,
        serverRequest: serverRequest(id: request.serverRequestID),
        intent: .grantAccessPendingDelivery
      )
    }

    #expect(await persistence.requestCount() == 2)
    #expect(await persistence.request(id: first.id)?.status == .allowed)
    #expect(await persistence.request(id: second.id)?.status == .allowed)
    #expect(await responder.responses() == [true, true])
  }

  private func permissionRequest(
    serverRequestID: String = "request-1",
    productGrantSignature: String? = nil,
    status: AgentPermissionRequestStatus = .pending
  ) -> AgentPermissionRequest {
    AgentPermissionRequest(
      productID: UUID(),
      workItemID: UUID(),
      agentRunID: UUID(),
      threadID: "thread",
      turnID: "turn",
      serverRequestID: serverRequestID,
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow access?",
      detail: "Read the selected runtime directory",
      signature: "permission-signature",
      productGrantSignature: productGrantSignature,
      status: status
    )
  }

  private func serverRequest(id: String = "request-1") -> CodexServerRequest {
    CodexServerRequest(
      id: .string(id),
      method: "item/permissions/requestApproval",
      params: .object([:])
    )
  }
}

private actor PermissionPersistenceFake: AgentPermissionResolutionPersisting {
  enum FailurePoint {
    case prepare
    case acknowledge
  }

  private var requestsByID: [UUID: AgentPermissionRequest]
  private var grantsByID: [UUID: AgentPermissionGrant] = [:]
  private let failure: FailurePoint?

  init(
    requests: [AgentPermissionRequest],
    failure: FailurePoint? = nil
  ) {
    requestsByID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
    self.failure = failure
  }

  func prepareAgentPermissionResolution(
    requestID: UUID,
    intent: AgentPermissionRequestStatus,
    productGrant: AgentPermissionGrant?
  ) throws -> AgentPermissionResolutionPreparation {
    if failure == .prepare { throw PermissionResolutionTestError.injected }
    guard var request = requestsByID[requestID] else {
      throw PermissionResolutionTestError.missingRequest
    }
    if request.status != intent.acknowledgedStatus {
      request.status = intent
      request.updatedAt = Date()
      requestsByID[requestID] = request
    }
    if let productGrant {
      grantsByID[productGrant.id] = productGrant
    }
    return AgentPermissionResolutionPreparation(
      request: request,
      grant: productGrant,
      createdGrantID: productGrant?.id
    )
  }

  func acknowledgeAgentPermissionResolution(
    requestID: UUID,
    intent: AgentPermissionRequestStatus
  ) throws -> AgentPermissionRequest {
    if failure == .acknowledge { throw PermissionResolutionTestError.injected }
    guard var request = requestsByID[requestID],
      let acknowledgedStatus = intent.acknowledgedStatus
    else {
      throw PermissionResolutionTestError.missingRequest
    }
    request.status = acknowledgedStatus
    request.updatedAt = Date()
    requestsByID[requestID] = request
    return request
  }

  func revokeAgentPermissionGrant(id: UUID) throws -> AgentPermissionGrant {
    guard var grant = grantsByID[id] else {
      throw PermissionResolutionTestError.missingGrant
    }
    grant.revokedAt = Date()
    grantsByID[id] = grant
    return grant
  }

  func request(id: UUID) -> AgentPermissionRequest? {
    requestsByID[id]
  }

  func requestCount() -> Int {
    requestsByID.count
  }

  func activeGrants() -> [AgentPermissionGrant] {
    grantsByID.values.filter(\.isActive)
  }
}

private actor PermissionResponderFake: CodexApprovalResponding {
  private var deliveredResponses: [Bool] = []
  private let fails: Bool

  init(fails: Bool = false) {
    self.fails = fails
  }

  func resolveApprovalRequest(
    _ request: CodexServerRequest,
    allow: Bool
  ) throws {
    deliveredResponses.append(allow)
    if fails { throw PermissionResolutionTestError.injected }
  }

  func responses() -> [Bool] {
    deliveredResponses
  }
}

private enum PermissionResolutionTestError: Error {
  case injected
  case missingRequest
  case missingGrant
}
