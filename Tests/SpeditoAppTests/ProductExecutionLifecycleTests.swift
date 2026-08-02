import Foundation
import Testing
@testable import SpeditoApp

@Suite("Product execution lifecycle")
struct ProductExecutionLifecycleTests {
  @Test("Switching products leaves every delivery scheduler running")
  func productSelectionDoesNotSuspendDelivery() {
    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .productSelectionChanged
      ) == .none
    )
  }

  @Test("Archiving stops only the archived product")
  func productArchivalHasProductScope() {
    let productID = UUID()

    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .productArchived(productID)
      ) == .product(productID)
    )
  }

  @Test("App shutdown stops delivery across products")
  func appShutdownHasGlobalScope() {
    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .appShutdown
      ) == .all
    )
  }
}
