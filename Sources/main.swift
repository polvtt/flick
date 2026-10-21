// Flick — gestionnaire de fenêtres par gestes trackpad pour macOS.
// Implémentation originale. Principe : un CGEventTap écoute les swipes à deux
// doigts (événements scroll continus) ; quand le curseur est sur la barre de
// titre d'une fenêtre (ou sur la fenêtre avec Ctrl), on accumule la direction
// et on redimensionne la fenêtre via l'API Accessibilité.
//
// Usage perso. Aucune dépendance tierce, aucune donnée ne sort de la machine.

import AppKit
import ApplicationServices

// MARK: - Log de diagnostic (activé si FLICK_DEBUG=1)

let DEBUG = ProcessInfo.processInfo.environment["FLICK_DEBUG"] == "1"
func dbg(_ s: @autoclosure () -> String) {
    guard DEBUG else { return }
    let line = "[flick] \(s())\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

// MARK: - Réglages

enum Config {
    /// Hauteur de la bande « barre de titre » (points) où un swipe est capté.
    static let titleBarBand: CGFloat = 34
    /// Déplacement minimal (points) pour afficher l'aperçu / valider un geste.
    static let minTravel: CGFloat = 20
    /// Au-delà de ce ratio (axe mineur / axe majeur) on considère un coin (diagonale).
    static let diagonalRatio: CGFloat = 0.45
    /// Inverser si une direction part à l'envers chez vous (scroll naturel).
    static let invertX = false
    static let invertY = false
    /// true = le geste se déclenche partout sur la fenêtre (intercepte le scroll
    /// du contenu). false = seulement sur la barre de titre, ou partout avec Ctrl.
    static let captureAnywhere = false
    /// Après un geste, replacer le pointeur sur la barre de titre de la fenêtre.
    static let moveCursorAfterAction = true
    /// Marge autour des fenêtres snappées (points). 0 = collé aux bords.
    static let gap: CGFloat = 0
}

// MARK: - Helpers Accessibilité

@inline(__always)
func axCopy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

func windowUnderCursor(_ pt: CGPoint) -> AXUIElement? {
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(pt.x), Float(pt.y), &el)
    guard err == .success, let e = el else {
        dbg("copyElementAtPosition a échoué err=\(err.rawValue)")
        return nil
    }
    // 1) attribut "fenêtre conteneur" direct
    if let w = axCopy(e, kAXWindowAttribute as String) {
        return (w as! AXUIElement)
    }
    // 2) remonter la hiérarchie jusqu'à un élément de rôle AXWindow
    var cur: AXUIElement? = e
    var hops = 0
    while let c = cur, hops < 12 {
        if let role = axCopy(c, kAXRoleAttribute as String) as? String,
           role == (kAXWindowRole as String) {
            return c
        }
        cur = axCopy(c, kAXParentAttribute as String).map { $0 as! AXUIElement }
        hops += 1
    }
    dbg("aucune fenêtre trouvée en remontant la hiérarchie (\(hops) niveaux)")
    return nil
}

