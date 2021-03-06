import Spots
import Brick
import Compass
import Malibu
import Sugar
import Tailor

public enum KeyboardEvents: UInt16 {
  case up = 126
  case down = 125
  case enter = 36
}

class DetailController: Spots.Controller, SpotsDelegate, ScrollDelegate {

  lazy var shadowSeparator = NSView().then {
    $0.alphaValue = 0.0
    $0.frame.size.height = 2
    $0.wantsLayer = true
    $0.layer?.backgroundColor = NSColor.black.alpha(0.4).cgColor

    var gradientLayer = CAGradientLayer()
    gradientLayer.frame.size.height = $0.frame.size.height
    gradientLayer.colors = [
      NSColor.clear.cgColor,
      NSColor.black.cgColor,
      NSColor.clear.cgColor
    ]
    gradientLayer.locations = [0.0, 0.5, 1.0]
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)

    $0.layer?.mask = gradientLayer

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black
    shadow.shadowBlurRadius = 3.0
    shadow.shadowOffset = CGSize(width: 0, height: -6)
    $0.shadow = shadow
  }

  var rides = [Ride]()
  var blueprint: Blueprint? {
    didSet {
      guard let blueprint = blueprint else { return }

      #if DEVMODE
      self.source = nil
      #endif
      let newCache = StateCache(key: blueprint.cacheKey)
      self.stateCache = newCache
      var spots = newCache.load()

      if spots.isEmpty {
        spots = blueprint.template
      }

      reloadSpots(spots: Parser.parse(spots)) {
        self.process(self.fragments)
        self.build(blueprint)
        self.delegate = self
        self.cache()
      }
    }
  }

  var fragments: [String : Any] = [:]

  required init(spots: [Spotable], backgroundType: ControllerBackground) {
    super.init(spots: spots, backgroundType: backgroundType)

    NotificationCenter.default.addObserver(self, selector: #selector(DetailController.willEnterFullscreen(_:)), name: NSNotification.Name.NSWindowWillEnterFullScreen, object: nil)

    NotificationCenter.default.addObserver(self, selector: #selector(DetailController.willExitFullscreen(_:)), name: NSNotification.Name.NSWindowWillExitFullScreen, object: nil)

    let notificationCenter = NotificationCenter.default
    notificationCenter.addObserver(self, selector: #selector(DetailController.activate),
                                   name: NSNotification.Name(rawValue: "sessionActivate"), object: nil)

    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (theEvent) -> NSEvent? in
      if self.handleKeyDown(theEvent) == true {
        return theEvent
      }
      return nil
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    view.addSubview(shadowSeparator)
    scrollView.frame.origin.y = -40
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    guard let blueprint = blueprint else { return }
    build(blueprint)
    scrollDelegate = self
  }

  func willEnterFullscreen(_ notification: NSNotification) {
    self.scrollView.animator().setFrameOrigin(
      NSPoint(x: self.scrollView.frame.origin.x, y: -20)
    )
  }

  func willExitFullscreen(_ notification: NSNotification) {
    scrollView.frame.origin.y = -40
  }

  func build(_ blueprint: Blueprint) {
    removeGradientSublayers()
    shadowSeparator.alphaValue = 0.0
    for ride in rides {
      ride.cancel()
    }
    rides = []

    for element in blueprint.requests {
      guard let request = element.request else { return }
      let ride = Malibu.networking("api").GET(request)
      ride.validate()
        .toJsonDictionary()
        .done { json in
          var items: [[String : Any]]
          if let rootElementItems: [[String : Any]] = json.resolve(keyPath: "\(element.rootKey).items") {
            items = rootElementItems
          } else {
            if let rootItems: [[String : Any]] = json.resolve(keyPath: "items") {
              items = rootItems
            } else {
              guard let secondaryItems: [[String : Any]] = json.resolve(keyPath: element.rootKey) else { return }
              items = secondaryItems
            }
          }

          let viewModels = element.adapter(items)
          self.updateIfNeeded(spotAtIndex: element.spotIndex, items: viewModels) {
            self.cache()
          }
        }.fail { error in
          NSLog("request: \(request.message)")
          NSLog("error: \(error)")
      }
      rides.append(ride)
    }
  }

  func process(_ fragments: [String : Any]? = nil) {
    guard let handler = blueprint?.fragmentHandler, let fragments = fragments , fragments["skipHistory"] == nil else { return }

    handler(fragments, self)
  }

  func removeGradientSublayers() {
    guard let sublayers = view.layer?.sublayers else { return }
    for case let sublayer as CAGradientLayer in sublayers {
      sublayer.removeFromSuperlayer()
    }
  }

  override func viewWillLayout() {
    super.viewWillLayout()

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    shadowSeparator.frame.size.width = view.frame.width
    shadowSeparator.frame.origin.y = view.frame.maxY + scrollView.frame.origin.y - shadowSeparator.frame.size.height

    guard let sublayers = view.layer?.sublayers else { return }
    for case let sublayer as CAGradientLayer in sublayers {
      sublayer.frame = view.frame
    }

    shadowSeparator.layer?.mask?.frame.size.width = view.frame.width

    CATransaction.commit()
  }

  override func scrollViewDidScroll(_ notification: NSNotification) {
    super.scrollViewDidScroll(notification)

    guard let scrollView = notification.object as? SpotsScrollView else { return }

    var from: CGFloat = 0.0
    var to: CGFloat = 0.0
    var shouldAnimate = false

    if scrollView.contentOffset.y > 0.0 && shadowSeparator.alphaValue == 0.0 {
      from = 0.0
      to = 1.0
      shouldAnimate = true
    } else if scrollView.contentOffset.y <= 0.0 && shadowSeparator.alphaValue == 1.0 {
      from = 1.0
      to = 0.0
      shouldAnimate = true
    }

    if shouldAnimate {
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 3.0
        self.shadowSeparator.alphaValue = from
      }) {
        self.shadowSeparator.alphaValue = to
      }
    }
  }

  func handleKeyDown(_ theEvent: NSEvent) -> Bool {
    super.keyDown(with: theEvent)

    guard let window = theEvent.window,
      let tableView = window.firstResponder as? NSTableView,
      let scrollView = tableView.superview?.superview as? ScrollView,
      let keyEvent = KeyboardEvents(rawValue: theEvent.keyCode),
      let currentSpot = spots.filter({ $0.responder == tableView }).first as? Listable
      else { return true }

    if let model = currentSpot.item(at: tableView.selectedRow), keyEvent == .enter {
      didSelect(item: model, in: currentSpot)
      return false
    }

    let viewRect = tableView.rect(ofRow: tableView.selectedRow)
    let currentView = viewRect.origin.y + viewRect.size.height
    let viewPortMin = scrollView.contentOffset.y - scrollView.frame.origin.y
    let viewPortMax = scrollView.frame.size.height + scrollView.contentOffset.y - scrollView.frame.origin.y - scrollView.contentInsets.top + scrollView.frame.origin.y

    var newY: CGFloat = 0.0
    var shouldScroll: Bool = false
    if currentView >= viewPortMax {
      newY = viewRect.origin.y - viewRect.size.height - scrollView.frame.origin.y - scrollView.contentInsets.top
      shouldScroll = true
    } else if currentView <= viewPortMin && viewPortMin > 0.0 {
      shouldScroll = true
      newY = viewRect.origin.y - scrollView.frame.origin.y
    }

    if shouldScroll {
      NSAnimationContext.runAnimationGroup({ (context) in
        context.duration = 0.3
        var newOrigin: NSPoint = self.scrollView.contentView.bounds.origin
        newOrigin.y = newY
        self.scrollView.contentView.animator().setBoundsOrigin(newOrigin)
        self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }, completionHandler: nil)
    }

    return true
  }

  func activate() {
    guard let blueprint = blueprint else { return }
    build(blueprint)
  }
}

extension DetailController {

  func didSelect(item: Item, in spot: Spotable) {
    guard let action = item.action else { return }

    if item.kind == "track" {
      for item in spot.items where item.meta("playing", type: Bool.self) == true {
        var item = item
        item.meta["playing"] = false
        update(item, index: item.index, spotIndex: spot.index, withAnimation: .none, completion: nil)
      }
      var newItem = item
      newItem.meta["playing"] = !item.meta("playing", false)

      update(newItem, index: item.index, spotIndex: spot.index, withAnimation: .none, completion: nil)

      if item.meta("playing", type: Bool.self) == true {
        guard let appDelegate = NSApplication.shared().delegate as? AppDelegate else { return }
        appDelegate.player?.stop()
        return
      }
    }

    AppDelegate.navigate(action, fragments: item.meta("fragments", [:]))
  }
}

extension DetailController {

  func didReachBeginning(in scrollView: ScrollableView, completion: Completion) {
    completion?()
  }

  func didReachEnd(in scrollView: ScrollableView, completion: Completion) {
    completion?()
  }
}
