import Foundation
import SwiftUI

// Set accessory policy before SwiftUI creates any windows,
// so WindowServer never transitions from .regular → .accessory
// (that transition can black-out external monitors).
NSApplication.shared.setActivationPolicy(.accessory)

// Normal GUI launch
AmpereApp.main()
