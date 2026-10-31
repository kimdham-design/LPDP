import Cocoa
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import CoreImage

let tau = Double.pi * 2
func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, v)) }
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(calibratedRed:r, green:g, blue:b, alpha:a) }
let cream = color(0.89,0.86,0.77)

// Varispeed changes both playback speed and pitch, as a physical platter does.
final class RecordPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let speed = AVAudioUnitVarispeed()
    private let file: AVAudioFile
    private var position = 0.0
    private var stamp = ProcessInfo.processInfo.systemUptime
    private(set) var isPlaying = false
    var duration: Double { Double(file.length) / file.processingFormat.sampleRate }
    var volume: Float = 0.7 { didSet { node.volume = volume } }
    var rate: Float = 1 { willSet { capture() } didSet { speed.rate = rate } }
    var currentTime: Double {
        get { min(duration,position + (isPlaying ? (ProcessInfo.processInfo.systemUptime-stamp)*Double(rate) : 0)) }
        set {
            let resume = isPlaying
            pause(); position = clamp(newValue,0,duration)
            if resume { play() }
        }
    }
    init(contentsOf url: URL) throws {
        file = try AVAudioFile(forReading:url)
        engine.attach(node); engine.attach(speed)
        engine.connect(node,to:speed,format:file.processingFormat)
        engine.connect(speed,to:engine.mainMixerNode,format:file.processingFormat)
        engine.prepare()
        try engine.start()
    }
    private func capture() { position = currentTime; stamp = ProcessInfo.processInfo.systemUptime }
    func play() {
        guard !isPlaying else { return }
        let start = AVAudioFramePosition(position*file.processingFormat.sampleRate)
        guard start < file.length else { return }
        node.stop()
        node.scheduleSegment(file,startingFrame:start,frameCount:AVAudioFrameCount(min(file.length-start,Int64(UInt32.max))),at:nil)
        stamp = ProcessInfo.processInfo.systemUptime; isPlaying = true; node.play()
    }
    func pause() { capture(); isPlaying = false; node.stop() }
    func stop() { pause(); position = 0 }
    deinit { node.stop(); engine.stop() }
}

struct Album: Codable {
    var id = UUID().uuidString
    var path: String
    var title: String
    var artist = "알 수 없는 아티스트"
    var album = "앨범 정보 없음"
    var genre = "—"
    var year = "—"
    var duration = 0.0
    var sampleRate = 0.0
    var channels = 0
    var artwork: String? = nil
}
let ink = color(0.23,0.25,0.23)
let muted = color(0.55,0.55,0.50)
let accent = color(0.37,0.43,0.33)

