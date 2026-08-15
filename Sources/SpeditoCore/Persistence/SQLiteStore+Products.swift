import Foundation
import SQLite3

extension SQLiteStore {
  public func createProduct(
    name: String,
    color: ProductColor? = nil,
    id: UUID = UUID()
  ) throws -> Product {
    let product = Product(
      id: id,
      name: name,
      color: try color ?? nextProductColor()
    )

    try transaction {
      try withStatement(
        """
        INSERT INTO products (
            id, name, instructions, status, color, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(product.id.uuidString, to: 1, in: statement)
        try bind(product.name, to: 2, in: statement)
        try bind(product.instructions, to: 3, in: statement)
        try bind(product.status.rawValue, to: 4, in: statement)
        try bind(product.color.rawValue, to: 5, in: statement)
        try bind(product.createdAt.timeIntervalSince1970, to: 6, in: statement)
        try bind(product.updatedAt.timeIntervalSince1970, to: 7, in: statement)
        try stepDone(statement)
      }

      _ = try insertEvent(
        productID: product.id,
        kind: "product.created",
        actor: "owner",
        detail: product.name
      )
    }

    return product
  }

  private func nextProductColor() throws -> ProductColor {
    let existingColors = try withStatement(
      """
      SELECT color
      FROM products
      WHERE status = 'active'
      ORDER BY created_at ASC, id ASC;
      """
    ) { statement in
      var colors: [ProductColor] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let rawValue = try text(statement, column: 0)
        guard let color = ProductColor(rawValue: rawValue) else {
          throw PersistenceError.corruptData("Invalid product color")
        }
        colors.append(color)
      }
      return colors
    }

    return ProductColor.nextAssigned(after: existingColors)
  }

  public func fetchProducts(status: ProductStatus? = .active) throws -> [Product] {
    let statusClause = status == nil ? "" : "WHERE status = ?"
    return try withStatement(
      """
      SELECT id, name, instructions, status, color, created_at,
             COALESCE(
               (
                 SELECT created_at
                 FROM activity_events
                 WHERE product_id = products.id
                 ORDER BY sequence DESC
                 LIMIT 1
               ),
               products.updated_at
             )
      FROM products
      \(statusClause)
      ORDER BY created_at ASC;
      """
    ) { statement in
      if let status {
        try bind(status.rawValue, to: 1, in: statement)
      }
      var products: [Product] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        products.append(try decodeProduct(statement))
      }
      return products
    }
  }

  public func archiveProduct(id: UUID) throws -> Product {
    try setProductStatus(id: id, status: .archived)
  }

  public func restoreProduct(id: UUID) throws -> Product {
    let product = try fetchProduct(id: id)
    guard product.status == .archived else { return product }
    let existingColors = try fetchProducts().map(\.color)
    let restoredColor =
      existingColors.contains(product.color)
      ? ProductColor.nextUnassigned(after: existingColors) ?? product.color
      : product.color
    return try restoreProduct(id: id, color: restoredColor)
  }

  func restoreProduct(id: UUID, color: ProductColor) throws -> Product {
    try setProductStatus(id: id, status: .active, color: color)
  }

  private func setProductStatus(
    id: UUID,
    status: ProductStatus,
    color: ProductColor? = nil
  ) throws -> Product {
    var product = try fetchProduct(id: id)
    let updatedColor = color ?? product.color
    guard product.status != status || product.color != updatedColor else { return product }

    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE products SET status = ?, color = ?, updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(status.rawValue, to: 1, in: statement)
        try bind(updatedColor.rawValue, to: 2, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 3, in: statement)
        try bind(id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }
      if product.color != updatedColor {
        _ = try insertEvent(
          productID: id,
          kind: "product.color_reassigned",
          actor: "system",
          detail: "\(product.color.rawValue) → \(updatedColor.rawValue)"
        )
      }
      _ = try insertEvent(
        productID: id,
        kind: status == .archived ? "product.archived" : "product.restored",
        actor: "owner",
        detail: product.name
      )
    }

    product.status = status
    product.color = updatedColor
    product.updatedAt = updatedAt
    return product
  }

  func reassignProductColor(id: UUID, to color: ProductColor) throws -> Product {
    var product = try fetchProduct(id: id)
    guard product.color != color else { return product }

    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE products SET color = ?, updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(color.rawValue, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: id,
        kind: "product.color_reassigned",
        actor: "system",
        detail: "\(product.color.rawValue) → \(color.rawValue)"
      )
    }

    product.color = color
    product.updatedAt = updatedAt
    return product
  }

  @discardableResult
  public func updateProductInstructions(
    productID: UUID,
    instructions: String
  ) throws -> Product {
    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE products SET instructions = ?, updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(instructions.trimmingCharacters(in: .whitespacesAndNewlines), to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(productID.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: productID,
        kind: "product.instructions_updated",
        actor: "owner",
        detail: "Shared team instructions updated"
      )
    }
    return try fetchProduct(id: productID)
  }

  @discardableResult
  public func updateProductDetails(productID: UUID, name: String) throws -> Product {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw PersistenceError.corruptData("Product name cannot be empty")
    }
    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE products SET name = ?, updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(trimmedName, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(productID.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: productID,
        kind: "product.details_updated",
        actor: "owner",
        detail: trimmedName
      )
    }
    return try fetchProduct(id: productID)
  }

}
