import Foundation

@MainActor
public final class TicketDeliveryPermissionWorkflowCoordinator {
  private weak var delegate: (any TicketDeliveryWorkflowDelegate)?
  private let runtimeCoordinator: TicketDeliveryRuntimeCoordinator

  public init(
    delegate: any TicketDeliveryWorkflowDelegate,
    runtimeCoordinator: TicketDeliveryRuntimeCoordinator
  ) {
    self.delegate = delegate
    self.runtimeCoordinator = runtimeCoordinator
  }

  public func decidePermissionRequest(
    _ request: AgentPermissionRequest,
    allow: Bool,
    rememberForProduct: Bool = false
  ) async {
    guard
      request.status.needsOwnerDecision,
      let store = delegate?.deliveryStore(for: request.productID),
      let client = delegate?.deliveryCodexClient
    else {
      delegate?.deliveryErrorMessage =
        "This permission request is no longer waiting for a decision."
      return
    }
    let serverRequest = runtimeCoordinator.liveApprovalRequest(id: request.id)
    guard request.status != .pending || serverRequest != nil else {
      delegate?.deliveryErrorMessage =
        "This permission request is no longer attached to a live agent turn. Relaunch Spedito to recover it before deciding."
      return
    }
    let resumesAfterDecision = request.status == .interrupted
    let intent: AgentPermissionRequestStatus
    if allow && rememberForProduct {
      intent = .allowProductPendingDelivery
    } else if allow {
      intent = .allowOncePendingDelivery
    } else {
      intent = .denyPendingDelivery
    }

    let proposedGrant: AgentPermissionGrant?
    if intent == .allowProductPendingDelivery {
      guard
        let signature = request.productGrantSignature,
        AgentPermissionGrantPolicy.isReusableProductGrant(
          signature: signature,
          kind: request.kind
        )
      else {
        delegate?.deliveryErrorMessage =
          "This access is too broad to save for future agent runs. Allow it once or ask the agent to request a narrower scope."
        return
      }
      proposedGrant = AgentPermissionGrant(
        productID: request.productID,
        sourceRequestID: request.id,
        method: request.method,
        kind: request.kind,
        title: request.title,
        detail: request.detail,
        signature: signature
      )
    } else {
      proposedGrant = nil
    }

    do {
      let result = try await AgentPermissionResolver(
        persistence: store,
        responder: client
      ).resolve(
        request: request,
        serverRequest: serverRequest,
        intent: intent,
        productGrant: proposedGrant
      )
      if result.responseDelivered {
        runtimeCoordinator.removeLiveApprovalRequest(id: request.id)
      }
      delegate?.deliveryReplacePermissionRequest(result.request)
      if let savedGrant = result.grant {
        delegate?.deliveryReplacePermissionGrant(savedGrant)
      }
      if let run = try? await store.fetchAgentRun(id: request.agentRunID),
        run.status == .awaitingOwner
      {
        let eventDetail =
          if resumesAfterDecision && allow && rememberForProduct {
            "Saved the recovered capability for this product; queued the conversation to resume"
          } else if resumesAfterDecision && allow {
            "Saved the recovered one-time permission; queued the conversation to resume"
          } else if resumesAfterDecision {
            "Saved the recovered denial; queued the conversation so the agent can adapt"
          } else if allow && rememberForProduct {
            "Saved and allowed the requested capability for this product"
          } else if allow {
            "Allowed the requested capability once"
          } else {
            "Denied the requested capability; the agent will adapt"
          }
        _ = try await updateAgentRun(
          id: request.agentRunID,
          status: resumesAfterDecision ? .queued : .running,
          eventActor: "Product owner",
          eventDetail: eventDetail
        )
      }
      await delegate?.deliveryReloadSelectedProductIfCurrent(productID: request.productID)
      if resumesAfterDecision {
        delegate?.deliveryScheduleSprintExecution(productID: request.productID)
      }
    } catch {
      if let persisted = try? await store.fetchAgentPermissionRequest(id: request.id) {
        delegate?.deliveryReplacePermissionRequest(persisted)
      }
      delegate?.deliveryErrorMessage = error.localizedDescription
    }
  }

