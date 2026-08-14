import Foundation

enum SpeditoResources {
  static func url(
    forResource name: String,
    withExtension fileExtension: String
  ) -> URL? {
    Bundle.main.url(
      forResource: name,
      withExtension: fileExtension
    )
      ?? Bundle.module.url(
        forResource: name,
        withExtension: fileExtension
      )
  }
}
