import SwiftUI

// MARK: - Sidebar Editor Panel

struct SidebarView: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Éditeur SRT").font(.title2).bold()

            // SRT Text Editor
            srtEditorSection

            if !vm.subtitles.isEmpty || vm.sharedPlayer != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        timingSection
                        Divider()
                        typographySection
                        Divider()
                        subtitleBackgroundSection
                        Divider()
                        positionSection
                    }
                }
            }

            //Spacer()

            if vm.sharedPlayer != nil {
                exportSettingsSection
                exportButton
            }
        }
        .padding()
        .frame(width: 400)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }

    // MARK: - SRT Editor

    private var srtEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TEXTE BRUT")
                    .font(.caption).foregroundColor(.secondary).bold()
                Spacer()
                Button(action: vm.saveSRTFile) {
                    Label("", systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Sauvegarder le fichier SRT")

                Button("Valider") { vm.syncFromRawText() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.green)
            }
            TextEditor(text: $vm.rawSRTText)
                .font(.system(.body, design: .monospaced))
                .frame(maxHeight: .infinity)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2))
                )
        }
    }

    // MARK: - Timing

    private var timingSection: some View {
        Group {
            Text("TIMING").font(.caption).foregroundColor(.secondary).bold()
            HStack(spacing: 8) {
                TextField("Sec", text: $vm.offsetInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Button("Appliquer") { vm.applyCustomOffset() }
                    .buttonStyle(.bordered)
                Button("Indexer") { vm.reindexSubtitles() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Typography

    private var typographySection: some View {
        Group {
            Text("TYPOGRAPHIE").font(.caption).foregroundColor(.secondary).bold()
            Toggle("Majuscules", isOn: $vm.forceUppercaseSubtitles)
                            .font(.system(size: 12, weight: .bold)) // <-- NOUVEAU
            HStack {
                Text("Police")
                Spacer()
                Picker("", selection: $vm.subtitleFontName) {
                    ForEach(vm.availableFonts, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 120)
                .labelsHidden()
            }
            HStack {
                ColorPicker("", selection: $vm.subtitleColor).labelsHidden()
                Text("Couleur Texte")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Taille: \(Int(vm.subtitleFontSize))pt").font(.caption)
                Slider(value: $vm.subtitleFontSize, in: 20...120)
            }
        }
    }

    // MARK: - Subtitle Background

    private var subtitleBackgroundSection: some View {
        Group {
            Toggle("Afficher le fond (Sous-titres)", isOn: $vm.showSubtitleBackground)
                .font(.system(size: 12, weight: .bold))

            if vm.showSubtitleBackground {
                HStack {
                    ColorPicker("", selection: $vm.subtitleBgColor).labelsHidden()
                    Text("Couleur Fond")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Opacité: \(Int(vm.subtitleBgOpacity * 100))%").font(.caption)
                    Slider(value: $vm.subtitleBgOpacity, in: 0...1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arrondi: \(Int(vm.subtitleCornerRadius))").font(.caption)
                    Slider(value: $vm.subtitleCornerRadius, in: 0...30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Marges: \(Int(vm.subtitlePadding))").font(.caption)
                    Slider(value: $vm.subtitlePadding, in: 0...40)
                }
            }
        }
    }

    // MARK: - Y Position

    private var positionSection: some View {
        Group {
            Text("POSITION Y (Sous-titres)").font(.caption).foregroundColor(.secondary).bold()
            Slider(value: $vm.subtitleYPosition, in: 0.1...0.9)
        }
    }

    // MARK: - Export Settings

    private var exportSettingsSection: some View {
        Group {
            Text("EXPORT").font(.caption).foregroundColor(.secondary).bold()
            
            VStack(alignment: .leading, spacing: 6) {
                // Row 1: filename + format
                HStack(spacing: 8) {
                    TextField("Nom du fichier", text: $vm.outputFileName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Text(".mp4").foregroundColor(.secondary).font(.caption)
                    
                    Divider().frame(height: 20)
                    
                    // Format picker
                    HStack(spacing: 0) {
                        ForEach(OutputFormat.allCases) { format in
                            let isSelected = vm.outputFormat == format
                            ZStack {
                                RoundedRectangle(cornerRadius: 0)
                                    .fill(isSelected ? Color.blue.opacity(0.15) : Color.clear)
                                HStack(spacing: 3) {
                                    Image(systemName: format.icon)
                                        .font(.system(size: 10))
                                    Text(format.rawValue)
                                        .font(.caption2).bold()
                                }
                                .foregroundColor(isSelected ? .blue : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.outputFormat = format }
                            
                            if format != OutputFormat.allCases.last {
                                Divider().frame(height: 20)
                            }
                        }
                    }
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
                    .fixedSize(horizontal: false, vertical: true)
                }
                
                // Row 2: crop mode picker
                HStack(spacing: 0) {
                    ForEach(CropMode.allCases) { mode in
                        let isSelected = vm.cropMode == mode
                        ZStack {
                            RoundedRectangle(cornerRadius: 0)
                                .fill(isSelected ? Color.blue.opacity(0.15) : Color.clear)
                            HStack(spacing: 4) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 10))
                                Text(mode.description)
                                    .font(.caption2).bold()
                            }
                            .foregroundColor(isSelected ? .blue : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.cropMode = mode }
                        
                        if mode != CropMode.allCases.last {
                            Divider().frame(height: 20)
                        }
                    }
                }
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
                .fixedSize(horizontal: false, vertical: true)
                // Row 3: blur slider (only visible in blurred mode)
                if vm.cropMode == .blurred {
                    HStack(spacing: 8) {
                        Text("Flou")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 30, alignment: .leading)
                        Slider(value: $vm.blurIntensity, in: 5...80)
                        Text("\(Int(vm.blurIntensity))")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.cropMode)
        }
    }

    // MARK: - Export Button

    private var exportButton: some View {
        VStack(spacing: 8) {
            if vm.isExporting {
                ProgressView(value: vm.exportProgress) {
                    Text("Exportation en cours… \(Int(vm.exportProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .progressViewStyle(.linear)
            }

            Button(action: vm.startExportProcess) {
                Text(vm.isExporting ? "Exportation..." : "EXPORTER")
                    .bold()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)
            .disabled(vm.isExporting)
        }
    }
}
