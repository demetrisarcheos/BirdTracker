import SwiftUI

/// Shown on every fresh launch (not when coming back from the background):
/// hunting birds or shooting clay targets.
struct ModeChooserView: View {
    let choose: (UserMode) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "scope")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.red)
                Text("Bird Tracker")
                    .font(.largeTitle.bold())
                Text("What are you shooting at today?")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                option(.hunter, icon: "bird.fill", title: "I am a hunter",
                       detail: "Birds: distance, speed, lead, aim at the head and neck")
                option(.shooter, icon: "circle.circle.fill", title: "I am a shooter",
                       detail: "Clay targets at the shooting range")
                Text("You can change this later in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }

    private func option(_ mode: UserMode, icon: String, title: String, detail: String) -> some View {
        Button {
            choose(mode)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(mode == .hunter ? .yellow : .orange)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.bold()).foregroundStyle(.white)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}
