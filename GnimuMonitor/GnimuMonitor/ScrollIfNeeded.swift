// Gnimu Monitor
// Copyright (C) 2026 Chris Halstead
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

/// Lays content out in the space available, and lets it scroll when the space
/// is too short. A plain frame that fills the panel would centre taller content
/// and cut off its top; this keeps the top reachable. Content that fits stays
/// where `alignment` puts it, and the view doesn't bounce.
struct ScrollIfNeeded<Content: View>: View {
    var alignment: Alignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geo.size.height, alignment: alignment)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