func frame(of w: AXUIElement) -> CGRect? {
    guard let posV = axCopy(w, kAXPositionAttribute as String),
          let sizeV = axCopy(w, kAXSizeAttribute as String) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(posV as! AXValue, .cgPoint, &pt)
    AXValueGetValue(sizeV as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func setFrame(_ w: AXUIElement, _ r: CGRect) {
    var pt = r.origin, sz = r.size
    // position d'abord, taille ensuite, puis position à nouveau : certaines
    // apps clampent la taille sur l'écran courant avant d'accepter la position.
    if let pv = AXValueCreate(.cgPoint, &pt) {
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
    }
    if let sv = AXValueCreate(.cgSize, &sz) {
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
    }
    if let pv = AXValueCreate(.cgPoint, &pt) {
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
    }
}

// MARK: - Géométrie écran (coordonnées AX, origine en haut à gauche)

func axVisibleFrame(forGlobalPoint pt: CGPoint) -> CGRect {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let cocoaPt = CGPoint(x: pt.x, y: primaryH - pt.y)
    let screen = NSScreen.screens.first { NSMouseInRect(cocoaPt, $0.frame, false) }
        ?? NSScreen.main ?? NSScreen.screens.first!
    let vf = screen.visibleFrame               // coords Cocoa (origine bas-gauche)
    let axY = primaryH - (vf.origin.y + vf.height)
    return CGRect(x: vf.origin.x, y: axY, width: vf.width, height: vf.height).insetBy(dx: 0, dy: 0)
}

/// Zones visibles (coords AX) de tous les écrans connectés.
func axVisibleFrames() -> [CGRect] {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    return NSScreen.screens.map { s in
        let vf = s.visibleFrame
        return CGRect(x: vf.minX, y: primaryH - (vf.minY + vf.height),
                      width: vf.width, height: vf.height)
    }
}

/// Zone visible (AX) de l'écran adjacent dans une direction cardinale, ou nil s'il
/// n'y a pas d'écran de ce côté. dir en coords AX (y vers le bas) :
/// (-1,0) gauche, (1,0) droite, (0,-1) haut, (0,1) bas.
func adjacentScreenFrame(from rect: CGRect, dir: (CGFloat, CGFloat)) -> CGRect? {
    let frames = axVisibleFrames()
    guard frames.count > 1 else { return nil }
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let cur = frames.first { $0.contains(c) }
        ?? frames.min { hypot($0.midX - c.x, $0.midY - c.y) < hypot($1.midX - c.x, $1.midY - c.y) }!
    let cc = CGPoint(x: cur.midX, y: cur.midY)
    var best: CGRect?; var bestScore = CGFloat.greatestFiniteMagnitude
    for f in frames where f != cur {
        let vx = f.midX - cc.x, vy = f.midY - cc.y
        let along = vx * dir.0 + vy * dir.1          // avancée dans la direction
        guard along > 1 else { continue }            // écran bien de ce côté
        let perp = abs(vx * dir.1 - vy * dir.0)      // décalage latéral
        let score = perp * 3 + along                 // aligné d'abord, puis proche
        if score < bestScore { bestScore = score; best = f }
    }
    return best
}

/// Replace proportionnellement un cadre de fenêtre d'un écran vers un autre
/// (garde la position et la taille relatives), en restant dans les bornes.
func mappedRect(_ win: CGRect, from src: CGRect, to dst: CGRect) -> CGRect {
    let relX = (win.minX - src.minX) / src.width
    let relY = (win.minY - src.minY) / src.height
    let w = min(win.width / src.width, 1) * dst.width
    let h = min(win.height / src.height, 1) * dst.height
    var x = dst.minX + relX * dst.width
    var y = dst.minY + relY * dst.height
    x = min(max(x, dst.minX), dst.maxX - w)
    y = min(max(y, dst.minY), dst.maxY - h)
    return CGRect(x: x, y: y, width: w, height: h)
}

// MARK: - Actions de fenêtre

enum Snap {
    case left, right, maximize, center
    case topLeft, topRight, bottomLeft, bottomRight

    func rect(in vf: CGRect) -> CGRect {
        let g = Config.gap
        let hw = vf.width / 2, hh = vf.height / 2
        let r: CGRect
        switch self {
        case .left:        r = CGRect(x: vf.minX, y: vf.minY, width: hw, height: vf.height)
        case .right:       r = CGRect(x: vf.minX + hw, y: vf.minY, width: hw, height: vf.height)
        case .maximize:    r = vf
        case .center:      r = CGRect(x: vf.minX + vf.width*0.15, y: vf.minY + vf.height*0.1,
                                      width: vf.width*0.7, height: vf.height*0.8)
        case .topLeft:     r = CGRect(x: vf.minX, y: vf.minY, width: hw, height: hh)
        case .topRight:    r = CGRect(x: vf.minX + hw, y: vf.minY, width: hw, height: hh)
        case .bottomLeft:  r = CGRect(x: vf.minX, y: vf.minY + hh, width: hw, height: hh)
        case .bottomRight: r = CGRect(x: vf.minX + hw, y: vf.minY + hh, width: hw, height: hh)
        }
        return r.insetBy(dx: g, dy: g)
    }
}

// MARK: - Overlay de prévisualisation (rectangle translucide animé)

/// La fenêtre overlay EST le rectangle : on la déplace/redimensionne directement
/// sur la zone cible. Animée via NSAnimationContext (piloté par un timer d'anim,
/// donc le rendu est poussé à l'écran même quand la maj vient d'un event-tap).
final class PreviewOverlay {
    private let window: NSWindow
    private var visible = false

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .ignoresCycle, .fullScreenAuxiliary]
        // Le contentView dessine via SON PROPRE layer de backing (toujours rendu,
        // contrairement à une sous-couche ajoutée à une vue layer-backed).
        let v = NSView()
        v.wantsLayer = true
        if let l = v.layer {
            l.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
            l.borderColor = NSColor.systemBlue.cgColor
            l.borderWidth = 3
            l.cornerRadius = 10
        }
        window.contentView = v
    }

    private func cocoaRect(fromAX axRect: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: axRect.minX, y: primaryH - axRect.maxY,
                      width: axRect.width, height: axRect.height)
    }

    /// Conservé pour compat (le positionnement se fait dans update).
    func position(onScreenContaining axPoint: CGPoint) {}

    /// Montre/déplace la fenêtre-rectangle vers une cible en coords AX (haut-gauche).
    func update(toAXRect axRect: CGRect) {
        let r = cocoaRect(fromAX: axRect)
        dbg("overlay.update -> cocoa=\(r) visibleAvant=\(visible)")
        if !visible {
            visible = true
            window.setFrame(r, display: true)
            window.orderFrontRegardless()
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                window.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(r, display: true)
            }
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.window.orderOut(nil) })
    }
}

