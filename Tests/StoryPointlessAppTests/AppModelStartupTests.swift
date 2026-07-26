import Testing
@testable import StoryPointlessApp

@Suite("App model startup")
@MainActor
struct AppModelStartupTests {
  @Test("Onboarding stays hidden until the initial store load resolves")
  func initialLoadingState() async {
    let model = AppModel(store: nil)

    #expect(model.isLoading)

    await model.reload()

    #expect(!model.isLoading)
  }
}
