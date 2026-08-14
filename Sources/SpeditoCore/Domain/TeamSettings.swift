import Foundation

public struct TeamProfileSettingsUpdate: Equatable, Sendable {
  public let profileID: UUID
  public let model: String
  public let reasoningEffort: String
  public let customInstructions: String?

  public init(
    profileID: UUID,
    model: String,
    reasoningEffort: String,
    customInstructions: String?
  ) {
    self.profileID = profileID
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.customInstructions = customInstructions
  }
}

public struct TeamSettingsSnapshot: Equatable, Sendable {
  public let product: Product
  public let profiles: [AgentProfile]

  public init(product: Product, profiles: [AgentProfile]) {
    self.product = product
    self.profiles = profiles
  }
}
