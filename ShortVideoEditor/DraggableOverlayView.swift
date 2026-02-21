import SwiftUI
import AppKit

// MARK: - Draggable Overlay View

struct DraggableOverlayView: View {
    @Binding var item: OverlayImage
    let containerHeight: CGFloat
    var onDelete: () -> Void

    @State private var isSettingsOpen = false
    @State private var showSnapLineV = false
    @State private var showSnapLineH = false

    private let snapThreshold: CGFloat = 15.0

    var body: some View {
        let currentScale = item.scale + item.currentScale
        let w = (containerHeight * 0.4) * currentScale
        let h = w / item.aspectRatio

        ZStack {
            // Invisible anchor for popover attachment
            Color.clear
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .popover(isPresented: $isSettingsOpen, arrowEdge: .bottom) {
                    OverlaySettingsPopover(item: $item, onDelete: onDelete)
                }

            // Rotatable image content with its own background style
            ZStack {
                Image(nsImage: item.nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: w)
                    .padding(item.showBackground ? item.bgPadding : 0)
                    .background {
                        if item.showBackground {
                            RoundedRectangle(cornerRadius: item.bgCornerRadius)
                                .fill(item.bgColor.opacity(item.bgOpacity))
                        }
                    }
            }
            .rotationEffect(.degrees(item.rotation))
        }
        .offset(item.offset)
        .onTapGesture(count: 2) {
            isSettingsOpen.toggle()
        }
        .gesture(
            SimultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        var newWidth = item.lastOffset.width + value.translation.width
                        var newHeight = item.lastOffset.height + value.translation.height

                        // Snap to center
                        if abs(newWidth) < snapThreshold {
                            if !showSnapLineV {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            }
                            newWidth = 0
                            showSnapLineV = true
                        } else {
                            showSnapLineV = false
                        }

                        if abs(newHeight) < snapThreshold {
                            if !showSnapLineH {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            }
                            newHeight = 0
                            showSnapLineH = true
                        } else {
                            showSnapLineH = false
                        }

                        item.offset = CGSize(width: newWidth, height: newHeight)
                    }
                    .onEnded { _ in
                        item.lastOffset = item.offset
                        showSnapLineV = false
                        showSnapLineH = false
                    },
                MagnificationGesture()
                    .onChanged { value in
                        item.currentScale = (value - 1.0) * item.scale
                    }
                    .onEnded { _ in
                        item.scale += item.currentScale
                        item.currentScale = 0
                    }
            )
        )
        .overlay {
            // Snap guide lines extend well beyond the container
            if showSnapLineV {
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 1, height: containerHeight * 2)
                    .allowsHitTesting(false)
            }
            if showSnapLineH {
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: containerHeight * 2, height: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Overlay Settings Popover

struct OverlaySettingsPopover: View {
    @Binding var item: OverlayImage
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Réglages Image").font(.headline)
            Divider()

            // Rotation
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rotation")
                    Spacer()
                    Text("\(Int(item.rotation))°")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(value: $item.rotation, in: 0...360, step: 1).controlSize(.small)
                if item.rotation != 0 {
                    Button("Remettre à 0°") {
                        withAnimation { item.rotation = 0 }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }

            Divider()

            // Independent background style for this overlay
            Toggle("Fond translucide", isOn: $item.showBackground)

            if item.showBackground {
                HStack {
                    ColorPicker("", selection: $item.bgColor).labelsHidden()
                    Text("Couleur du fond")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Opacité: \(Int(item.bgOpacity * 100))%").font(.caption)
                    Slider(value: $item.bgOpacity, in: 0...1).controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arrondi: \(Int(item.bgCornerRadius))").font(.caption)
                    Slider(value: $item.bgCornerRadius, in: 0...30).controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Marge: \(Int(item.bgPadding))").font(.caption)
                    Slider(value: $item.bgPadding, in: 0...40).controlSize(.small)
                }
            }

            Divider()

            Button(action: onDelete) {
                Label("Supprimer", systemImage: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 260)
    }
}