  public func handleServerRequest(
    _ request: CodexServerRequest,
    client: CodexAppServerClient
  ) async {
    let presentation: CodexApprovalPresentation
    do {
      presentation = try CodexAppServerClient.approvalPresentation(for: request)
    } catch {
      await client.rejectUnsupportedServerRequest(request)
      return
    }
    let activeMatch = runtimeCoordinator.activeTurn(
      threadID: presentation.threadID,
      turnID: presentation.turnID
    )
    let fallbackRuns = delegate?.deliveryRuns ?? []
    let fallbackRunID = fallbackRuns
      .filter {
        $0.codexThreadID == presentation.threadID
          && ($0.status == .running || $0.status == .awaitingOwner)
      }
      .max(by: { $0.createdAt < $1.createdAt })?
      .id
    let runID = activeMatch?.runID ?? fallbackRunID
    let runStore: SQLiteStore?
    if let productID = activeMatch?.productID {
      runStore = delegate?.deliveryStore(for: productID)
    } else if let runID {
      runStore = await delegate?.deliveryStore(containingAgentRun: runID)
    } else {
      runStore = nil
    }
    guard let runID, let store = runStore else {
      await client.rejectUnsupportedServerRequest(request)
      return
    }

    let run: AgentRun
    let productPermissionRequests: [AgentPermissionRequest]
    let productPermissionGrants: [AgentPermissionGrant]
    do {
      run = try await store.fetchAgentRun(id: runID)
      productPermissionRequests = try await store.fetchAgentPermissionRequests(
        productID: run.productID
      )
      productPermissionGrants = try await store.fetchAgentPermissionGrants(
        productID: run.productID
      )
    } catch {
      delegate?.deliveryErrorMessage =
        "The permission request could not be checked against its durable history, so no response was sent. \(error.localizedDescription)"
      return
    }

    let productGrantSignature = try? CodexAppServerClient.productGrantSignature(
      for: request,
      ticketWorkspaceRoot: run.worktreePath.map {
        URL(fileURLWithPath: $0)
      }
    )
    let reusableProductGrantSignature = productGrantSignature.flatMap { signature in
      AgentPermissionGrantPolicy.isReusableProductGrant(
        signature: signature,
        kind: presentation.kind
      ) ? signature : nil
    }
    let serverRequestID = Self.serverRequestID(request.id)
    let exactRequest =
      productPermissionRequests
      .filter {
        $0.agentRunID == runID
          && $0.serverRequestID == serverRequestID
          && $0.signature == presentation.signature
      }
      .max(by: { $0.updatedAt < $1.updatedAt })

    if let signature = productGrantSignature,
      AgentPermissionGrantPolicy.requestsProtectedSpeditoStorage(
        productGrantSignature: signature,
        kind: presentation.kind,
        ticketWorkspaceRoot: run.worktreePath.map {
          URL(fileURLWithPath: $0)
        },
        protectedStorageRoots: CodexPermissionProfiles.protectedSpeditoDeliveryStorageRoots
      )
    {
      let policyExplanation =
        "Spedito protected storage owned by another execution. This delivery run must use its assigned ticket worktree; managed preview, integration, product-control, and other ticket workspaces are not available to it."
      let recordedReason =
        presentation.reason.map {
          "\(policyExplanation)\n\nAgent rationale: \($0)"
        } ?? policyExplanation
      let record =
        exactRequest
        ?? permissionRequestRecord(
          run: run,
          presentation: presentation,
          request: request,
          productGrantSignature: productGrantSignature,
          reason: recordedReason,
          status: .policyDenyPendingDelivery
        )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: exactRequest != nil,
        intent: .policyDenyPendingDelivery,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }
    if let signature = productGrantSignature,
      AgentPermissionGrantPolicy.requestsProhibitedConfigurationRoot(
        productGrantSignature: signature,
        kind: presentation.kind
      )
    {
      let policyExplanation =
        "Broad configuration directories cannot be granted to a delivery run. Request only the exact configuration file or runtime directory required by this ticket."
      let recordedReason =
        presentation.reason.map {
          "\(policyExplanation)\n\nAgent rationale: \($0)"
        } ?? policyExplanation
      let record =
        exactRequest
        ?? permissionRequestRecord(
          run: run,
          presentation: presentation,
          request: request,
          productGrantSignature: productGrantSignature,
          reason: recordedReason,
          status: .policyDenyPendingDelivery
        )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: exactRequest != nil,
        intent: .policyDenyPendingDelivery,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }


    if let exactRequest {
      if let intent = exactRequest.status.replayIntent {
        await resolveAutomaticPermissionRequest(
          exactRequest,
          isPersisted: true,
          intent: intent,
          serverRequest: request,
          store: store,
          client: client
        )
      } else {
        runtimeCoordinator.registerLiveApprovalRequest(
          id: exactRequest.id,
          productID: run.productID,
          request: request
        )
        delegate?.deliveryReplacePermissionRequest(exactRequest)
      }
      return
    }

    if let priorDecision =
      (productPermissionRequests
        .filter {
          $0.agentRunID == runID
            && $0.signature == presentation.signature
            && $0.status.replayIntent != nil
            && ($0.status != .existingAccess
              || $0.turnID == presentation.turnID)
            && ($0.status != .existingAccessPendingDelivery
              || $0.turnID == presentation.turnID)
        }
        .max(by: { $0.updatedAt < $1.updatedAt })),
      let intent = priorDecision.status.replayIntent
    {
      let record = permissionRequestRecord(
        run: run,
        presentation: presentation,
        request: request,
        productGrantSignature: reusableProductGrantSignature,
        reason: presentation.reason,
        status: intent
      )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: false,
        intent: intent,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }

    if let signature = productGrantSignature,
      AgentPermissionGrantPolicy.coversActiveRunRequest(
        productGrantSignature: signature,
        kind: presentation.kind,
        turnID: presentation.turnID,
        ticketWorkspaceRoot: run.worktreePath.map {
          URL(fileURLWithPath: $0)
        },
        writableTransientStorageRoots: CodexPermissionProfiles.macOSUserTransientStorageRoots,
        requests: productPermissionRequests.filter { $0.agentRunID == runID }
      )
    {
      let record = permissionRequestRecord(
        run: run,
        presentation: presentation,
        request: request,
        productGrantSignature: reusableProductGrantSignature,
        reason: presentation.reason,
        status: .existingAccessPendingDelivery
      )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: false,
        intent: .existingAccessPendingDelivery,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }

    if let signature = productGrantSignature,
      AgentPermissionGrantPolicy.covers(
        productGrantSignature: signature,
        kind: presentation.kind,
        grants: productPermissionGrants.filter { $0.productID == run.productID }
      )
    {
      let record = permissionRequestRecord(
        run: run,
        presentation: presentation,
        request: request,
        productGrantSignature: reusableProductGrantSignature,
        reason: presentation.reason,
        status: .grantAccessPendingDelivery
      )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: false,
        intent: .grantAccessPendingDelivery,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }

    let record = permissionRequestRecord(
      run: run,
      presentation: presentation,
      request: request,
      productGrantSignature: reusableProductGrantSignature,
      reason: presentation.reason,
      status: .pending
    )
    do {
      let saved = try await store.saveAgentPermissionRequest(record)
      runtimeCoordinator.registerLiveApprovalRequest(
        id: saved.id,
        productID: run.productID,
        request: request
      )
      delegate?.deliveryReplacePermissionRequest(saved)
      _ = try await updateAgentRun(
        id: run.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "Waiting for a scoped permission decision"
      )
      await delegate?.deliveryReloadSelectedProductIfCurrent(productID: run.productID)
    } catch {
      delegate?.deliveryErrorMessage =
        "The permission request could not be saved, so no response was sent. \(error.localizedDescription)"
    }
  }

