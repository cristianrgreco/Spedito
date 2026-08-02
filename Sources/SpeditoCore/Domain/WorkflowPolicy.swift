import Foundation

public enum WorkflowError: Error, Equatable, Sendable {
  case invalidTransition(from: WorkItemState, to: WorkItemState)
}

public struct WorkflowPolicy: Sendable {
  public init() {}

  public func validateTransition(from: WorkItemState, to: WorkItemState) throws {
    guard Self.allowedTransitions[from, default: []].contains(to) else {
      throw WorkflowError.invalidTransition(from: from, to: to)
    }
  }

  public func availableTransitions(from state: WorkItemState) -> [WorkItemState] {
    Self.allowedTransitions[state, default: []]
  }

  private static let allowedTransitions: [WorkItemState: [WorkItemState]] = [
    .backlog: [.refining, .cancelled],
    .refining: [.backlog, .ready, .cancelled],
    .ready: [.refining, .queued, .cancelled],
    .queued: [.ready, .running, .cancelled],
    .running: [.queued, .integrating, .cancelled],
    .integrating: [.running, .verifying, .cancelled],
    .verifying: [.running, .acceptance, .cancelled],
    .acceptance: [.running, .readyToRelease, .cancelled],
    .readyToRelease: [.acceptance, .released, .cancelled],
    .released: [],
    .cancelled: [],
  ]
}
