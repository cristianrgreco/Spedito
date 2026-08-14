import Foundation

public struct AgentPermissionResolutionPreparation: Sendable {
  public let request: AgentPermissionRequest
  public let grant: AgentPermissionGrant?
  public let createdGrantID: UUID?

  public init(
    request: AgentPermissionRequest,
    grant: AgentPermissionGrant?,
    createdGrantID: UUID?
  ) {
    self.request = request
    self.grant = grant
    self.createdGrantID = createdGrantID
  }
}

public protocol AgentPermissionResolutionPersisting: Sendable {
  func prepareAgentPermissionResolution(
    requestID: UUID,
    intent: AgentPermissionRequestStatus,
    productGrant: AgentPermissionGrant?
  ) async throws -> AgentPermissionResolutionPreparation

  func acknowledgeAgentPermissionResolution(
    requestID: UUID,
    intent: AgentPermissionRequestStatus
  ) async throws -> AgentPermissionRequest

  func revokeAgentPermissionGrant(id: UUID) async throws -> AgentPermissionGrant
}

public protocol CodexApprovalResponding: Sendable {
  func resolveApprovalRequest(
    _ request: CodexServerRequest,
    allow: Bool
  ) async throws
}

extension CodexAppServerClient: CodexApprovalResponding {}

public enum AgentPermissionResolutionError: Error, Equatable, LocalizedError, Sendable {
  case persistencePreparationFailed(String)
  case responseDeliveryFailed(String)
  case grantRollbackFailed(response: String, rollback: String)
  case acknowledgementPersistenceFailed(String)

  public var errorDescription: String? {
    switch self {
    case .persistencePreparationFailed(let detail):
      "The permission decision could not be saved, so no response was sent. \(detail)"
    case .responseDeliveryFailed(let detail):
      "The permission decision was saved but could not be delivered. It will be recovered without asking again. \(detail)"
    case .grantRollbackFailed(let response, let rollback):
      "The permission decision could not be delivered, and its saved product access could not be rolled back. Delivery: \(response) Rollback: \(rollback)"
    case .acknowledgementPersistenceFailed(let detail):
      "The permission response was delivered, but its acknowledgement could not be saved. The saved decision remains recoverable. \(detail)"
    }
  }
}

public struct AgentPermissionResolutionResult: Sendable {
  public let request: AgentPermissionRequest
  public let grant: AgentPermissionGrant?
  public let responseDelivered: Bool

  public init(
    request: AgentPermissionRequest,
    grant: AgentPermissionGrant?,
    responseDelivered: Bool
  ) {
    self.request = request
    self.grant = grant
    self.responseDelivered = responseDelivered
  }
}

public struct AgentPermissionResolver: Sendable {
  private let persistence: any AgentPermissionResolutionPersisting
  private let responder: any CodexApprovalResponding

  public init(
    persistence: any AgentPermissionResolutionPersisting,
    responder: any CodexApprovalResponding
  ) {
    self.persistence = persistence
    self.responder = responder
  }

  public func resolve(
    request: AgentPermissionRequest,
    serverRequest: CodexServerRequest?,
    intent: AgentPermissionRequestStatus,
    productGrant: AgentPermissionGrant? = nil
  ) async throws -> AgentPermissionResolutionResult {
    let preparation: AgentPermissionResolutionPreparation
    do {
      preparation = try await persistence.prepareAgentPermissionResolution(
        requestID: request.id,
        intent: intent,
        productGrant: productGrant
      )
    } catch {
      throw AgentPermissionResolutionError.persistencePreparationFailed(
        error.localizedDescription
      )
    }

    guard let serverRequest else {
      return AgentPermissionResolutionResult(
        request: preparation.request,
        grant: preparation.grant,
        responseDelivered: false
      )
    }
    guard let allow = intent.allowsRequest else {
      throw AgentPermissionResolutionError.persistencePreparationFailed(
        "The saved permission decision has no delivery action."
      )
    }

    do {
      try await responder.resolveApprovalRequest(serverRequest, allow: allow)
    } catch {
      let responseError = error.localizedDescription
      if let createdGrantID = preparation.createdGrantID {
        do {
          _ = try await persistence.revokeAgentPermissionGrant(id: createdGrantID)
        } catch {
          throw AgentPermissionResolutionError.grantRollbackFailed(
            response: responseError,
            rollback: error.localizedDescription
          )
        }
      }
      throw AgentPermissionResolutionError.responseDeliveryFailed(responseError)
    }

    do {
      let acknowledged = try await persistence.acknowledgeAgentPermissionResolution(
        requestID: request.id,
        intent: intent
      )
      return AgentPermissionResolutionResult(
        request: acknowledged,
        grant: preparation.grant,
        responseDelivered: true
      )
    } catch {
      throw AgentPermissionResolutionError.acknowledgementPersistenceFailed(
        error.localizedDescription
      )
    }
  }
}

extension SQLiteStore: AgentPermissionResolutionPersisting {}
