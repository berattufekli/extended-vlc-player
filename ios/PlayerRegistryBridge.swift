import Foundation

/// Exposes the Swift-only `PlayerRegistry` to the Obj-C++ Fabric component
/// view. The class methods are `@objc` so they show up in the generated
/// `ExtendedVlcPlayer-Swift.h` header.
@objc(EXVLCPlayerRegistryBridge)
final class PlayerRegistryBridge: NSObject {
  @objc static func createSession() -> NSNumber {
    let (id, _) = PlayerRegistry.shared.next()
    return NSNumber(value: id)
  }

  /// Returns a NSNumber-wrapped PlayerSession opaque pointer. The Obj-C++
  /// view keeps this opaque reference and uses it to call closure setters
  /// on the session.
  @objc static func session(forId id: NSNumber) -> NSValue? {
    guard let session = PlayerRegistry.shared.session(for: id.intValue) else { return nil }
    return NSValue(nonretainedObject: session)
  }

  @objc static func destroySession(_ id: NSNumber) {
    PlayerRegistry.shared.remove(id: id.intValue)
  }

  /// Forwards a JS event payload into the Fabric event dispatcher. The
  /// Obj-C++ view's event blocks call into this and we surface them as
  /// normal Fabric component events.
  @objc static func attachEventSinks(_ id: NSNumber, _ view: UIView) {
    guard let session = PlayerRegistry.shared.session(for: id.intValue) else { return }
    let view = view
    session.onLoad = { [weak view] payload in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onLoad", payload)
    }
    session.onProgress = { [weak view] payload in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onProgress", payload)
    }
    session.onPlaying = { [weak view] payload in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onPlaying", payload)
    }
    session.onPaused = { [weak view] payload in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onPaused", payload)
    }
    session.onEnded = { [weak view] in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onEnded", [:])
    }
    session.onError = { [weak view] payload in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onError", payload)
    }
    session.onBuffering = { [weak view] payload in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onBuffering", payload)
    }
    session.onPictureInPictureStart = { [weak view] in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onPictureInPictureStart", [:])
    }
    session.onPictureInPictureStop = { [weak view] in
      (view as? ExtendedVlcPlayerViewEventReceiver)?.exvlcEmit("onPictureInPictureStop", [:])
    }
  }
}

/// Implemented by the Fabric component view (in Obj-C++) so that the
/// Swift registry bridge can forward events to the view, which in turn
/// surfaces them via the standard Fabric event system. This indirection
/// keeps Swift-only types out of the Obj-C++ source.
@objc protocol ExtendedVlcPlayerViewEventReceiver {
  func exvlcEmit(_ name: String, _ payload: [AnyHashable: Any])
}
