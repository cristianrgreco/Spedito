import Foundation

public struct CodexTurnIdentity: Equatable, Sendable {
  public let threadID: String
  public let turnID: String

  public init(threadID: String, turnID: String) {
    self.threadID = threadID
    self.turnID = turnID
  }
}

public struct FeatureOperationToken<Key: Hashable>: Hashable {
  public let key: Key
  fileprivate let identity: UUID
}

@MainActor
public final class FeatureOperationRegistry<Key: Hashable> {
  private struct Entry {
    let productID: UUID?
    let token: FeatureOperationToken<Key>
    var task: Task<Void, Never>?
    var turn: CodexTurnIdentity?
  }

  private var entries: [Key: Entry] = [:]
  private var settlementWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

  public init() {}

  public var isBusy: Bool { !entries.isEmpty }
  public var activeKeys: Set<Key> { Set(entries.keys) }

  public func activeKeys(productID: UUID) -> Set<Key> {
    Set(
      entries.compactMap { key, entry in
        entry.productID == productID ? key : nil
      })
  }

  public func productID(for key: Key) -> UUID? {
    entries[key]?.productID
  }

  public func isActive(_ key: Key) -> Bool {
    entries[key] != nil
  }

  public func isCurrent(_ token: FeatureOperationToken<Key>) -> Bool {
    entries[token.key]?.token == token
  }

  public func token(for key: Key) -> FeatureOperationToken<Key>? {
    entries[key]?.token
  }

  @discardableResult
  public func claim(
    _ key: Key,
    productID: UUID?,
    replacing: Bool = false
  ) -> FeatureOperationToken<Key>? {
    guard replacing || entries[key] == nil else { return nil }
    entries[key]?.task?.cancel()
    let token = FeatureOperationToken(key: key, identity: UUID())
    entries[key] = Entry(productID: productID, token: token, task: nil, turn: nil)
    return token
  }

  @discardableResult
  public func start(
    _ key: Key,
    productID: UUID?,
    replacing: Bool = false,
    operation: @escaping @MainActor (FeatureOperationToken<Key>) async -> Void
  ) -> FeatureOperationToken<Key>? {
    guard replacing || entries[key] == nil else { return nil }
    let previousTask = entries[key]?.task
    previousTask?.cancel()
    let token = FeatureOperationToken(key: key, identity: UUID())
    let task = Task { @MainActor [weak self] in
      await previousTask?.value
      guard !Task.isCancelled else {
        self?.finish(token)
        return
      }
      await operation(token)
      self?.finish(token)
    }
    entries[key] = Entry(productID: productID, token: token, task: task, turn: nil)
    return token
  }

  @discardableResult
  public func enqueue(
    _ key: Key,
    productID: UUID?,
    operation: @escaping @MainActor () async -> Void
  ) -> FeatureOperationToken<Key> {
    let previousTask = entries[key]?.task
    let token = FeatureOperationToken(key: key, identity: UUID())
    let task = Task { @MainActor [weak self] in
      await previousTask?.value
      guard !Task.isCancelled else {
        self?.finish(token)
        return
      }
      await operation()
      self?.finish(token)
    }
    entries[key] = Entry(productID: productID, token: token, task: task, turn: nil)
    return token
  }

  public func recordTurn(
    _ turn: CodexTurnIdentity,
    for token: FeatureOperationToken<Key>
  ) {
    guard var entry = entries[token.key], entry.token == token else { return }
    entry.turn = turn
    entries[token.key] = entry
  }

  public func clearTurn(for token: FeatureOperationToken<Key>) {
    guard var entry = entries[token.key], entry.token == token else { return }
    entry.turn = nil
    entries[token.key] = entry
  }

  public func turn(for key: Key) -> CodexTurnIdentity? {
    entries[key]?.turn
  }

  public func finish(_ token: FeatureOperationToken<Key>) {
    let waiters = settlementWaiters.removeValue(forKey: token.identity) ?? []
    for waiter in waiters {
      waiter.resume()
    }
    guard entries[token.key]?.token == token else { return }
    entries.removeValue(forKey: token.key)
  }

  public func cancelTask(_ key: Key) {
    entries[key]?.task?.cancel()
  }

  public func settle(_ key: Key) async {
    guard let entry = entries[key] else { return }
    await entry.task?.value
  }

  public func settleAll() async {
    while !entries.isEmpty {
      let currentEntries = Array(entries.values)
      for entry in currentEntries {
        if let task = entry.task {
          await task.value
        } else {
          await waitForSettlement(entry.token)
        }
      }
    }
  }

  public func cancel(
    _ key: Key,
    interrupt: (CodexTurnIdentity) async -> Void = { _ in }
  ) async {
    guard let entry = entries[key] else { return }
    entry.task?.cancel()
    if let turn = entry.turn {
      await interrupt(turn)
    }
    if let task = entry.task {
      await task.value
      finish(entry.token)
    } else {
      await waitForSettlement(entry.token)
    }
  }

  public func cancel(
    productID: UUID,
    interrupt: (CodexTurnIdentity) async -> Void = { _ in }
  ) async {
    let matchingEntries = entries.values.filter { $0.productID == productID }
    await cancel(entries: matchingEntries, interrupt: interrupt)
  }

  public func shutdown(
    interrupt: (CodexTurnIdentity) async -> Void = { _ in }
  ) async {
    await cancel(entries: Array(entries.values), interrupt: interrupt)
  }

  private func cancel(
    entries entriesToCancel: [Entry],
    interrupt: (CodexTurnIdentity) async -> Void
  ) async {
    for entry in entriesToCancel {
      entry.task?.cancel()
    }
    for entry in entriesToCancel {
      if let turn = entry.turn {
        await interrupt(turn)
      }
    }
    for entry in entriesToCancel {
      if let task = entry.task {
        await task.value
        finish(entry.token)
      } else {
        await waitForSettlement(entry.token)
      }
    }
  }

  private func waitForSettlement(_ token: FeatureOperationToken<Key>) async {
    guard isCurrent(token) else { return }
    await withCheckedContinuation { continuation in
      guard isCurrent(token) else {
        continuation.resume()
        return
      }
      settlementWaiters[token.identity, default: []].append(continuation)
    }
  }
}
