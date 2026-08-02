public enum SprintReviewCorrectionPolicy {
  public static let maximumChangeRequestsBeforeOwnerPause = 5

  public static func changeRequestNumber(reviewCycle: Int) -> Int {
    max(0, reviewCycle) + 1
  }

  public static func shouldAutomaticallyRevise(reviewCycle: Int) -> Bool {
    changeRequestNumber(reviewCycle: reviewCycle)
      < maximumChangeRequestsBeforeOwnerPause
  }
}