// MARK: - Moteur de gestes

final class GestureEngine {
    private var tap: CFMachPort?
    private var capturing = false
    private var target: AXUIElement?
    private var accumX: CGFloat = 0
    private var accumY: CGFloat = 0
    private var vf: CGRect = .zero          // zone visible de l'écran cible (coords AX)
    private var cmdMode = false             // Cmd maintenu → déplacer vers un autre écran
    private var optMode = false             // Option maintenu → minimiser (bas) / quitter (Cmd+bas)
    private var candidateRect: CGRect?      // cible actuellement prévisualisée (coords AX)
    private var candidateKey: String?       // clé de zone/écran, pour n'animer qu'au changement
    private var overlay: PreviewOverlay?

    func start() {
        overlay = PreviewOverlay()
        let mask = (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let engine = Unmanaged<GestureEngine>.fromOpaque(refcon!).takeUnretainedValue()
                return engine.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            fputs("Flick: impossible de créer l'event tap (permission Accessibilité ?)\n", stderr)
            dbg("tapCreate a ÉCHOUÉ — AXIsProcessTrusted=\(AXIsProcessTrusted())")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        dbg("event tap créé et actif — AXIsProcessTrusted=\(AXIsProcessTrusted())")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Réarmer si le système a désactivé le tap.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        // Seulement le trackpad (scroll continu/précis), pas la molette souris.
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        if continuous == 0 { return Unmanaged.passUnretained(event) }

        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let loc = event.location
        dbg("scroll cont=\(continuous) phase=\(phase) mom=\(momentum) dx=\(String(format: "%.1f", dx)) dy=\(String(format: "%.1f", dy)) cap=\(capturing)")

        switch phase {
        case 1: // began
            beginIfEligible(at: loc, modifiers: event.flags)
            return capturing ? nil : Unmanaged.passUnretained(event)
        case 2: // changed
            if capturing {
                accumX += CGFloat(dx)
                accumY += CGFloat(dy)
                updatePreview()
                return nil
            }
            return Unmanaged.passUnretained(event)
        case 4, 8: // ended / cancelled
            if capturing {
                if phase == 4 { commit() }
                overlay?.hide()
                reset()
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return capturing ? nil : Unmanaged.passUnretained(event)
        }
    }

    private func beginIfEligible(at loc: CGPoint, modifiers: CGEventFlags) {
        guard let w = windowUnderCursor(loc), let f = frame(of: w) else {
            dbg("began @\(Int(loc.x)),\(Int(loc.y)) : pas de fenêtre exploitable sous le curseur")
            return
        }
        let inTitleBar = loc.y >= f.minY && loc.y <= f.minY + Config.titleBarBand
            && loc.x >= f.minX && loc.x <= f.maxX
        let withModifier = modifiers.contains(.maskControl)
            && f.contains(loc)
        // Cmd maintenu : déplacer la fenêtre vers un autre écran (déclenche partout sur la fenêtre).
        let cmd = modifiers.contains(.maskCommand) && f.contains(loc)
        // Option maintenu : geste d'action (swipe bas = minimiser ; +Cmd = quitter).
        let opt = modifiers.contains(.maskAlternate) && f.contains(loc)
        let anywhere = (Config.captureAnywhere
            || ProcessInfo.processInfo.environment["FLICK_ANYWHERE"] == "1") && f.contains(loc)
        dbg("began @\(Int(loc.x)),\(Int(loc.y)) titleBar=\(inTitleBar) ctrl=\(withModifier) cmd=\(cmd) opt=\(opt) anywhere=\(anywhere)")
        if inTitleBar || withModifier || anywhere || cmd || opt {
            capturing = true
            target = w
            accumX = 0; accumY = 0
            candidateRect = nil; candidateKey = nil
            cmdMode = cmd
            optMode = opt
            vf = axVisibleFrame(forGlobalPoint: CGPoint(x: f.midX, y: f.minY + 1))
        }
    }

    /// Classe la direction accumulée en une zone de snap, ou nil si trop court.
    private func classify(_ fx: CGFloat, _ fy: CGFloat) -> Snap? {
        let ax = abs(fx), ay = abs(fy)
        guard max(ax, ay) >= Config.minTravel else { return nil }
        let major = max(ax, ay), minor = min(ax, ay)
        if (minor / major) >= Config.diagonalRatio {
            switch (fx >= 0, fy >= 0) {
            case (true, true):   return .bottomRight
            case (false, true):  return .bottomLeft
            case (true, false):  return .topRight
            case (false, false): return .topLeft
            }
        } else if ax > ay {
            return fx >= 0 ? .right : .left
        } else {
            return fy >= 0 ? .center : .maximize   // bas = recentrer, haut = maximiser
        }
    }

    /// Affiche/déplace l'aperçu, en n'animant QUE si la cible change (anti-saccades).
    private func showPreview(key: String, rect: CGRect) {
        guard key != candidateKey else { return }
        candidateKey = key; candidateRect = rect
        overlay?.update(toAXRect: rect)
    }
    private func clearPreview() {
        guard candidateKey != nil else { return }
        candidateKey = nil; candidateRect = nil
        overlay?.hide()
    }

    /// Met à jour l'aperçu pendant le geste.
    private func updatePreview() {
        let fx = Config.invertX ? -accumX : accumX
        let fy = Config.invertY ? -accumY : accumY
        let ax = abs(fx), ay = abs(fy)

        if optMode {
            // Geste d'action (minimiser/quitter) : pas d'aperçu de zone.
            clearPreview(); return
        }
        if cmdMode {
            // Déplacement vers l'écran adjacent dans la direction du geste.
            guard max(ax, ay) >= Config.minTravel, let w = target, let wf = frame(of: w) else {
                clearPreview(); return
            }
            let dir: (CGFloat, CGFloat) = ax > ay ? (fx >= 0 ? (1, 0) : (-1, 0))
                                                  : (fy >= 0 ? (0, 1) : (0, -1))
            guard let dst = adjacentScreenFrame(from: wf, dir: dir) else {
                clearPreview(); return     // pas d'écran de ce côté
            }
            let src = axVisibleFrames().first { $0.contains(CGPoint(x: wf.midX, y: wf.midY)) } ?? vf
            showPreview(key: "scr\(dir.0),\(dir.1)", rect: mappedRect(wf, from: src, to: dst))
        } else if let snap = classify(fx, fy) {
            showPreview(key: "snap\(snap)", rect: snap.rect(in: vf))
        } else {
            clearPreview()
        }
    }

    private func commit() {
        guard let w = target else { return }

        // Geste d'action (Option) : swipe bas franc = minimiser ; +Cmd = quitter.
        if optMode {
            let fx = Config.invertX ? -accumX : accumX
            let fy = Config.invertY ? -accumY : accumY
            guard abs(fy) >= Config.minTravel, fy >= 0, abs(fy) > abs(fx) else { return }
            if cmdMode {
                var pid: pid_t = 0
                if AXUIElementGetPid(w, &pid) == .success {
                    NSRunningApplication(processIdentifier: pid)?.terminate()
                }
            } else {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            return
        }

        guard let rect = candidateRect else { return }
        dbg("commit cmd=\(cmdMode) -> \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
        setFrame(w, rect)
        if Config.moveCursorAfterAction {
            // Recentrer le pointeur sur la barre de titre de la position RÉELLE
            // (l'app a pu clamper le cadre). Coords globales = coords AX (haut-gauche).
            let final = frame(of: w) ?? rect
            let p = CGPoint(x: final.midX, y: final.minY + min(Config.titleBarBand / 2, 11))
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1)   // réassocie le déplacement physique
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    private func reset() {
        capturing = false
        target = nil
        cmdMode = false
        optMode = false
        candidateRect = nil; candidateKey = nil
        accumX = 0; accumY = 0
    }
}

// MARK: - App (agent barre de menus)

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = GestureEngine()
    var statusItem: NSStatusItem!

    var statusLabel: NSMenuItem!
    var pollTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌾"
        let menu = NSMenu()
        statusLabel = NSMenuItem(title: "Flick — démarrage…", action: nil, keyEquivalent: "")
        menu.addItem(statusLabel)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu

        // Demande l'autorisation (affiche le prompt la 1re fois).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            activate()
        } else {
            statusLabel.title = "Flick — autorisation requise"
            dbg("pas encore autorisé : attente de l'activation dans Réglages…")
            // Surveille l'autorisation et démarre dès qu'elle est accordée,
            // sans qu'il faille relancer l'app.
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() {
                    t.invalidate()
                    self?.activate()
                }
            }
        }
    }

    private func activate() {
        statusLabel.title = "Flick — actif"
        dbg("autorisé : démarrage du moteur de gestes")
        engine.start()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
