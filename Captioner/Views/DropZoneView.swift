import SwiftUI

struct DropZoneView: View {
    let onChoose: () -> Void

    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 148, height: 148)
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 8) {
                Text("Drop videos to add captions")
                    .font(.title2.weight(.semibold))
                Text("MP4, MOV and anything else QuickTime plays. Speech is recognized on this Mac; nothing is uploaded. Each video is exported as a new file with the captions burned in.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Button("Choose Videos…", action: onChoose)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            Text("Captions are generated in \(TranscriptionEngine.languageName(settings.locale)). Change the language in the inspector or in Settings.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
