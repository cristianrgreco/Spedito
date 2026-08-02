import Foundation

public struct AgentSavedAccessGroup: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case capabilities
    case command
    case other
  }

  public let id: String
  public let kind: Kind
  public let title: String
  public let detail: String
  public let grantIDs: [UUID]
  public let updatedAt: Date

  public init(
    id: String,
    kind: Kind,
    title: String,
    detail: String,
    grantIDs: [UUID],
    updatedAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.detail = detail
    self.grantIDs = grantIDs
    self.updatedAt = updatedAt
  }
}

public enum AgentPermissionGrantPolicy {
  private static let permissionMethod = "item/permissions/requestApproval"

  public static func covers(
    productGrantSignature signature: String,
    kind: CodexApprovalRequestKind,
    grants: [AgentPermissionGrant]
  ) -> Bool {
    let activeGrants = grants.filter(\.isActive)
    if activeGrants.contains(where: { $0.kind == kind && $0.signature == signature }) {
      return true
    }
    guard
      kind == .permissions,
      let requested = capabilities(fromSignature: signature)
    else {
      return false
    }

    let saved = activeGrants
      .filter { $0.kind == .permissions }
      .compactMap { capabilities(fromSignature: $0.signature) }
      .reduce(into: Capabilities()) { result, capability in
        result.formUnion(capability)
      }
    return saved.covers(requested)
  }

  public static func canonicalProductGrantValue(
    for permissions: JSONValue
  ) -> JSONValue? {
    guard let capabilities = capabilities(from: permissions) else { return nil }
    return capabilities.canonicalValue
  }

  public static func savedAccessGroups(
    for grants: [AgentPermissionGrant]
  ) -> [AgentSavedAccessGroup] {
    let activeGrants = grants.filter(\.isActive)
    let structured = activeGrants.compactMap { grant -> (AgentPermissionGrant, Capabilities)? in
      guard
        grant.kind == .permissions,
        let capabilities = capabilities(fromSignature: grant.signature)
      else { return nil }
      return (grant, capabilities)
    }
    let structuredIDs = Set(structured.map { $0.0.id })
    var groups: [AgentSavedAccessGroup] = []

    if !structured.isEmpty {
      let effective = structured
        .map(\.1)
        .reduce(into: Capabilities()) { result, capability in
          result.formUnion(capability)
        }
      groups.append(
        AgentSavedAccessGroup(
          id: "effective-capabilities",
          kind: .capabilities,
          title: "Additional access",
          detail: effective.detail,
          grantIDs: structured.map { $0.0.id }.sorted { $0.uuidString < $1.uuidString },
          updatedAt: structured.map { $0.0.createdAt }.max() ?? .distantPast
        )
      )
    }

    groups.append(
      contentsOf: activeGrants
        .filter { !structuredIDs.contains($0.id) }
        .map { grant in
          AgentSavedAccessGroup(
            id: grant.id.uuidString,
            kind: grant.kind == .command ? .command : .other,
            title: grant.kind == .command ? "Exact command" : "Additional access",
            detail: grant.detail,
            grantIDs: [grant.id],
            updatedAt: grant.createdAt
          )
        }
    )
    return groups.sorted { lhs, rhs in
      if lhs.kind == .capabilities { return true }
      if rhs.kind == .capabilities { return false }
      return lhs.updatedAt < rhs.updatedAt
    }
  }

  public static func agentContext(for grants: [AgentPermissionGrant]) -> String {
    let effective = grants
      .filter { $0.isActive && $0.kind == .permissions }
      .compactMap { capabilities(fromSignature: $0.signature) }
      .reduce(into: Capabilities()) { result, capability in
        result.formUnion(capability)
      }
    let access = effective.isEmpty
      ? "No additional filesystem or network access has saved Product Owner consent."
      : "The Product Owner has already saved consent for:\n\(effective.detailAsBullets)"
    return """
      SAVED PRODUCT ACCESS

      \(access)

      Saved consent is not active sandbox access and does not expand this ticket's scope. When the
      authorised work needs one of the listed capabilities, request the smallest coherent matching
      subset with `request_permissions`; Spedito will apply the saved consent automatically
      and record it in this ticket's Work log. Do not request unrelated access or assume that an
      exact saved command is an instruction to run it.
      """
  }

  private struct FileSystemRule: Hashable {
    let access: String
    let selector: String
    let displayLocation: String

    var detail: String {
      "\(access.prefix(1).uppercased())\(access.dropFirst()) \(displayLocation)"
    }

    var canonicalValue: JSONValue {
      .object([
        "access": .string(access),
        "selector": .string(selector),
        "displayLocation": .string(displayLocation),
      ])
    }
  }

  private struct Capabilities {
    var fileSystemRules: Set<FileSystemRule> = []
    var networkScopes: Set<String> = []

    var isEmpty: Bool {
      fileSystemRules.isEmpty && networkScopes.isEmpty
    }

    mutating func formUnion(_ other: Capabilities) {
      fileSystemRules.formUnion(other.fileSystemRules)
      networkScopes.formUnion(other.networkScopes)
    }

    func covers(_ requested: Capabilities) -> Bool {
      guard fileSystemRules.isSuperset(of: requested.fileSystemRules) else {
        return false
      }
      guard !requested.networkScopes.isEmpty else { return true }
      let unrestricted = Self.canonicalJSON(.object(["enabled": .bool(true)]))
      return networkScopes.contains(unrestricted)
        || networkScopes.isSuperset(of: requested.networkScopes)
    }

