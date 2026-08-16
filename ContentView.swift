import SwiftUI
import PDFKit
import CoreMIDI
import UniformTypeIdentifiers

// MARK: - Data Models
enum FileType: String, Codable {
    case pdf
    case image
}

struct SheetMusic: Identifiable, Codable {
    var id = UUID()
    var title: String
    var fileURL: URL
    var type: FileType
    var folder: String = "未分类"
}

// MARK: - MIDI Manager
class MIDIManager: ObservableObject {
    @Published var pageTurnSignal: Int? = nil // 1: 下一页, -1: 上一页
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

// MARK: - Main View
struct ContentView: View {
    @State private var sheets: [SheetMusic] = []
    @State private var folders: [String] = ["全部", "未分类", "古典", "爵士", "流行"]
    @State private var selectedFolder: String = "全部"
    @State private var isImporting: Bool = false
    
    var filteredSheets: [SheetMusic] {
        if selectedFolder == "全部" { return sheets }
        return sheets.filter { $0.folder == selectedFolder }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // 分类筛选器
                Picker("分类", selection: $selectedFolder) {
                    ForEach(folders, id: \.self) { folder in
                        Text(folder).tag(folder)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                // 乐谱列表
                if filteredSheets.isEmpty {
                    Spacer()
                    Text("暂无乐谱，请点击右上角导入")
                        .foregroundColor(.gray)
                    Spacer()
                } else {
                    List {
                        ForEach(filteredSheets) { sheet in
                            NavigationLink(destination: SheetViewer(sheet: sheet)) {
                                HStack {
                                    Image(systemName: sheet.type == .pdf ? "doc.richtext" : "photo")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading) {
                                        Text(sheet.title).font(.headline)
                                        Text(sheet.folder).font(.subheadline).foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("我的乐谱库")
            .toolbar {
                // 右上角导入按钮
                Button(action: { isImporting = true }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importFile(url: url)
                case .failure(let error):
                    print("导入失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func importFile(url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        
        let ext = url.pathExtension.lowercased()
        let type: FileType = (ext == "pdf") ? .pdf : .image
        let newSheet = SheetMusic(
            title: url.deletingPathExtension().lastPathComponent,
            fileURL: url,
            type: type,
            folder: selectedFolder == "全部" ? "未分类" : selectedFolder
        )
        sheets.append(newSheet)
    }
}

// MARK: - Sheet Viewer View
struct SheetViewer: View {
    let sheet: SheetMusic
    @StateObject private var midiManager = MIDIManager()
    @State private var currentPage: Int = 0
    @State private var pdfDocument: PDFDocument? = nil
    @State private var image: UIImage? = nil
    
    var body: some View {
        VStack {
            if sheet.type == .pdf {
                if let pdfDocument = pdfDocument {
                    PDFKitRepresentView(document: pdfDocument, currentPage: $currentPage)
                } else {
                    Text("无法读取 PDF 文件")
                }
            } else {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("无法读取图片文件")
                }
            }
        }
        .navigationTitle(sheet.title)
        .onAppear { loadFile() }
        .onReceive(midiManager.$pageTurnSignal) { signal in
            guard let signal = signal else { return }
            turnPage(by: signal)
            midiManager.pageTurnSignal = nil
        }
    }
    
    private func loadFile() {
        if sheet.type == .pdf {
            pdfDocument = PDFDocument(url: sheet.fileURL)
        } else {
            if let data = try? Data(contentsOf: sheet.fileURL) {
                image = UIImage(data: data)
            }
        }
    }
    
    private func turnPage(by delta: Int) {
        if sheet.type == .pdf, let pdf = pdfDocument {
            let newPage = currentPage + delta
            if newPage >= 0 && newPage < pdf.pageCount {
                currentPage = newPage
            }
        }
    }
}

// PDFKit 渲染器
struct PDFKitRepresentView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        if let page = document.page(at: currentPage) {
            uiView.go(to: page)
        }
    }
}
