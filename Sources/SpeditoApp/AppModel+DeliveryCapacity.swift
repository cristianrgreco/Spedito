import Foundation
import SpeditoCore

@MainActor
extension AppModel {
  func synchronizeDeliveryExecutionConstraints() async {
    for product in products where product.status == .active {
      guard let store = store(for: product.id) else { continue }
      do {
        let queuedRuns = try await store.fetchAgentRuns(productID: product.id)
          .filter { $0.status == .queued }
        let constraint = TicketDeliveryCapacityPolicy.constraint(
          from: codexRateLimits,
          isObservationStale: isCodexUsageStale,
          durableRuns: queuedRuns
        )
        await persistDeliveryExecutionConstraint(
          constraint,
          on: queuedRuns,
          productID: product.id
        )
        scheduleSprintExecution(productID: product.id)
      } catch {
        presentExecutionError(error, productID: product.id)
      }
    }
  }

  func persistDeliveryExecutionConstraint(
    _ constraint: AgentRunExecutionConstraint?,
    on queuedRuns: [AgentRun],
    productID: UUID
  ) async {
    guard let store = store(for: productID) else { return }
    var changed = false
    do {
      for run in queuedRuns where run.executionConstraint != constraint {
        _ = try await store.setAgentRunExecutionConstraint(
          id: run.id,
          constraint: constraint
        )
        changed = true
      }
      if changed {
        await reloadSelectedProductIfCurrent(productID: productID)
      }
    } catch {
      presentExecutionError(error, productID: productID)
    }
  }

  func scheduleCodexUsageReset(
    _ resetAt: Date?,
    client: CodexAppServerClient,
    monitorToken: FeatureOperationToken<CodexConnectionRuntime.Operation>
  ) {
    codexConnectionRuntime.stopNow(.usageReset)
    guard let resetAt else { return }
    let delay = resetAt.timeIntervalSinceNow + 1
    guard delay > 0 else { return }
    codexConnectionRuntime.start(.usageReset) { [weak self] _ in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard let self, self.codexConnectionRuntime.isCurrent(monitorToken) else {
        return
      }
      await self.refreshCodexUsage(client: client, monitorToken: monitorToken)
    }
  }
}