    var detail: String {
      detailLines.joined(separator: "\n")
    }

    var detailAsBullets: String {
      detailLines.map { "- \($0)" }.joined(separator: "\n")
    }

    private var detailLines: [String] {
      var lines: [String] = []
      if !networkScopes.isEmpty {
        let unrestricted = Self.canonicalJSON(.object(["enabled": .bool(true)]))
        lines.append(
          networkScopes.contains(unrestricted)
            ? "Network access"
            : "Restricted network access"
        )
      }
      lines.append(
        contentsOf: fileSystemRules
          .map(\.detail)
          .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      )
      return lines
    }

    var canonicalValue: JSONValue {
      .object([
        "speditoCapabilities": .object([
          "fileSystem": .array(
            fileSystemRules
              .sorted {
                ($0.access, $0.selector) < ($1.access, $1.selector)
              }
              .map(\.canonicalValue)
          ),
          "network": .array(networkScopes.sorted().map(JSONValue.string)),
        ])
      ])
    }

    static func canonicalJSON(_ value: JSONValue) -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = (try? encoder.encode(value)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    }
  }

  private static func capabilities(fromSignature signature: String) -> Capabilities? {
    guard let separator = signature.firstIndex(of: "|") else { return nil }
    let method = String(signature[..<separator])
    guard method == permissionMethod else { return nil }
    let jsonStart = signature.index(after: separator)
    guard let data = String(signature[jsonStart...]).data(using: .utf8) else {
      return nil
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      return nil
    }
    return capabilities(from: value)
  }

  private static func capabilities(from value: JSONValue) -> Capabilities? {
    if let canonical = value["speditoCapabilities"] {
      return canonicalCapabilities(from: canonical)
    }
    guard case .object(let root) = value else { return nil }
    guard Set(root.keys).isSubset(of: ["fileSystem", "network"]) else { return nil }
    var result = Capabilities()

    if let network = root["network"], network != .null {
      guard network["enabled"]?.boolValue == true else { return nil }
      result.networkScopes.insert(Capabilities.canonicalJSON(network))
    }

    if let fileSystem = root["fileSystem"], fileSystem != .null {
      guard case .object(let fileSystemObject) = fileSystem else { return nil }
      guard Set(fileSystemObject.keys).isSubset(of: ["entries", "read", "write"]) else {
        return nil
      }
      if let entriesValue = fileSystemObject["entries"], entriesValue != .null {
        guard let entries = entriesValue.arrayValue else { return nil }
        for entry in entries {
          guard let rule = fileSystemRule(from: entry) else { return nil }
          result.fileSystemRules.insert(rule)
        }
      }
      for (key, access) in [("read", "read"), ("write", "write")] {
        guard let values = fileSystemObject[key], values != .null else { continue }
        guard let paths = values.arrayValue else { return nil }
        for path in paths {
          guard let location = path.stringValue else { return nil }
          result.fileSystemRules.insert(
            FileSystemRule(
              access: access,
              selector: "path:\(location)",
              displayLocation: location
            )
          )
        }
      }
    }
    return result.isEmpty ? nil : result
  }

  private static func canonicalCapabilities(from value: JSONValue) -> Capabilities? {
    guard
      let fileSystem = value["fileSystem"]?.arrayValue,
      let network = value["network"]?.arrayValue
    else { return nil }
    var result = Capabilities()
    for rule in fileSystem {
      guard
        let access = rule["access"]?.stringValue,
        let selector = rule["selector"]?.stringValue,
        let displayLocation = rule["displayLocation"]?.stringValue
      else { return nil }
      result.fileSystemRules.insert(
        FileSystemRule(
          access: access,
          selector: selector,
          displayLocation: displayLocation
        )
      )
    }
    for scope in network {
      guard let scope = scope.stringValue else { return nil }
      result.networkScopes.insert(scope)
    }
    return result.isEmpty ? nil : result
  }

  private static func fileSystemRule(from value: JSONValue) -> FileSystemRule? {
    guard
      case .object(let entry) = value,
      let access = entry["access"]?.stringValue?.lowercased(),
      let path = entry["path"]
    else { return nil }
    if Set(entry.keys).subtracting(["access", "path"]).isEmpty,
      let selector = recognizedPathSelector(path)
    {
      return FileSystemRule(
        access: access,
        selector: selector.selector,
        displayLocation: selector.displayLocation
      )
    }
    let canonical = Capabilities.canonicalJSON(value)
    return FileSystemRule(
      access: access,
      selector: "entry:\(canonical)",
      displayLocation: canonical
    )
  }

  private static func recognizedPathSelector(
    _ value: JSONValue
  ) -> (selector: String, displayLocation: String)? {
    guard case .object(let path) = value else { return nil }
    let keys = Set(path.keys)
    if keys.isSubset(of: ["path", "type"]), let location = path["path"]?.stringValue {
      return ("path:\(location)", location)
    }
    if keys.isSubset(of: ["pattern", "type"]),
      let location = path["pattern"]?.stringValue
    {
      return ("pattern:\(location)", location)
    }
    if keys.isSubset(of: ["value", "type"]),
      case .object(let nested)? = path["value"],
      Set(nested.keys).isSubset(of: ["kind"]),
      let kind = nested["kind"]?.stringValue
    {
      return ("kind:\(kind)", kind)
    }
    return nil
  }
}