final class DeckView: NSView {
    var library: [Album] = []
    var selected: String?
    var mounted: String?
    var player: RecordPlayer?
    var motor = false, lifted = true
    var rpm = 33.333, pitch = 0.0, volume = 0.7
    var angle = 0.0, velocity = 0.0, needle = 0.0
    var armProgress = 0.0
    var renderedArmAngle = -6.0 * Double.pi / 180
    var previousTick = ProcessInfo.processInfo.systemUptime
    var timer: Timer?
    var dragging: String?
    var armGrabOffset = CGPoint.zero
    var armWasLifted = true
    var draggedID: String?
    var dragStart = CGPoint.zero, dragPoint = CGPoint.zero
    var moved = false, hovering = false
    var sleeveOpen: String?
    var sleeveReveal = 0.0
    var flightID: String?
    var flightFrom = CGPoint.zero, flightTo = CGPoint.zero
    var flightProgress = 0.0
    var flightMount = false
    var shelfPage = 0
    var showDetails = false
    var playerOnly = false
    var minimalPlayer = true
    var playbackMode = 0
    let playbackModes = ["한 곡 감상", "컬렉션 연속", "한 곡 반복", "셔플"]
    var contextAlbumID: String?
    var lastRemoved: (album:Album,index:Int)?
    var theme = "plain"
    let themeNames = [("plain","기본"),("walnut","우드"),("stone","스톤"),("midnight","딥 블루"),("album","앨범 아트 · 블러")]
    var themeButtonRect:CGRect {
        let focus = focusButtonRect
        return CGRect(x:focus.minX-112,y:focus.minY,width:100,height:focus.height)
    }
    @objc func selectTheme(_ sender:NSMenuItem) {
        theme = themeNames[sender.tag].0
        if theme == "album" { minimalPlayer = true; if !testing { UserDefaults.standard.set(true,forKey:"minimalPlayer") } }
        if !testing { UserDefaults.standard.set(theme,forKey:"backgroundTheme") }
        needsDisplay = true
    }
    @objc func choosePlayerStyle(_ sender:NSMenuItem) {
        minimalPlayer = sender.tag == 1
        if !testing { UserDefaults.standard.set(minimalPlayer,forKey:"minimalPlayer") }
        needsDisplay = true
    }
    func showThemeMenu(_ event:NSEvent) {
        let menu = NSMenu()
        for (i,entry) in themeNames.enumerated() {
            let item = NSMenuItem(title:entry.1,action:#selector(selectTheme(_:)),keyEquivalent:"")
            item.tag = i; item.target = self; item.state = theme == entry.0 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (tag,title) in [(1,"미니멀 · LP와 톤암"),(0,"클래식 · 흰색 본체")] {
            let item = NSMenuItem(title:title,action:#selector(choosePlayerStyle(_:)),keyEquivalent:"")
            item.target = self; item.tag = tag; item.state = minimalPlayer == (tag == 1) ? .on : .off; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    var lightTarget = CGPoint(x:-0.65,y:-0.65)
    var lightPosition = CGPoint(x:-0.65,y:-0.65)
    var lightTracking: NSTrackingArea?
    var reflectionImage: CGImage?
    var lastReflectionTime = 0.0
    struct SurfaceSample {
        var nx:Double; var ny:Double; var radius:Double; var mask:Double
    }
    lazy var surface: [SurfaceSample] = {
        var result:[SurfaceSample] = []; result.reserveCapacity(256*256)
        for y in 0..<256 { for x in 0..<256 {
            let px = (Double(x)+0.5-128)/128, py = (Double(y)+0.5-128)/128
            let r = hypot(px,py)
            let edge = clamp((1-r)*130,0,1)*clamp((r-0.357)*100,0,1)
            result.append(SurfaceSample(nx:px/max(r,0.001),ny:py/max(r,0.001),radius:r,mask:edge))
        } }
        return result
    }()
    var notice = "음악을 선반에 모으고, 한 장씩 꺼내 들어보세요."
    var images: [String:NSImage] = [:]
    var rasterImages: [String:CGImage] = [:]
    let testing = CommandLine.arguments.contains("--self-test")
    var storage: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GrooveListeningRoom")
    }
    var scale: CGFloat {
        playerOnly ? min((bounds.width-64)/800,(bounds.height-100)/533.333) : min(bounds.width/1440,bounds.height/960)
    }
    var offset: CGPoint {
        if playerOnly { return CGPoint(x:bounds.midX-520*scale,y:64+(bounds.height-88)/2-436.6665*scale) }
        return CGPoint(x:(bounds.width-1440*scale)/2,y:(bounds.height-960*scale)/2)
    }
    var focusButtonRect:CGRect {
        if playerOnly { return CGRect(x:bounds.width-130,y:20,width:102,height:32) }
        return CGRect(x:offset.x+1080*scale,y:offset.y+38*scale,width:100*scale,height:38*scale)
    }
    func togglePlayerOnly() {
        playerOnly.toggle(); dragging = nil; draggedID = nil
        needsDisplay = true
    }
    var active: Album? { library.first { $0.id == (selected ?? mounted) } }
    var onDeck: Album? { library.first { $0.id == mounted } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame)
        registerForDraggedTypes([.fileURL])
        if !testing {
            playbackMode = min(3,max(0,UserDefaults.standard.integer(forKey:"playbackMode")))
            if UserDefaults.standard.object(forKey:"volume") != nil { volume = clamp(UserDefaults.standard.double(forKey:"volume"),0,1) }
        }
        if !testing, UserDefaults.standard.object(forKey:"minimalPlayer") != nil { minimalPlayer = UserDefaults.standard.bool(forKey:"minimalPlayer") }
        if !testing, let saved = UserDefaults.standard.string(forKey:"backgroundTheme"), themeNames.contains(where:{$0.0 == saved}) { theme = saved }
        if !testing, let data = try? Data(contentsOf:storage.appendingPathComponent("library.json")), let saved = try? JSONDecoder().decode([Album].self,from:data) { library = saved; selected = saved.first?.id }
        timer = Timer.scheduledTimer(withTimeInterval:1/60,repeats:true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer,forMode:.common) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let lightTracking { removeTrackingArea(lightTracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); lightTracking = area
    }
    override func mouseMoved(with event:NSEvent) { aimLight(point(event)) }
    override func mouseExited(with event:NSEvent) { lightTarget = CGPoint(x:-0.65,y:-0.65) }
    func aimLight(_ p:CGPoint) {
        lightTarget = CGPoint(x:-0.8+clamp((p.x-platterCenter.x)/900,-0.3,0.3),y:-0.7+clamp((p.y-platterCenter.y)/900,-0.3,0.3))
    }
    func updateReflection() {
        let n = 256, lx = Double(lightPosition.x), ly = Double(lightPosition.y)
        let length = max(0.01,hypot(lx,ly))
        let dx = lx/length, dy = ly/length
        let phase = angle * Double.pi/180
        let co = cos(phase), si = sin(phase)
        var pixels = [UInt8](repeating:0,count:n*n*4)
        for i in surface.indices {
            let p = surface[i]
            guard p.mask > 0 else { continue }
            // Concentric groove tangents produce anisotropic paired softbox reflections.
            let alignment = abs(p.nx*dx+p.ny*dy)
            let lobe = pow(alignment,12)
            let broad = pow(alignment,4)*0.06
            let fill = pow(abs(p.nx*0.88-p.ny*0.475),48)*0.085
            let rotatedX = p.nx*co+p.ny*si
            let rotatedY = p.ny*co-p.nx*si
            let grain = 0.985+0.008*sin(p.radius*90+rotatedX*4)+0.007*sin(p.radius*55+rotatedY*6)
            let fresnel = 0.42+0.58*pow(p.radius,1.6)
            let illumination = 0.22+0.10*min(1.3,length)
            let specular = clamp((lobe+broad+fill)*fresnel*grain*illumination*p.mask,0,0.85)
            let a = UInt8(specular*255)
            // Premultiplied cool-neutral reflected light, composited in screen space.
            pixels[i*4] = UInt8(Double(a)*0.94)
            pixels[i*4+1] = UInt8(Double(a)*0.97)
            pixels[i*4+2] = a; pixels[i*4+3] = a
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data:data as CFData)!
        reflectionImage = CGImage(width:n,height:n,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:n*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
    required init?(coder:NSCoder) { fatalError() }
    func save() {
        guard !testing else { return }
        do {
            try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
            try JSONEncoder().encode(library).write(to:storage.appendingPathComponent("library.json"),options:.atomic)
        } catch { notice = "선반 저장 실패: \(error.localizedDescription)" }
    }
    func advanceRotation(_ elapsed: Double) {
        // Keep the physical angle continuous across complete turns and view-mode switches.
        angle += max(0,velocity) * 6 * max(0,elapsed)
    }
    func updateMotor(_ elapsed:Double) {
        if motor {
            let target = rpm*(1+pitch/100)
            velocity += (target-velocity)*(1-exp(-elapsed*2.3))
        } else {
            // Bearing friction + gentle brake drag: decelerate continuously, then reach exact rest.
            velocity = max(0,(velocity+25)*exp(-0.4*elapsed)-25)
            if velocity < 0.03 { velocity = 0 }
        }
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime, dt = min(0.1,now-previousTick); previousTick = now
        sleeveReveal += ((sleeveOpen == nil ? 0.0 : 1.0)-sleeveReveal)*min(1,dt*10)
        if let id = flightID {
            flightProgress = min(1,flightProgress+dt/0.45)
            if flightProgress >= 1 {
                flightID = nil
                if flightMount { mount(id); sleeveOpen = nil } else { sleeveOpen = nil }
            }
        }
        lightPosition.x += (lightTarget.x-lightPosition.x)*min(1,dt*9)
        lightPosition.y += (lightTarget.y-lightPosition.y)*min(1,dt*9)
        updateMotor(dt)
        advanceRotation(dt)
        let destination = mounted != nil ? 1.0 : 0.0
        armProgress += (destination-armProgress)*min(1,dt*4)
        if let p = player {
            p.rate = Float(clamp(velocity/33.333,0.25,4))
            needle = clamp(p.currentTime / max(0.01,p.duration),0,1)
            // Below the varispeed minimum, fade the remaining sound smoothly into silence.
            p.volume = Float(volume * (motor ? 1 : clamp(velocity/(33.333*0.25),0,1)))
            if !motor && velocity == 0 { p.pause() }
            if motor && !lifted && armProgress > 0.97 && abs(renderedArmAngle-grooveAngle(needle)) < 0.01 && velocity > 8 && !p.isPlaying && dragging != "seek" && needle < 0.999 { p.play() }
            if p.isPlaying && p.currentTime >= p.duration-0.04 { finishTrack() }
        }
        let targetAngle = mounted == nil ? restAngle : grooveAngle(needle)
        renderedArmAngle += (targetAngle-renderedArmAngle)*min(1,dt*7)
        if now-lastReflectionTime >= 1/30 || reflectionImage == nil {
            updateReflection(); lastReflectionTime = now
        }
        needsDisplay = true
    }
    @discardableResult func add(_ url:URL) -> String? {
        if let existing = library.first(where:{$0.path == url.path}) { selected = existing.id; return existing.id }
        do {
            let file = try AVAudioFile(forReading:url)
            var item = Album(path:url.path,title:url.deletingPathExtension().lastPathComponent)
            item.duration = Double(file.length)/file.processingFormat.sampleRate
            item.sampleRate = file.processingFormat.sampleRate; item.channels = Int(file.processingFormat.channelCount)
            library.append(item); selected = item.id; shelfPage = (library.count-1)/8; save()
            readMetadata(item)
            notice = "선반에 추가했습니다. 커버를 턴테이블로 끌어다 놓으세요."
            return item.id
        } catch { notice = "열 수 없는 오디오 파일: \(url.lastPathComponent)"; return nil }
    }
    func readMetadata(_ item:Album) {
        Task { [weak self] in
            let asset = AVURLAsset(url:URL(fileURLWithPath:item.path))
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            var title: String?, artist: String?, album: String?, year: String?, art: Data?
            for m in metadata {
                switch m.commonKey {
                case .commonKeyTitle: title = try? await m.load(.stringValue)
                case .commonKeyArtist: artist = try? await m.load(.stringValue)
                case .commonKeyAlbumName: album = try? await m.load(.stringValue)
                case .commonKeyCreationDate: year = try? await m.load(.stringValue)
                case .commonKeyArtwork: art = try? await m.load(.dataValue)
                default: break
                }
            }
            await MainActor.run {
                guard let self, let index = self.library.firstIndex(where:{$0.id == item.id}) else { return }
                if let title { self.library[index].title = title }
                if let artist { self.library[index].artist = artist }
                if let album { self.library[index].album = album }
                if let year { self.library[index].year = year }
                if self.library[index].artwork == nil, let art, NSImage(data:art) != nil, !self.testing {
                    do {
                        try FileManager.default.createDirectory(at:self.storage,withIntermediateDirectories:true)
                        let url = self.storage.appendingPathComponent(item.id+".cover")
                        try art.write(to:url,options:.atomic); self.library[index].artwork = url.path
                    } catch { self.notice = "앨범 커버를 저장하지 못했습니다." }
                }
                self.save(); self.needsDisplay = true
            }
        }
    }
    func mount(_ id:String) {
        guard let item = library.first(where:{$0.id == id}) else { return }
        do {
            let next = try RecordPlayer(contentsOf:URL(fileURLWithPath:item.path)); next.volume = Float(volume)
            player?.stop(); player = next; mounted = id; selected = id
            flightID = nil; sleeveOpen = nil
            if let index = library.firstIndex(where:{$0.id == id}) { shelfPage = index/8 }
            needle = 0; armProgress = 0; lifted = false; motor = true
            notice = "바늘을 내리는 중…  \(item.title)"
            window?.title = "LPDP — \(item.title)"
        } catch { notice = "파일을 찾거나 재생할 수 없습니다. 음반 우클릭 → 음악 파일 재연결을 이용하세요." }
    }
    func sleeveCenter(_ id:String) -> CGPoint {
        guard let index = library.firstIndex(where:{$0.id == id}) else { return CGPoint(x:136,y:838) }
        let r = cardRect(index%8); return CGPoint(x:r.midX,y:r.midY)
    }
    func flyRecord(_ id:String, from:CGPoint, mount:Bool) {
        flightID = id; flightFrom = from; flightMount = mount; flightProgress = 0
        flightTo = mount ? platterCenter : sleeveCenter(id)
    }
    func eject() {
        if let id = mounted, !playerOnly {
            if let i = library.firstIndex(where:{$0.id == id}) { shelfPage = i/8 }
            sleeveOpen = id; flyRecord(id,from:platterCenter,mount:false)
        }
        player?.stop(); player = nil; mounted = nil; motor = false; lifted = true; needle = 0
        notice = "레코드를 선반에 다시 전시했습니다."; window?.title = "LPDP — The Listening Room"
    }
    @objc func openFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { add(url) } }
    }
    @objc func changeCover() {
        guard let id = active?.id else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf:url), let tiff = img.tiffRepresentation {
            do {
                try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
                let dest = storage.appendingPathComponent(id+"-custom.tiff"); try tiff.write(to:dest,options:.atomic)
                if let i = library.firstIndex(where:{$0.id == id}) { library[i].artwork = dest.path; images[dest.path] = img; blurredCover = nil; blurredCoverKey = nil; rasterImages = rasterImages.filter { !$0.key.hasPrefix("label:") }; save() }
            } catch { notice = "커버를 저장할 수 없습니다." }
        }
    }
    func playPause() {
        if mounted == nil { if let id = selected { mount(id) } else { openFile() }; return }
        if lifted || !motor { if needle >= 0.999 { player?.currentTime = 0; needle = 0 }; lifted = false; motor = true }
        else { motor = false; notice = "모터 OFF · LP가 관성으로 감속합니다." }
    }
    func nextTrackID(direction:Int, shuffled:Bool = false) -> String? {
        guard !library.isEmpty else { return nil }
        let current = mounted ?? selected
        if shuffled { return library.filter { $0.id != current }.randomElement()?.id ?? library.first?.id }
        guard let i = library.firstIndex(where:{$0.id == current}) else { return library.first?.id }
        return library[(i+direction+library.count)%library.count].id
    }
    @objc func nextTrack() { if let id = nextTrackID(direction:1,shuffled:playbackMode == 3) { mount(id) } }
    @objc func previousTrack() {
        if let player, player.currentTime > 3 { seek(to:0); return }
        if let id = nextTrackID(direction:-1) { mount(id) }
    }
    @objc func togglePlayback() { playPause() }
    @objc func toggleCue() { lifted.toggle(); if lifted { player?.pause() } }
    @objc func ejectRecord() { eject() }
    @objc func toggleFocus() { togglePlayerOnly() }
    func finishTrack() {
        player?.pause(); if let player { player.currentTime = player.duration }
        lifted = true; motor = false; needle = 1
        switch playbackMode {
        case 1,3: nextTrack()
        case 2: if let id = mounted { mount(id) }
        default: notice = "한 면의 끝 · 다음 곡을 고르거나 레코드를 선반에 놓아보세요."
        }
    }
    func seek(to seconds:Double) {
        guard let player else { return }
        player.currentTime = clamp(seconds,0,max(0,player.duration-0.05))
        needle = player.currentTime/max(0.01,player.duration)
    }
    func seekBar(_ p:CGPoint) {
        guard active?.id == mounted, let player else { return }
        seek(to:clamp((p.x-1050)/290,0,1)*player.duration)
    }
    @objc func selectPlaybackMode(_ sender:NSMenuItem) {
        playbackMode = sender.tag
        if !testing { UserDefaults.standard.set(playbackMode,forKey:"playbackMode") }
        needsDisplay = true
    }
    func playbackMenu() -> NSMenu {
        let menu = NSMenu(title:"재생 방식")
        for (i,title) in playbackModes.enumerated() {
            let item = NSMenuItem(title:title,action:#selector(selectPlaybackMode(_:)),keyEquivalent:"")
            item.target = self; item.tag = i; item.state = playbackMode == i ? .on : .off; menu.addItem(item)
        }
        return menu
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 49 { playPause() }
        else if event.keyCode == 123 || event.keyCode == 124 {
            if event.modifierFlags.contains(.option) { if event.keyCode == 123 { previousTrack() } else { nextTrack() } }
            else { seek(to:(player?.currentTime ?? 0)+(event.keyCode == 123 ? -5 : 5)) }
        }
        else if event.keyCode == 53 { if playerOnly { togglePlayerOnly() }; dragging = nil; draggedID = nil }
        else { super.keyDown(with:event) }
    }
    override func rightMouseDown(with event:NSEvent) {
        guard !playerOnly else { return }
        let p = point(event)
        guard let index = (0..<8).map({shelfPage*8+$0}).first(where:{$0 < library.count && cardRect($0%8).contains(p)}) else { return }
        contextAlbumID = library[index].id
        let menu = NSMenu()
        for (title,action) in [("이 음반 재생",#selector(playContextAlbum)),("커버 변경…",#selector(coverContextAlbum)),("Finder에서 보기",#selector(revealContextAlbum)),("음악 파일 재연결…",#selector(relinkContextAlbum)),("선반에서 제거",#selector(removeContextAlbum))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc func playContextAlbum() { if let id = contextAlbumID { mount(id) } }
    @objc func coverContextAlbum() { selected = contextAlbumID; changeCover() }
    @objc func revealContextAlbum() {
        guard let item = library.first(where:{$0.id == contextAlbumID}) else { return }
        if FileManager.default.fileExists(atPath:item.path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:item.path)]) }
        else { notice = "파일이 이동되었습니다. 음반을 우클릭한 뒤 ‘음악 파일 재연결’을 선택하세요." }
    }
    @objc func relinkContextAlbum() {
        guard let id = contextAlbumID else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relinkAlbum(id,to:url)
    }
    @discardableResult func relinkAlbum(_ id:String,to url:URL) -> Bool {
        guard let index = library.firstIndex(where:{$0.id == id}) else { return false }
        do {
            let audio = try AVAudioFile(forReading:url)
            if library.contains(where:{$0.id != id && $0.path == url.path}) { notice = "이미 선반에 있는 파일입니다."; return false }
            if mounted == id { eject(); flightID = nil }
            library[index].path = url.path
            library[index].duration = Double(audio.length)/audio.processingFormat.sampleRate
            library[index].sampleRate = audio.processingFormat.sampleRate
            library[index].channels = Int(audio.processingFormat.channelCount)
            save(); notice = "음악 파일을 다시 연결했습니다. 커버와 앨범 정보는 유지됩니다."; return true
        } catch { notice = "열 수 없는 오디오 파일입니다."; return false }
    }
    func removeAlbum(_ id:String) {
        guard let index = library.firstIndex(where:{$0.id == id}) else { return }
        if mounted == id { eject() }
        if flightID == id { flightID = nil }
        if draggedID == id { draggedID = nil; dragging = nil }
        if sleeveOpen == id { sleeveOpen = nil }
        lastRemoved = (library[index],index)
        library.remove(at:index)
        if selected == id { selected = library.isEmpty ? nil : library[min(index,library.count-1)].id }
        shelfPage = min(shelfPage,max(0,(library.count-1)/8))
        save(); notice = "선반에서 제거했습니다. 원본 음악 파일은 그대로 보관됩니다."
    }
    @objc func restoreRemovedAlbum() {
        guard let removed = lastRemoved else { return }
        guard !library.contains(where:{$0.id == removed.album.id || $0.path == removed.album.path}) else { lastRemoved = nil; return }
        let index = min(removed.index,library.count)
        library.insert(removed.album,at:index); selected = removed.album.id; shelfPage = index/8
        lastRemoved = nil; save(); notice = "음반을 선반에 복원했습니다."
    }
    @objc func showHelp() {
        let alert = NSAlert(); alert.messageText = "LPDP 사용 안내"
        alert.informativeText = "커버를 눌러 꺼낸 LP를 턴테이블에 놓거나, 커버를 두 번 누르면 재생됩니다.\n\nSpace: 재생 / 관성 정지\n← / →: 5초 이동\nOption + ← / →: 이전 / 다음 곡\n⌘U: 톤암 올리기 / 내리기\n⌘E: LP 꺼내기\n⌘F: 플레이어만 보기\n⌘Z: 마지막으로 제거한 음반 복원\n\n곡 정보 위에서 재생 방식을 고를 수 있습니다. ‘컬렉션 연속’은 선반 순서대로 반복하고, ‘셔플’은 현재 곡을 제외한 음반을 무작위로 고릅니다.\n\n음반 우클릭: 커버 변경, Finder 열기, 파일 재연결, 선반에서 제거. 원본 파일은 삭제하지 않습니다."
        alert.runModal()
    }
    @objc func removeContextAlbum() { if let id = contextAlbumID { removeAlbum(id) } }
    func point(_ event:NSEvent) -> CGPoint { logical(convert(event.locationInWindow,from:nil)) }
    func logical(_ p:CGPoint) -> CGPoint { CGPoint(x:(p.x-offset.x)/scale,y:(p.y-offset.y)/scale) }
    func platterContains(_ p:CGPoint) -> Bool { hypot(p.x-platterCenter.x,p.y-platterCenter.y) < 218 }
    func cardRect(_ slot:Int) -> CGRect { CGRect(x:66+CGFloat(slot)*164,y:768,width:140,height:140) }
    var minimalControls:[CGRect] {
        [CGRect(x:676,y:616,width:42,height:36),CGRect(x:720,y:616,width:42,height:36),
         CGRect(x:764,y:616,width:46,height:36),CGRect(x:812,y:616,width:56,height:36),
         CGRect(x:870,y:616,width:42,height:36)]
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        if themeButtonRect.contains(convert(event.locationInWindow,from:nil)) { showThemeMenu(event); return }
        if focusButtonRect.contains(convert(event.locationInWindow,from:nil)) { togglePlayerOnly(); return }
        let p = point(event); dragStart = p; dragPoint = p; moved = false; dragging = nil; draggedID = nil
        if !playerOnly {
        if CGRect(x:1050,y:104,width:42,height:32).contains(p) { previousTrack(); return }
        if CGRect(x:1098,y:104,width:42,height:32).contains(p) { nextTrack(); return }
        if CGRect(x:1150,y:104,width:190,height:32).contains(p) { NSMenu.popUpContextMenu(playbackMenu(),with:event,for:self); return }
        if CGRect(x:1210,y:38,width:175,height:43).contains(p) { openFile(); return }
        if (CGRect(x:1060,y:414,width:280,height:30).contains(p) || CGRect(x:1082,y:167,width:226,height:226).contains(p)), active != nil { changeCover(); return }
        if CGRect(x:1230,y:704,width:50,height:35).contains(p) { shelfPage = max(0,shelfPage-1); return }
        if CGRect(x:1300,y:704,width:50,height:35).contains(p) { shelfPage = min(max(0,(library.count-1)/8),shelfPage+1); return }
        }
        if minimalPlayer {
            if let i = minimalControls.firstIndex(where:{$0.contains(p)}) {
                switch i {
                case 0: rpm = 33.333
                case 1: rpm = 45
                case 2: playPause()
                case 3: toggleCue()
                default: eject()
                }
                return
            }
        } else {
        if CGRect(x:777,y:608,width:42,height:44).contains(p) { playPause(); return }
        if CGRect(x:185,y:612,width:32,height:42).contains(p) { rpm = 33.333; return }
        if CGRect(x:221,y:612,width:32,height:42).contains(p) { rpm = 45; return }
        if CGRect(x:772,y:570,width:80,height:34).contains(p) { toggleCue(); return }
        if CGRect(x:824,y:610,width:35,height:42).contains(p) { eject(); return }
        }
        if !playerOnly {
        if CGRect(x:1050,y:634,width:290,height:26).contains(p) { dragging = "volume"; setVolume(p); return }
        if CGRect(x:1050,y:575,width:130,height:20).contains(p) { showDetails.toggle(); return }
        if showDetails && CGRect(x:1050,y:591,width:290,height:26).contains(p) { dragging = "pitch"; setPitch(p); return }
        if CGRect(x:1050,y:548,width:290,height:22).contains(p), active?.id == mounted, let player { dragging = "seek"; player.pause(); seekBar(p); return }
        }
        if tonearmContains(p) {
            if mounted != nil {
                dragging = "arm"; armWasLifted = lifted
                armGrabOffset = CGPoint(x:stylus.x-p.x,y:stylus.y-p.y)
                player?.pause(); lifted = true
            }
            return
        }
        if platterContains(p), let id = mounted { dragging = "record"; draggedID = id; return }
        if playerOnly { return }
        if let id = sleeveOpen, id != mounted {
            let c = sleeveCenter(id)
            if CGRect(x:c.x-66,y:c.y-132,width:132,height:70).contains(p) {
                dragging = "sleeve"; draggedID = id; return
            }
        }
        for slot in 0..<8 {
            let index = shelfPage*8+slot
            if index < library.count && cardRect(slot).contains(p) {
                let id = library[index].id; selected = id
                if event.clickCount == 2 { flyRecord(id,from:sleeveCenter(id),mount:true); return }
                if sleeveOpen != id { sleeveReveal = 0 }; sleeveOpen = id
                dragging = "sleeve"; draggedID = id; return
            }
        }
        if library.isEmpty && p.y > 760 { openFile() }
    }
    func setVolume(_ p:CGPoint) { volume = clamp((p.x-1050)/290,0,1); player?.volume = Float(volume); if !testing { UserDefaults.standard.set(volume,forKey:"volume") } }
    func setPitch(_ p:CGPoint) { pitch = clamp((p.x-1195)/145*8,-8,8) }
    func seekArm(_ p:CGPoint) {
        let r = hypot(p.x-platterCenter.x,p.y-platterCenter.y)
        needle = clamp((outerGrooveRadius-r)/(outerGrooveRadius-innerGrooveRadius),0,0.995)
        if let player { player.currentTime = needle*player.duration }
    }
    override func mouseDragged(with event:NSEvent) {
        let p = point(event); dragPoint = p; aimLight(p)
        if hypot(p.x-dragStart.x,p.y-dragStart.y)>5 { moved = true }
        if dragging == "seek" { seekBar(p) }
        if dragging == "volume" { setVolume(p) }
        if dragging == "pitch" { setPitch(p) }
        if dragging == "arm" && moved { seekArm(CGPoint(x:p.x+armGrabOffset.x,y:p.y+armGrabOffset.y)); armProgress = 1; renderedArmAngle = grooveAngle(needle) }
    }
    override func mouseUp(with event:NSEvent) {
        let p = point(event)
        if dragging == "sleeve", moved, platterContains(p), let id = draggedID { flyRecord(id,from:p,mount:true) }
        if dragging == "sleeve", moved, !platterContains(p), let id = draggedID { flyRecord(id,from:p,mount:false) }
        if dragging == "record" && moved && !platterContains(p) { eject() }
        if dragging == "arm" { lifted = armWasLifted }
        dragging = nil; draggedID = nil; needsDisplay = true
    }
    override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation { hovering = true; return .copy }
    override func draggingUpdated(_ sender:NSDraggingInfo) -> NSDragOperation { dragPoint = logical(convert(sender.draggingLocation,from:nil)); return .copy }
    override func draggingExited(_ sender:NSDraggingInfo?) { hovering = false }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        hovering = false
        guard let urls = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:nil) as? [URL] else { return false }
        let p = logical(convert(sender.draggingLocation,from:nil))
        var first:String?
        for url in urls { let id = add(url); if first == nil { first = id } }
        if platterContains(p), let first { mount(first) }
        return first != nil
    }
    // Calibrated to the photographed platter rim, not the slightly off-center mat spindle.
    let platterCenter = CGPoint(x:444.0,y:435.0)
    let armPivot = CGPoint(x:786.15,y:293.96)
    var stylusLocal:CGPoint { minimalPlayer ? CGPoint(x:0,y:283.2) : CGPoint(x:7.2,y:282.96) }
    let outerGrooveRadius = 207.0
    let innerGrooveRadius = 96.0
    let restAngle = -6.0 * Double.pi / 180
    func grooveAngle(_ progress:Double) -> Double {
        // Circle intersection: a fixed-length arm meets the groove radius corresponding to elapsed audio.
        let radius = outerGrooveRadius-(outerGrooveRadius-innerGrooveRadius)*clamp(progress,0,1)
        let dx = platterCenter.x-armPivot.x, dy = platterCenter.y-armPivot.y
        let distance = hypot(dx,dy), length = hypot(stylusLocal.x,stylusLocal.y)
        let cosine = clamp((distance*distance+length*length-radius*radius)/(2*distance*length),-1,1)
        return atan2(dy,dx)-acos(cosine)-atan2(stylusLocal.y,stylusLocal.x)
    }
    var armRotation: Double { renderedArmAngle }
    func tonearmContains(_ point:CGPoint) -> Bool {
        // Transform pointer into the photographed tonearm's unrotated local space.
        let dx = point.x-armPivot.x, dy = point.y-armPivot.y
        let a = armRotation
        let local = CGPoint(x:dx*cos(a)+dy*sin(a),y:-dx*sin(a)+dy*cos(a))
        let zones = [
            CGRect(x:-32,y:-68,width:64,height:106), // bearing and counterweight
            CGRect(x:-12,y:20,width:25,height:184), // chrome shaft
            CGRect(x:-14,y:195,width:38,height:92), // bend, headshell and stylus
            CGRect(x:7,y:244,width:48,height:28), // finger lift
            CGRect(x:10,y:10,width:40,height:42) // bearing lever
        ]
        return zones.contains { $0.contains(local) }
    }
    var stylus:CGPoint {
        let a = armRotation
        return CGPoint(x:armPivot.x+stylusLocal.x*cos(a)-stylusLocal.y*sin(a),
                       y:armPivot.y+stylusLocal.x*sin(a)+stylusLocal.y*cos(a))
    }
    func asset(_ name:String) -> NSImage? {
        let key = "asset:"+name
        if let cached = images[key] { return cached }
        let url: URL
        if testing {
            url = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(""+name+".png")
        } else {
            guard let resource = Bundle.main.resourceURL else { return nil }
            url = resource.appendingPathComponent("Turntable/"+name+".png")
        }
        let image = NSImage(contentsOf:url); images[key] = image; return image
    }
    func time(_ t: Double) -> String { let n = Int(max(0,t)); return String(format:"%02d:%02d",n/60,n%60) }
    func fill(_ rect: CGRect, _ c: NSColor, radius: CGFloat = 0) {
        c.setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()
    }
    func ellipse(_ rect: CGRect, _ c: NSColor) { c.setFill(); NSBezierPath(ovalIn:rect).fill() }
    func line(_ a: CGPoint, _ b: CGPoint, _ c: NSColor, _ width: CGFloat = 1) {
        let p = NSBezierPath(); p.move(to:a); p.line(to:b); p.lineWidth = width; p.lineCapStyle = .round; c.setStroke(); p.stroke()
    }
    func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12, c: NSColor = cream, weight: NSFont.Weight = .regular, width: CGFloat = 700, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle(); style.alignment = align; style.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize:size,weight:weight)
        (text as NSString).draw(in:NSRect(x:x,y:y,width:width,height:size*1.6),withAttributes:[.font:font,.foregroundColor:c,.paragraphStyle:style])
    }
    func gradient(_ rect: CGRect, _ colors: [NSColor], radius: CGFloat = 0, angle: CGFloat = 90) {
        NSGradient(colors:colors)?.draw(in:NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius),angle:angle)
    }
    func disc(_ center: CGPoint, _ radius: CGFloat, _ colors: [NSColor]) {
        NSGradient(colors:colors)?.draw(in:NSBezierPath(ovalIn:NSRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2)),angle:35)
    }
    func circleStroke(_ center: CGPoint, _ radius: CGFloat, _ c: NSColor, _ width: CGFloat = 1) {
        c.setStroke(); let p = NSBezierPath(ovalIn:NSRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2)); p.lineWidth = width; p.stroke()
    }
    func polygon(_ points:[CGPoint],_ c:NSColor,stroke:NSColor? = nil) {
        let p = NSBezierPath(); p.move(to:points[0]); for v in points.dropFirst() { p.line(to:v) }; p.close(); c.setFill(); p.fill()
        if let stroke { stroke.setStroke(); p.lineWidth = 1.5; p.stroke() }
    }
    func artwork(_ item:Album, _ rect:CGRect) {
        if let path = item.artwork {
            if images[path] == nil { images[path] = NSImage(contentsOfFile:path) }
            if let img = images[path] {
                let side = min(img.size.width,img.size.height)
                img.draw(in:rect,from:CGRect(x:(img.size.width-side)/2,y:(img.size.height-side)/2,width:side,height:side),operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
                return
            }
        }
        let seed = item.title.utf8.reduce(0) { ($0+Int($1))%6 }
        let palettes = [color(0.44,0.51,0.43),color(0.64,0.38,0.28),color(0.32,0.42,0.50),color(0.68,0.57,0.37),color(0.46,0.38,0.48),color(0.36,0.47,0.46)]
        fill(rect,palettes[seed])
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:rect).addClip()
        let s = rect.width
        for i in 0..<8 {
            circleStroke(CGPoint(x:rect.midX+s*0.17,y:rect.midY-s*0.03),s*(0.15+Double(i)*0.06),cream.withAlphaComponent(0.12),s*0.025)
        }
        label("G / RECORDS",rect.minX+s*0.09,rect.minY+s*0.08,size:s*0.055,c:cream,weight:.medium,width:s*0.8)
        label(item.title,rect.minX+s*0.09,rect.minY+s*0.72,size:s*0.085,c:cream,weight:.medium,width:s*0.84)
        label("PERSONAL COLLECTION",rect.minX+s*0.09,rect.minY+s*0.87,size:s*0.038,c:cream.withAlphaComponent(0.7),width:s*0.8)
        NSGraphicsContext.restoreGraphicsState()
    }
    // Blur the artwork itself to preserve its spatial color composition.
    // Render only when the cover changes, never during the platter animation.
    let blurContext = CIContext(options:[.cacheIntermediates:false])
    var blurredCoverKey: String?
    var blurredCover: NSImage?
    func albumBackground(_ item:Album) -> NSImage? {
        let key = item.id + (item.artwork ?? "") + item.title
        if key == blurredCoverKey { return blurredCover }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:384,pixelsHigh:384,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        artwork(item,CGRect(x:0,y:0,width:384,height:384))
        NSGraphicsContext.restoreGraphicsState()
        guard let raster = bitmap.cgImage else { return nil }
        let source = CIImage(cgImage:raster)
        // Clamp before blurring so the edges stay opaque, without dark borders.
        let softened = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:30.0])
            .cropped(to:source.extent)
            .applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:1.12,kCIInputContrastKey:0.92,kCIInputBrightnessKey:0.04])
        guard let result = blurContext.createCGImage(softened,from:source.extent) else { return nil }
        blurredCoverKey = key
        blurredCover = NSImage(cgImage:result,size:NSSize(width:384,height:384))
        return blurredCover
    }
    func drawAlbumBackground() {
        guard let item = onDeck ?? active, let background = albumBackground(item) else {
            gradient(bounds,[color(0.55,0.57,0.80),color(0.85,0.80,0.91)],angle:65)
            return
        }
        // Overscan the cover like a full-bleed photograph behind the record.
        let side = max(bounds.width,bounds.height)*1.12
        background.draw(in:CGRect(x:bounds.midX-side/2,y:bounds.midY-side/2,width:side,height:side),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        fill(bounds,NSColor.white.withAlphaComponent(0.16))
    }
    func button(_ text:String,_ rect:CGRect) {
        fill(rect,color(0.90,0.90,0.86),radius:5)
        label(text,rect.minX,rect.minY+10,size:10,c:ink,weight:.medium,width:rect.width,align:.center)
    }
    override func draw(_ dirtyRect:NSRect) {
        fill(bounds,color(0.97,0.97,0.95))
        if theme == "album" { drawAlbumBackground() }
        if theme != "plain", let background = asset(theme) {
            let ratio = max(bounds.width/background.size.width,bounds.height/background.size.height)
            let size = NSSize(width:background.size.width*ratio,height:background.size.height*ratio)
            background.draw(in:CGRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.translateBy(x:offset.x,y:offset.y); ctx.scaleBy(x:scale,y:scale)
        if !playerOnly {
        if theme != "plain" {
            materialPanel(CGRect(x:1028,y:145,width:336,height:530))
            materialPanel(CGRect(x:44,y:698,width:1352,height:256))
        }
        label("LPDP",62,41,size:23,c:theme == "midnight" ? cream : ink,weight:.medium)
        label("＋ 음악 추가",1210,49,size:12,c:theme == "midnight" ? cream : ink,width:175,align:.right)
        }
        drawTurntable(ctx)
        if !playerOnly {
        drawInfo(ctx)
        label(notice,160,680,size:10,c:theme == "midnight" ? cream : ink,width:830)
        drawShelf(ctx)
        }
        if hovering {
            let over = platterContains(dragPoint)
            circleStroke(platterCenter,213,accent.withAlphaComponent(0.3),3)
            label(over ? "놓으면 바로 재생됩니다" : "놓으면 선반에 추가됩니다",228,430,size:19,c:accent,weight:.semibold,width:430,align:.center)
        }
        if moved, let id = draggedID, let item = library.first(where:{$0.id == id}) {
            ctx.saveGState(); ctx.setShadow(offset:CGSize(width:3,height:10),blur:20,color:NSColor.black.withAlphaComponent(0.25).cgColor)
            drawLooseRecord(item,center:dragPoint,radius:100,context:ctx); ctx.restoreGState()
            if platterContains(dragPoint) { circleStroke(platterCenter,219,accent.withAlphaComponent(0.6),2) }
        }
        if let id = flightID, let item = library.first(where:{$0.id == id}) {
            let t = flightProgress*flightProgress*(3-2*flightProgress)
            let center = CGPoint(x:flightFrom.x+(flightTo.x-flightFrom.x)*t,y:flightFrom.y+(flightTo.y-flightFrom.y)*t)
            let radius = flightMount ? 100+116*t : 216-150*t
            drawLooseRecord(item,center:center,radius:radius,context:ctx)
        }
        ctx.restoreGState()
        let tb = themeButtonRect
        fill(tb,color(0.9,0.91,0.88),radius:tb.height/2)
        label("스타일 ▾",tb.minX,tb.midY-8,size:12,c:ink,width:tb.width,align:.center)
        let toggle = focusButtonRect
        fill(toggle,color(0.9,0.91,0.88),radius:toggle.height/2)
        label(playerOnly ? "전체 보기" : "숨기기",toggle.minX,toggle.midY-8,size:12,c:ink,width:toggle.width,align:.center)
    }
    func drawLooseRecord(_ item:Album,center:CGPoint,radius:CGFloat,context:CGContext) {
        context.saveGState()
        context.setShadow(offset:CGSize(width:0,height:7),blur:12,color:NSColor.black.withAlphaComponent(0.22).cgColor)
        ellipse(CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2),color(0.03,0.035,0.03))
        context.setShadow(offset:.zero,blur:0,color:nil)
        NSBezierPath(ovalIn:CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2)).addClip()
        asset("vinyl")?.draw(in:CGRect(x:center.x-radius*1.025,y:center.y-radius*1.025,width:radius*2.05,height:radius*2.05),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        let lr = radius*0.35
        NSBezierPath(ovalIn:CGRect(x:center.x-lr,y:center.y-lr,width:lr*2,height:lr*2)).addClip()
        artwork(item,CGRect(x:center.x-lr,y:center.y-lr,width:lr*2,height:lr*2))
        ellipse(CGRect(x:center.x-2,y:center.y-2,width:4,height:4),color(0.04,0.045,0.04))
        context.restoreGState()
    }
    func drawRaster(_ image:CGImage, in rect:CGRect, context:CGContext) {
        context.saveGState()
        context.translateBy(x:rect.minX,y:rect.maxY)
        context.scaleBy(x:1,y:-1)
        context.interpolationQuality = .high
        context.draw(image,in:CGRect(origin:.zero,size:rect.size))
        context.restoreGState()
    }
    func recordLabel(_ item:Album) -> CGImage? {
        let key = "label:"+item.id+":"+(item.artwork ?? "")+item.title
        if let image = rasterImages[key] { return image }
        let image = NSImage(size:NSSize(width:304,height:304),flipped:true) { rect in
            self.artwork(item,rect); return true
        }
        var rect = CGRect(x:0,y:0,width:304,height:304)
        let raster = image.cgImage(forProposedRect:&rect,context:nil,hints:nil)
        rasterImages[key] = raster
        return raster
    }
    func drawTurntable(_ ctx:CGContext) {
        let baseRect = CGRect(x:120,y:170,width:800,height:800*1024/1536)
        if !minimalPlayer, let base = asset("base-top") {
            base.draw(in:baseRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        }
        let c = platterCenter
        // One concentric rim masks the slightly eccentric rim in the source photo.
        if !minimalPlayer {
        disc(c,231,[color(0.67,0.69,0.67),color(0.95,0.96,0.94),color(0.50,0.53,0.51),color(0.86,0.88,0.85)])
        circleStroke(c,230,color(0.50,0.53,0.50),0.7)
        circleStroke(c,227,color(1,1,0.98,0.6),0.7)
        disc(c,222,[color(0.08,0.09,0.08),color(0.15,0.16,0.15)])
        } else {
            ctx.saveGState(); ctx.setShadow(offset:CGSize(width:0,height:9),blur:18,color:NSColor.black.withAlphaComponent(0.25).cgColor)
            disc(c,218,[color(0.08,0.09,0.08),color(0.025,0.03,0.025)])
            ctx.restoreGState()
        }
        if let item = onDeck, let vinyl = asset("vinyl") {
            // The entire vinyl photo and its album label rotate in one coordinate system.
            ctx.saveGState(); ctx.translateBy(x:c.x,y:c.y); ctx.rotate(by:angle * .pi/180)
            NSBezierPath(ovalIn:CGRect(x:-216,y:-216,width:432,height:432)).addClip()
            ellipse(CGRect(x:-216,y:-216,width:432,height:432),color(0.025,0.028,0.025))
            if rasterImages["vinyl"] == nil { rasterImages["vinyl"] = vinyl.cgImage(forProposedRect:nil,context:nil,hints:nil) }
            if let raster = rasterImages["vinyl"] { drawRaster(raster,in:CGRect(x:-221,y:-221,width:442,height:442),context:ctx) }
            ctx.saveGState()
            // Cover the whole photographed paper label, including its uneven edge.
            NSBezierPath(ovalIn:CGRect(x:-76,y:-76,width:152,height:152)).addClip()
            if let raster = recordLabel(item) { drawRaster(raster,in:CGRect(x:-76,y:-76,width:152,height:152),context:ctx) }
            circleStroke(.zero,75,color(0.98,0.97,0.91,0.3),0.6)
            circleStroke(.zero,22,color(0.05,0.05,0.04,0.14),0.7)
            ctx.restoreGState(); ctx.restoreGState()
        } else {
            for i in 0..<50 { circleStroke(c,70+CGFloat(i)*3,color(0.4,0.42,0.39,0.09),0.5) }
        }
        if onDeck != nil {
            if reflectionImage == nil { updateReflection() }
            if let reflectionImage {
                let reflection = NSImage(cgImage:reflectionImage,size:NSSize(width:432,height:432))
                reflection.draw(in:CGRect(x:c.x-216,y:c.y-216,width:432,height:432),from:.zero,operation:.screen,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
            }
        }
        disc(c,5,[color(0.92,0.93,0.90),color(0.48,0.51,0.48),.white])
        // Independent photograph of a tonearm, rotated about its actual bearing center.
        if let arm = asset(minimalPlayer ? "tonearm-minimal" : "tonearm") {
            ctx.saveGState(); ctx.translateBy(x:armPivot.x,y:armPivot.y); ctx.rotate(by:armRotation)
            ctx.setShadow(offset:CGSize(width:lifted ? 5 : 2,height:lifted ? 7 : 3),blur:lifted ? 6 : 2,color:NSColor.black.withAlphaComponent(0.22).cgColor)
            arm.draw(in:CGRect(x:minimalPlayer ? -122.88 : -122.4,y:minimalPlayer ? -66 : -69.36,width:245.76,height:368.64),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
            ctx.restoreGState()
        }
        if minimalPlayer {
            let tray = CGRect(x:668,y:608,width:252,height:52)
            ctx.saveGState(); ctx.setShadow(offset:CGSize(width:0,height:3),blur:9,color:NSColor.black.withAlphaComponent(0.12).cgColor)
            fill(tray,color(0.97,0.97,0.95,0.97),radius:16); ctx.restoreGState()
            let titles = ["33⅓","45",!motor || lifted ? "▶" : "■",lifted ? "큐 ↓" : "큐 ↑","⏏"]
            for (index,r) in minimalControls.enumerated() {
                let active = (index == 0 && rpm < 40) || (index == 1 && rpm > 40)
                if active || index == 2 { fill(r,active ? color(0.88,0.90,0.85) : color(0.22,0.26,0.22),radius:10) }
                label(titles[index],r.minX,r.midY-8,size:index == 2 ? 14 : 11,c:index == 2 ? .white : ink,weight:.medium,width:r.width,align:.center)
            }
            return
        }
        // Small labels follow the photographed physical controls; hit targets are larger than the buttons.
        label("33",187,650,size:9,c:rpm < 40 ? ink : muted,weight:.medium,width:28,align:.center)
        label("45",222,650,size:9,c:rpm > 40 ? ink : muted,weight:.medium,width:28,align:.center)
        ellipse(CGRect(x:rpm < 40 ? 199 : 234,y:665,width:3,height:3),accent)
        label(!motor || lifted ? "START" : "STOP",774,652,size:8,c:ink,weight:.medium,width:46,align:.center)
        label("EJECT",823,652,size:8,c:ink,weight:.medium,width:40,align:.center)

        // An inset mechanical cue switch belongs to the chassis rather than floating above it.
        label("CUE",772,580,size:7,c:color(0.43,0.45,0.42),weight:.medium,width:30)
        gradient(CGRect(x:808,y:577,width:37,height:15),[color(0.58,0.60,0.56),color(0.91,0.92,0.88)],radius:7)
        fill(CGRect(x:811,y:582,width:31,height:5),color(0.18,0.20,0.18),radius:2)
        let knobX:CGFloat = lifted ? 814 : 830
        ctx.saveGState(); ctx.setShadow(offset:CGSize(width:0,height:1),blur:2,color:NSColor.black.withAlphaComponent(0.3).cgColor)
        gradient(CGRect(x:knobX,y:578,width:9,height:13),[color(0.96,0.97,0.93),color(0.54,0.57,0.52)],radius:3)
        ctx.restoreGState()
        line(CGPoint(x:knobX+4,y:580),CGPoint(x:knobX+4,y:589),color(1,1,0.98,0.7),0.7)
        label("UP",809,594,size:5,c:muted,width:16)
        label("DN",831,594,size:5,c:muted,width:16)
        ellipse(CGRect(x:875,y:627,width:4,height:4),motor ? color(0.45,0.65,0.34) : color(0.65,0.65,0.60))
        if mounted == nil {
            label("선반의 레코드를 이곳에 올려주세요",c.x-150,c.y+94,size:10,c:color(0.71,0.72,0.67),width:300,align:.center)
        }
    }
    var darkPanel: Bool { theme == "walnut" || theme == "midnight" }
    var panelInk:NSColor { darkPanel ? color(0.97,0.94,0.86) : color(0.23,0.25,0.23) }
    var panelMuted:NSColor { darkPanel ? color(0.80,0.78,0.71) : color(0.43,0.44,0.40) }
    var panelAccent:NSColor { darkPanel ? color(0.78,0.66,0.43) : color(0.37,0.43,0.33) }
    func materialPanel(_ rect:CGRect, radius:CGFloat = 16) {
        if theme == "album" {
            fill(rect,NSColor.white.withAlphaComponent(0.30),radius:radius)
            let edge = NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),xRadius:radius,yRadius:radius)
            NSColor.white.withAlphaComponent(0.38).setStroke(); edge.lineWidth = 1; edge.stroke()
            return
        }
        guard let material = asset("panel-"+theme) else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowOffset = NSSize(width:0,height:-5); shadow.shadowBlurRadius = 14; shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.set()
        fill(rect,darkPanel ? color(0.13,0.14,0.14) : cream,radius:radius)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).addClip()
        // Preserve the texture's proportions by cropping, not stretching.
        let ratio = max(rect.width/material.size.width,rect.height/material.size.height)
        let w = material.size.width*ratio, h = material.size.height*ratio
        material.draw(in:CGRect(x:rect.midX-w/2,y:rect.midY-h/2,width:w,height:h),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        fill(rect,(darkPanel ? NSColor.black : NSColor.white).withAlphaComponent(0.18))
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(roundedRect:rect.insetBy(dx:0.7,dy:0.7),xRadius:radius,yRadius:radius)
        panelAccent.withAlphaComponent(0.4).setStroke(); edge.lineWidth = 1; edge.stroke()
    }
    func drawInfo(_ ctx:CGContext) {
        let ink = panelInk, muted = panelMuted, accent = panelAccent
        button("◀|",CGRect(x:1050,y:104,width:42,height:32))
        button("|▶",CGRect(x:1098,y:104,width:42,height:32))
        button(playbackModes[playbackMode]+" ▾",CGRect(x:1150,y:104,width:190,height:32))
        if let item = active {
            ctx.saveGState(); ctx.setShadow(offset:CGSize(width:0,height:8),blur:16,color:NSColor.black.withAlphaComponent(0.14).cgColor)
            artwork(item,CGRect(x:1082,y:167,width:226,height:226)); ctx.restoreGState()
            label("커버 변경",1050,414,size:9,c:accent,width:290,align:.center)
            label(item.title,1050,452,size:19,c:ink,weight:.medium,width:290)
            label(item.artist,1050,484,size:13,c:muted,width:290)
            if showDetails { label(item.album+"  ·  "+item.year,1050,509,size:10,c:muted,width:290) }
            let p = item.id == mounted ? (player?.currentTime ?? 0) : 0
            fill(CGRect(x:1050,y:555,width:290,height:3),color(0.81,0.82,0.76),radius:2)
            fill(CGRect(x:1050,y:555,width:290*p/max(0.01,item.duration),height:3),accent,radius:2)
            label(time(p)+" / "+time(item.duration),1050,532,size:10,c:muted,width:140)
            if showDetails { label("\(URL(fileURLWithPath:item.path).pathExtension.uppercased()) · \(String(format:"%.1f",item.sampleRate/1000)) kHz · \(item.channels) CH",1190,532,size:9,c:muted,width:150,align:.right) }
        } else {
            fill(CGRect(x:1082,y:167,width:226,height:226),color(0.88,0.88,0.82),radius:2)
            circleStroke(CGPoint(x:1195,y:270),65,color(0.73,0.76,0.68),1)
            label("YOUR",1107,233,size:24,c:accent,weight:.light,width:176,align:.center)
            label("COLLECTION",1107,267,size:21,c:accent,weight:.light,width:176,align:.center)
            label("오늘은 어떤 음악인가요?",1050,453,size:21,c:ink,weight:.light,width:300)
            label("음악을 추가하면 커버와 곡 정보가 표시됩니다.",1050,490,size:11,c:muted,width:310)
        }
        label(showDetails ? "세부정보 −" : "세부정보 +",1050,578,size:10,c:muted,width:130)
        if showDetails {
            label(String(format:"%+.1f%%",pitch),1240,578,size:9,c:muted,width:100,align:.right)
            line(CGPoint(x:1050,y:604),CGPoint(x:1340,y:604),color(0.78,0.80,0.73),1)
            ellipse(CGRect(x:1195+pitch/8*145-4,y:600,width:8,height:8),accent)
        }
        label("음량",1050,622,size:9,c:muted,width:290)
        line(CGPoint(x:1050,y:648),CGPoint(x:1340,y:648),color(0.78,0.80,0.73),2)
        line(CGPoint(x:1050,y:648),CGPoint(x:1050+290*volume,y:648),accent,2)
        ellipse(CGRect(x:1050+290*volume-5,y:643,width:10,height:10),accent)
    }
    func drawShelf(_ ctx:CGContext) {
        let ink = panelInk, muted = panelMuted, accent = panelAccent
        label("컬렉션",66,714,size:12,c:ink,weight:.medium)
        label("\(library.count)",129,715,size:10,c:muted,width:60)
        label("←",1230,714,size:14,c:muted,width:50,align:.center)
        label("→",1300,714,size:14,c:muted,width:50,align:.center)
        if theme == "plain" {
            line(CGPoint(x:65,y:914),CGPoint(x:1378,y:914),color(0.78,0.78,0.74),2)
        } else {
            materialPanel(CGRect(x:56,y:907,width:1332,height:15),radius:3)
            line(CGPoint(x:60,y:909),CGPoint(x:1384,y:909),panelAccent.withAlphaComponent(0.65),1)
        }
        for slot in 0..<8 {
            let i = shelfPage*8+slot, rect = cardRect(slot)
            if i < library.count {
                let item = library[i]
                ctx.saveGState(); ctx.setShadow(offset:CGSize(width:3,height:4),blur:7,color:NSColor.black.withAlphaComponent(0.12).cgColor)
                if item.id == sleeveOpen && item.id != mounted && !(draggedID == item.id && moved) && flightID != item.id {
                    drawLooseRecord(item,center:CGPoint(x:rect.midX,y:rect.midY-66*sleeveReveal),radius:66,context:ctx)
                }
                artwork(item,rect); ctx.restoreGState()
                // A fine lip makes the cover read as a sleeve with an opening.
                line(CGPoint(x:rect.minX+2,y:rect.minY+1),CGPoint(x:rect.maxX-2,y:rect.minY+1),color(0,0,0,0.24),1)
                if item.id == mounted {
                    ellipse(CGRect(x:rect.minX+10,y:rect.minY+10,width:7,height:7),cream)
                }
                if item.id == selected { line(CGPoint(x:rect.minX,y:rect.maxY+3),CGPoint(x:rect.maxX,y:rect.maxY+3),accent,3) }
                label(item.title,rect.minX,936,size:10,c:ink,width:140,align:.center)
            } else if library.isEmpty && slot < 3 {
                fill(rect,color(0.89,0.88,0.82),radius:2)
                label(slot == 0 ? "+" : "",rect.minX,rect.minY+36,size:40,c:muted,weight:.ultraLight,width:140,align:.center)
                label(slot == 0 ? "첫 레코드 추가" : "",rect.minX,rect.minY+96,size:11,c:muted,width:140,align:.center)
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var deck: DeckView!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:960),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "LPDP — The Listening Room"
        window.minSize = NSSize(width:1080,height:750)
        window.backgroundColor = color(0.055,0.062,0.065)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named:.aqua)
        deck = DeckView(frame:window.contentView!.bounds); deck.autoresizingMask = [.width,.height]
        window.contentView = deck
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"LPDP 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let fileItem = NSMenuItem(); fileItem.title = "파일"; menu.addItem(fileItem)
        let fileMenu = NSMenu(title:"파일"); fileItem.submenu = fileMenu
        let open = NSMenuItem(title:"음악 파일 열기…",action:#selector(DeckView.openFile),keyEquivalent:"o"); open.target = deck; fileMenu.addItem(open)
        let editItem = NSMenuItem(); editItem.title = "편집"; menu.addItem(editItem)
        let editMenu = NSMenu(title:"편집"); editItem.submenu = editMenu
        let restore = NSMenuItem(title:"제거한 음반 복원",action:#selector(DeckView.restoreRemovedAlbum),keyEquivalent:"z"); restore.target = deck; editMenu.addItem(restore)
        let playbackItem = NSMenuItem(); playbackItem.title = "재생"; menu.addItem(playbackItem)
        let playbackMenu = NSMenu(title:"재생"); playbackItem.submenu = playbackMenu
        for (title,action,key) in [("재생 / 모터 정지",#selector(DeckView.togglePlayback),""),("이전 곡",#selector(DeckView.previousTrack),"["),("다음 곡",#selector(DeckView.nextTrack),"]"),("톤암 올리기 / 내리기",#selector(DeckView.toggleCue),"u"),("레코드 꺼내기",#selector(DeckView.ejectRecord),"e"),("플레이어만 보기",#selector(DeckView.toggleFocus),"f")] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:key); item.target = deck; playbackMenu.addItem(item)
        }
        let windowItem = NSMenuItem(); windowItem.title = "윈도우"; menu.addItem(windowItem)
        let windowMenu = NSMenu(title:"윈도우"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle:"최소화",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        let helpItem = NSMenuItem(); helpItem.title = "도움말"; menu.addItem(helpItem)
        let helpMenu = NSMenu(title:"도움말"); helpItem.submenu = helpMenu
        let help = NSMenuItem(title:"LPDP 사용 안내",action:#selector(DeckView.showHelp),keyEquivalent:"?"); help.target = deck; helpMenu.addItem(help)
        NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(deck)
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func application(_ sender:NSApplication, openFiles filenames:[String]) { for file in filenames { deck.add(URL(fileURLWithPath:file)) }; sender.reply(toOpenOrPrint:.success) }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
if CommandLine.arguments.contains("--self-test") {
    let view = DeckView(frame:CGRect(x:0,y:0,width:1440,height:960)); view.timer?.invalidate()
    let url = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("groove-test-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!
    let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:88200)!; buffer.frameLength = 88200
    do { let file = try AVAudioFile(forWriting:url,settings:format.settings); try file.write(from:buffer) }
    precondition(view.asset("tonearm-minimal") != nil && view.asset("base-top") != nil && view.asset("vinyl") != nil && view.asset("tonearm") != nil)
    precondition(view.platterContains(view.platterCenter))
    precondition(!view.platterContains(CGPoint(x:view.platterCenter.x,y:view.platterCenter.y+230)))
    for startingRPM in [33.333,45.0] {
        view.motor = false; view.velocity = startingRPM
        view.updateMotor(0.05); precondition(view.velocity > 0 && view.velocity < startingRPM)
        for _ in 0..<300 { view.updateMotor(1.0/60) }
        precondition(view.velocity == 0)
    }
    view.angle = 359; view.velocity = 33.333
    var previousAngle = view.angle
    for frame in 0..<1800 {
        view.advanceRotation(1.0/60)
        precondition(view.angle > previousAngle && view.angle-previousAngle < 5)
        if frame % 180 == 0 {
            let preserved = view.angle
            view.togglePlayerOnly(); precondition(view.angle == preserved)
            view.togglePlayerOnly(); precondition(view.angle == preserved)
        }
        previousAngle = view.angle
    }
    precondition(view.angle > 6000,"Rotation must accumulate across many turns")
    view.angle = 0; view.velocity = 0
    for (i,r) in view.minimalControls.enumerated() {
        precondition(!view.platterContains(CGPoint(x:r.midX,y:r.midY)))
        for other in view.minimalControls.dropFirst(i+1) { precondition(!r.intersects(other)) }
    }
    let id = view.add(url)!; precondition(view.library.count == 1)
    precondition(view.add(url) == id && view.library.count == 1)
    view.sleeveOpen = id
    view.flyRecord(id,from:view.sleeveCenter(id),mount:true)
    precondition(view.flightID == id && view.mounted == nil)
    for _ in 0..<6 { view.previousTick -= 0.1; view.tick() }
    precondition(view.flightID == nil && view.mounted == id && view.motor && !view.lifted)
    view.player?.volume = 0
    for progress in [0.0,0.5,1.0] {
        view.renderedArmAngle = view.grooveAngle(progress)
        precondition(view.tonearmContains(view.stylus))
        let shaft = CGPoint(x:view.armPivot.x-sin(view.armRotation)*140,y:view.armPivot.y+cos(view.armRotation)*140)
        precondition(view.tonearmContains(shaft))
        precondition(!view.tonearmContains(view.platterCenter))
        let rim = CGPoint(x:view.platterCenter.x-190,y:view.platterCenter.y)
        precondition(view.platterContains(rim) && !view.tonearmContains(rim))
    }
    view.renderedArmAngle = view.restAngle
    let rest = view.stylus
    let angleBefore = view.angle
    for _ in 0..<30 { view.previousTick -= 0.1; view.tick() }
    precondition(view.angle != angleBefore)
    precondition(view.armProgress > 0.97 && view.stylus.x < rest.x && view.player!.isPlaying)
    view.seekArm(CGPoint(x:620,y:460)); precondition(view.needle > 0)
    let coastStartAngle = view.angle
    view.playPause(); precondition(!view.motor && !view.lifted && view.player!.isPlaying)
    var previousSpeed = view.velocity
    for _ in 0..<240 {
        view.previousTick -= 1.0/60; view.tick()
        precondition(view.velocity <= previousSpeed+0.00001)
        previousSpeed = view.velocity
    }
    precondition(view.velocity == 0 && !view.player!.isPlaying && view.angle > coastStartAngle)
    let stoppedAngle = view.angle
    for _ in 0..<5 { view.previousTick -= 0.1; view.tick() }
    precondition(view.angle == stoppedAngle)
    view.lifted = true
    // Seek actual audio timestamps while paused; ensure the animation tracks the corresponding groove.
    for progress in [0.0,0.25,0.5,0.75,0.97] {
        view.player!.currentTime = progress*view.player!.duration
        for _ in 0..<35 { view.previousTick -= 0.1; view.tick() }
        precondition(abs(view.needle-progress)<0.0001)
        let radius = hypot(view.stylus.x-view.platterCenter.x,view.stylus.y-view.platterCenter.y)
        let expected = view.outerGrooveRadius-(view.outerGrooveRadius-view.innerGrooveRadius)*progress
        precondition(abs(radius-expected)<0.05,"Needle must lie on elapsed-time groove")
        precondition(view.armProgress > 0.99,"Cue up must not send the arm home")
    }
    view.player!.currentTime = 0.25*view.player!.duration
    view.playPause()
    for _ in 0..<30 { view.previousTick -= 0.1; view.tick() }
    precondition(view.player!.isPlaying)
    let beforeMode = view.player
    let normalScale = view.scale
    view.togglePlayerOnly()
    precondition(view.playerOnly && view.scale > normalScale && view.player === beforeMode && view.player!.isPlaying)
    let screenPoint = CGPoint(x:view.offset.x+view.platterCenter.x*view.scale,y:view.offset.y+view.platterCenter.y*view.scale)
    let logicalPoint = view.logical(screenPoint)
    precondition(hypot(logicalPoint.x-view.platterCenter.x,logicalPoint.y-view.platterCenter.y)<0.001)
    view.togglePlayerOnly(); precondition(!view.playerOnly && view.player!.isPlaying)
    let before = view.needle
    Thread.sleep(forTimeInterval:0.1); view.tick()
    precondition(view.needle > before,"Live audio playback must advance needle")
    view.playPause()
    view.eject(); precondition(view.mounted == nil && view.player == nil && view.library.count == 1)
    for _ in 0..<35 { view.previousTick -= 0.1; view.tick() }
    precondition(abs(view.armRotation-view.restAngle)<0.001)
    view.setPitch(CGPoint(x:1340,y:604)); precondition(view.pitch == 8)
    view.setVolume(CGPoint(x:1050,y:648)); precondition(view.volume == 0)
    view.flightID = nil; view.sleeveOpen = nil
    // Exercise end-of-track policies, scrub state, and non-destructive library management.
    let secondURL = url.deletingLastPathComponent().appendingPathComponent("lpdp-second-"+UUID().uuidString+".wav")
    try! FileManager.default.copyItem(at:url,to:secondURL)
    let secondID = view.add(secondURL)!
    view.mount(id); view.playbackMode = 0; view.finishTrack()
    precondition(view.mounted == id && !view.motor && view.lifted && view.needle == 1)
    view.playbackMode = 1; view.finishTrack(); precondition(view.mounted == secondID && view.motor && view.needle == 0)
    view.finishTrack(); precondition(view.mounted == id,"Continuous playback wraps the shelf")
    view.playbackMode = 2; view.finishTrack(); precondition(view.mounted == id && view.motor && view.needle == 0)
    view.playbackMode = 3; view.finishTrack(); precondition(view.mounted == secondID,"Shuffle excludes the current record")
    view.previousTrack(); precondition(view.mounted == id)
    view.nextTrack(); precondition(view.mounted == secondID)
    view.dragging = "seek"; view.player!.pause(); view.seekBar(CGPoint(x:1195,y:555))
    precondition(abs(view.needle-0.5)<0.01)
    for _ in 0..<50 { view.previousTick -= 0.1; view.tick() }
    precondition(!view.player!.isPlaying,"Scrubbing holds audio until release")
    view.dragging = nil; view.previousTick -= 0.1; view.tick(); precondition(view.player!.isPlaying)
    view.toggleCue(); view.seek(to:-100); precondition(view.needle == 0 && view.lifted && !view.player!.isPlaying)
    view.seek(to:1000); precondition(view.player!.currentTime < view.player!.duration)
    let retainedTitle = view.library.first(where:{$0.id == id})!.title
    precondition(!view.relinkAlbum(id,to:secondURL),"Reject duplicate replacement files")
    let missingURL = secondURL.deletingLastPathComponent().appendingPathComponent("missing-"+UUID().uuidString+".wav")
    precondition(!view.relinkAlbum(id,to:missingURL))
    view.removeAlbum(secondID)
    precondition(view.mounted == nil && view.flightID == nil && view.library.count == 1)
    precondition(FileManager.default.fileExists(atPath:secondURL.path),"Removing a sleeve never deletes audio")
    view.restoreRemovedAlbum(); precondition(view.library.count == 2 && view.selected == secondID)
    view.removeAlbum(secondID)
    precondition(view.relinkAlbum(id,to:secondURL))
    precondition(view.library.first(where:{$0.id == id})!.title == retainedTitle)
    view.removeAlbum(id); precondition(view.library.isEmpty && view.selected == nil && view.shelfPage == 0)
    precondition(view.nextTrackID(direction:1) == nil)
    view.restoreRemovedAlbum(); precondition(view.library.count == 1)
    view.playbackMode = 3; view.mount(id); view.finishTrack(); precondition(view.mounted == id)
    view.eject(); view.flightID = nil; view.sleeveOpen = nil; view.playbackMode = 0
    try! FileManager.default.removeItem(at:secondURL)
    print("PASS: playback policies, next/previous, scrub pause/resume, cue-safe seek, relink validation, remove/restore, original file preservation, empty/single-item collection")
    // Render a clearly marked sample collection; no demo tracks are persisted.
    view.library = []
    for (title,artist,album) in [("Evening Light","DEMO / 미리보기","Quiet hours"),("Blue Room","DEMO / 미리보기","Studio sessions"),("Sunday, Slowly","DEMO / 미리보기","At home"),("A Little Jazz","DEMO / 미리보기","Listening notes"),("봄의 기록","DEMO / 미리보기","Personal collection")] {
        var a = Album(path:url.path,title:title); a.artist = artist; a.album = album; a.duration = 238; a.sampleRate = 44100; a.channels = 2; a.year = "2026"; view.library.append(a)
    }
    view.selected = view.library[0].id; view.mounted = view.selected; view.armProgress = 1; view.lifted = false; view.pitch = 0; view.volume = 0.7; view.motor = true; view.angle = 0
    view.needle = 0; view.renderedArmAngle = view.grooveAngle(0)
    view.notice = "미리보기용 예시 선반 · 실제 앱에는 직접 추가한 음악만 표시됩니다."
    view.lightPosition = CGPoint(x:-0.65,y:-0.65); view.updateReflection()
    let firstLight = view.reflectionImage!.dataProvider!.data! as Data
    view.lightPosition = CGPoint(x:0.8,y:-0.3); view.updateReflection()
    let secondLight = view.reflectionImage!.dataProvider!.data! as Data
    precondition(firstLight != secondLight,"Moving the light must update the reflection")
    let centerOffset = (128*256+128)*4+3
    precondition(secondLight[centerOffset] == 0,"Paper label must not receive vinyl reflection")
    view.lightPosition = CGPoint(x:-0.65,y:-0.65); view.updateReflection()
    let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds)!; view.cacheDisplay(in:view.bounds,to:rep)
    try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments.last!))
    view.togglePlayerOnly()
    let focusRep = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.cacheDisplay(in:view.bounds,to:focusRep)
    let focusURL = URL(fileURLWithPath:CommandLine.arguments.last!).deletingLastPathComponent().appendingPathComponent("PlayerOnly.png")
    try! focusRep.representation(using:.png,properties:[:])!.write(to:focusURL)
    view.togglePlayerOnly()
    for (key,_) in view.themeNames where key != "plain" {
        if key != "album" { precondition(view.asset(key) != nil && view.asset("panel-"+key) != nil) }
        view.theme = key
        let themed = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:themed)
        let themeURL = URL(fileURLWithPath:CommandLine.arguments.last!).deletingLastPathComponent().appendingPathComponent("Theme-"+key+".png")
        try! themed.representation(using:.png,properties:[:])!.write(to:themeURL)
    }
    view.theme = "plain"
    view.minimalPlayer = false
    let classic = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.cacheDisplay(in:view.bounds,to:classic)
    try! classic.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments.last!).deletingLastPathComponent().appendingPathComponent("Classic.png"))
    view.minimalPlayer = true
    // Verify texture rotation outside the album label, and export an actual UI-rendered animation.
    let crop = CGRect(x:120,y:170,width:800,height:533)
    var firstPixels:[Double] = []
    let gifURL = URL(fileURLWithPath:CommandLine.arguments.last!).deletingLastPathComponent().appendingPathComponent("Rotation.gif")
    let gif = CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,24,nil)!
    CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
    var textureDifference = 0.0
    for frame in 0..<24 {
        view.angle = Double(frame)*15
        view.lightPosition = CGPoint(x:-0.65,y:-0.65)
        view.updateReflection()
        let bitmap = view.bitmapImageRepForCachingDisplay(in:crop)!
        view.cacheDisplay(in:crop,to:bitmap)
        if frame == 0 || frame == 5 {
            let sx = Double(bitmap.pixelsWide)/crop.width, sy = Double(bitmap.pixelsHigh)/crop.height
            for (index,p) in [CGPoint(x:130,y:-100),CGPoint(x:-145,y:70),CGPoint(x:80,y:155)].enumerated() {
                let pixel = bitmap.colorAt(x:Int((view.platterCenter.x+p.x-crop.minX)*sx),y:Int((view.platterCenter.y+p.y-crop.minY)*sy))!.usingColorSpace(.deviceRGB)!
                let intensity = Double(pixel.redComponent+pixel.greenComponent+pixel.blueComponent)/3
                if frame == 0 { firstPixels.append(intensity) } else { textureDifference += abs(intensity-firstPixels[index]) }
            }
        }
        CGImageDestinationAddImage(gif,bitmap.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.075]] as CFDictionary)
    }
    precondition(textureDifference > 0.005,"Vinyl texture, not only the label, must visibly rotate")
    precondition(CGImageDestinationFinalize(gif))
    print("PASS: rotating vinyl texture pixels changed by \(textureDifference)")
    try? FileManager.default.removeItem(at:url)
    print("PASS: 30-second continuous multi-turn rotation and mode switches; import, deduplication, mount, auto playback, top-view circular hit testing, generated assets, elapsed-time radial geometry (0/25/50/75/97%), live playback tracking, pause holds position, eject returns home, seek, cue, eject preserving shelf, pitch, volume, render")
} else { application.run() }