  private func permissionRequestRecord(
    run: AgentRun,
    presentation: CodexApprovalPresentation,
    request: CodexServerRequest,
    productGrantSignature: String?,
    reason: String?,
    status: AgentPermissionRequestStatus
  ) -> AgentPermissionRequest {
    AgentPermissionRequest(
      productID: run.productID,
      workItemID: run.workItemID,
      agentRunID: run.id,
      threadID: presentation.threadID,
      turnID: presentation.turnID,
      serverRequestID: Self.serverRequestID(request.id),
      method: request.method,
      kind: presentation.kind,
      title: presentation.title,
      detail: presentation.detail,
      reason: reason,
      signature: presentation.signature,
      productGrantSignature: productGrantSignature,
      status: status
    )
  }

  private func resolveAutomaticPermissionRequest(
    _ request: AgentPermissionRequest,
    isPersisted: Bool,
    intent: AgentPermissionRequestStatus,
    serverRequest: CodexServerRequest,
    store: SQLiteStore,
    client: CodexAppServerClient
  ) async {
    do {
      let durableRequest =
        if isPersisted {
          request
        } else {
          try await store.saveAgentPermissionRequest(request)
        }
      let proposedGrant: AgentPermissionGrant?
      if intent == .allowProductPendingDelivery {
        guard let signature = durableRequest.productGrantSignature else {
          throw PersistenceError.corruptData(
            "The saved product permission has no reusable signature"
          )
        }
        proposedGrant = AgentPermissionGrant(
          productID: durableRequest.productID,
          sourceRequestID: durableRequest.id,
          method: durableRequest.method,
          kind: durableRequest.kind,
          title: durableRequest.title,
          detail: durableRequest.detail,
          signature: signature
        )
      } else {
        proposedGrant = nil
      }
      let result = try await AgentPermissionResolver(
        persistence: store,
        responder: client
      ).resolve(
        request: durableRequest,
        serverRequest: serverRequest,
        intent: intent,
        productGrant: proposedGrant
      )
      if result.responseDelivered {
        runtimeCoordinator.removeLiveApprovalRequest(id: result.request.id)
      }
      delegate?.deliveryReplacePermissionRequest(result.request)
      if let grant = result.grant {
        delegate?.deliveryReplacePermissionGrant(grant)
      }
    } catch {
      if let persisted = try? await store.fetchAgentPermissionRequest(id: request.id) {
        delegate?.deliveryReplacePermissionRequest(persisted)
      }
      delegate?.deliveryErrorMessage = error.localizedDescription
    }
  }

  @discardableResult
  private func updateAgentRun(
    id: UUID,
    status: AgentRunStatus,
    eventActor: String? = nil,
    eventDetail: String? = nil
  ) async throws -> AgentRun {
    guard let store = await delegate?.deliveryStore(containingAgentRun: id) else {
      throw PersistenceError.recordNotFound("Spedito database")
    }
    let previous = try await store.fetchAgentRun(id: id)
    let updated = try await store.updateAgentRun(
      id: id,
      status: status,
      eventActor: eventActor,
      eventDetail: eventDetail
    )
    await delegate?.deliveryAgentRunDidUpdate(previous: previous, updated: updated)
    return updated
  }

  private static func serverRequestID(_ id: JSONValue) -> String {
    if let string = id.stringValue { return string }
    if let integer = id.integerValue { return String(integer) }
    return String(describing: id)
  }
}
