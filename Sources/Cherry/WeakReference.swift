/// Holds `object` without keeping it alive: a collection's element that
/// goes nil once the object is gone.
final class WeakReference<Object: AnyObject> {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}
