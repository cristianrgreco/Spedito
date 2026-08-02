import Testing

@testable import SpeditoApp

@Suite("Sprint goal suggestion policy")
struct SprintGoalSuggestionPolicyTests {
  @Test("New and placeholder sprint goals receive an automatic suggestion")
  func automaticSuggestionCandidates() {
    #expect(SprintGoalSuggestionPolicy.shouldGenerate(existingGoal: ""))
    #expect(SprintGoalSuggestionPolicy.shouldGenerate(existingGoal: "   "))
    #expect(
      SprintGoalSuggestionPolicy.shouldGenerate(
        existingGoal: SprintGoalSuggestionPolicy.defaultPlaceholder
      )
    )
  }

  @Test("A saved owner goal is preserved when planning reopens")
  func preservesOwnerGoal() {
    #expect(
      !SprintGoalSuggestionPolicy.shouldGenerate(
        existingGoal: "Make today's weather shareable"
      )
    )
  }
}
