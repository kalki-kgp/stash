import SwiftUI

/// The rounded gradient tile beside a settings row.
struct IconTile: View {
    let symbol: String
    let hue: Int
    var size: CGFloat = 26

    var body: some View {
        let color = Chrome.tileHues[hue % Chrome.tileHues.count]
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

