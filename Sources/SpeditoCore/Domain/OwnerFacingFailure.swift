import Foundation

/// A failure that knows how to describe itself to a product owner.
///
/// `localizedDescription` is written for whoever has to act on the detail — a
/// log, a repair prompt, a test. Nesting those descriptions is how a product
/// owner ends up reading "The delivery agent returned an invalid execution
/// result: The demo could not be prepared safely: the demo artifact path is
/// incomplete", which is three layers of implementation detail and nothing they
/// can do.
///
/// The failure contract asks for these to be separate: a stable category, one
/// concise owner-facing explanation, and technical evidence kept apart. This is
/// the owner-facing half.
public protocol OwnerFacingFailure {
  /// One sentence, in the owner's language, saying what happened and what it
  /// means for them. No nested causes, no implementation nouns.
  var ownerFacingDescription: String { get }
}

extension Error {
  /// What a product owner should be shown for this failure.
  ///
  /// Falls back to `localizedDescription` for errors that have not been given an
  /// owner-facing form yet, so adopting this is incremental rather than a flag
  /// day.
  public var ownerFacingDescription: String {
    (self as? OwnerFacingFailure)?.ownerFacingDescription ?? localizedDescription
  }
}
