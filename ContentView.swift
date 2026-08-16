import SwiftUI
import PDFKit
import CoreMIDI

// MARK: - Data Models
enum FileType: String, Codable { case pdf, image }

struct SheetMusic: Identifiable, Codable {
    var id = UUID()
    var title: String
    var fileURL: URL
    var type: FileType
    var folder: String = "未分类"
}

// MARK: - MIDI Manager
class MIDIManager: ObservableObject {
    @Published var pageTurnSignal: Int? = nil // 1: next, -1: prev
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    
    init() { setupMIDI() }
    
    private func setupMIDI() {
        MIDIClientCreate("SheetMIDI" as CFString, nil, nil, &client)
        MIDIInputPortCreate(client, "Input" as CFString, { packetList, refCon, _ in
            let manager = Unmanaged<MIDIManager>.fromOpaque(refCon!).takeUnretainedValue()
            let packets = packetList.pointee
            var packet = packets.packet
            for _ in 0..<packets.numPackets {
                if packet.length >= 2 {
                    let status = packet.data.0
                    let note = packet.data.1
                    if (status & 0xF0) == 0xB0 || (status & 0xF0) == 0x90 {
                        DispatchQueue.main.async {
                            if note == 64 { manager.pageTurnSignal = 1 }
                            else if note == 65 { manager.pageTurnSignal = -1 }
                        }
                    }
                }
                packet = MIDIPacketNext(&packet).pointee
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &inputPort)
        
        for i in 0..<MIDIGetNumberOfSources() {
            MIDIPortConnectSource(inputPort, MIDIGetSource(i), nil)
        }
    }
}

// MARK: - Main App
@main
struct SheetMusicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var sheets: [SheetMusic] = []
    @State private var selectedFolder = "全部"
    
    var body: some View {
        NavigationView {
            List(sheets) { sheet in
                Text(sheet.title)
            }
            .navigationTitle("乐谱库")
        }
    }
}
