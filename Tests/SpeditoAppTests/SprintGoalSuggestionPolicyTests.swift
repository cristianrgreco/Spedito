import Testing

@testable import SpeditoApp

@Suite("Sprint goal suggestion policy")
struct SprintGoalSuggestionPolicyTests {
  @Test("Only a missing sprint goal receives an automatic suggestion")
  func automaticSuggestionCandidates() {
    #expect(SprintGoalSuggestionPolicy.shouldGenerate(existingGoal: ""))
    #expect(SprintGoalSuggestionPolicy.shouldGenerate(existingGoal: "   "))
  }

  @Test("An existing sprint goal is preserved")
  func preservesExistingGoal() {
    #expect(
      !SprintGoalSuggestionPolicy.shouldGenerate(
        existingGoal: "Make today's weather shareable"
      )
    )
  }
}
