//
//  Item.swift
//  MacClean
//
//  Created by 王为 on 2026/1/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
