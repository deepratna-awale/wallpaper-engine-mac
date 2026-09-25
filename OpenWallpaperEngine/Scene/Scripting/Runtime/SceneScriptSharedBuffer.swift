import Foundation
import JavaScriptCore

/// Swift-owned memory that JavaScript sees as a typed array over the same bytes, so the renderer
/// and scripts exchange per-frame data without marshalling (docs/scenescript-plan.md §4.3).
///
/// The typed array owns the allocation: JavaScriptCore frees it when the array is collected, and
/// this object keeps the array alive, so `pointer` stays valid for this object's lifetime. Fixed
/// capacity; a larger table is a new buffer. Confined to the runtime's thread.
final class SceneScriptSharedBuffer<Element: SceneScriptSharedElement> {
    let count: Int
    let pointer: UnsafeMutablePointer<Element>
    /// The typed array (`Float32Array`, `Int32Array`, …) to hand to JavaScript.
    let value: JSValue

    init?(count: Int, in context: JSContext) {
        guard count > 0, let contextRef = context.jsGlobalContextRef else { return nil }
        let memory = UnsafeMutablePointer<Element>.allocate(capacity: count)
        memory.initialize(repeating: Element.zero, count: count)
        let deallocate: JSTypedArrayBytesDeallocator = { bytes, _ in bytes?.deallocate() }
        var exception: JSValueRef?
        let byteCount = count * MemoryLayout<Element>.stride
        guard let object = JSObjectMakeTypedArrayWithBytesNoCopy(
            contextRef, Element.typedArrayType, memory, byteCount, deallocate, nil, &exception),
              exception == nil, let value = JSValue(jsValueRef: object, in: context) else {
            memory.deallocate()
            return nil
        }
        self.count = count
        self.pointer = memory
        self.value = value
    }

    subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count, "SceneScriptSharedBuffer index out of range")
            return pointer[index]
        }
        set {
            precondition(index >= 0 && index < count, "SceneScriptSharedBuffer index out of range")
            pointer[index] = newValue
        }
    }
}

/// The element types a shared buffer can hold, with their JavaScript typed-array kind.
protocol SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { get }
    static var zero: Self { get }
}

extension Float: SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { kJSTypedArrayTypeFloat32Array }
}

extension Int32: SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { kJSTypedArrayTypeInt32Array }
}

extension UInt8: SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { kJSTypedArrayTypeUint8Array }
}
