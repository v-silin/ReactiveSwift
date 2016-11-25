//
//  Atomic.swift
//  ReactiveSwift
//
//  Created by Justin Spahr-Summers on 2014-06-10.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

import Foundation

internal struct _PosixThreadMutex {
	private var mutex = pthread_mutex_t()

	init() {
		let result = pthread_mutex_init(&mutex, nil)
		precondition(result == 0, "Failed to initialize mutex with error \(result).")
	}

	mutating func deinitialize() {
		let result = pthread_mutex_destroy(&mutex)
		precondition(result == 0, "Failed to destroy mutex with error \(result).")
	}

	@inline(__always)
	mutating func lock() {
		let result = pthread_mutex_lock(&mutex)
		if result != 0 {
			fatalError("Failed to lock \(self) with error \(result).")
		}
	}

	@inline(__always)
	mutating func unlock() {
		let result = pthread_mutex_unlock(&mutex)
		if result != 0 {
			fatalError("Failed to unlock \(self) with error \(result).")
		}
	}
}

internal final class PosixThreadMutex: NSLocking {
	private var mutex = _PosixThreadMutex()

	deinit {
		mutex.deinitialize()
	}

	@inline(__always)
	func lock() {
		mutex.lock()
	}

	@inline(__always)
	func unlock() {
		mutex.unlock()
	}
}

/// An atomic variable.
public final class Atomic<Value>: AtomicProtocol {
	private var lock: _PosixThreadMutex
	private var _value: Value

	/// Atomically get or set the value of the variable.
	public var value: Value {
		@inline(__always)
		get {
			return modify { $0 }
		}

		@inline(__always)
		set(newValue) {
			modify { $0 = newValue }
		}
	}

	/// Initialize the variable with the given initial value.
	/// 
	/// - parameters:
	///   - value: Initial value for `self`.
	public init(_ value: Value) {
		_value = value
		lock = _PosixThreadMutex()
	}

	deinit {
		lock.deinitialize()
	}

	/// Atomically modifies the variable.
	///
	/// - parameters:
	///   - action: A closure that takes the current value.
	///
	/// - returns: The result of the action.
	@discardableResult
	@inline(__always)
	public func modify<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
		lock.lock()
		let value = try action(&_value)
		lock.unlock()
		return value
	}
	
	/// Atomically perform an arbitrary action using the current value of the
	/// variable.
	///
	/// - parameters:
	///   - action: A closure that takes the current value.
	///
	/// - returns: The result of the action.
	@discardableResult
	@inline(__always)
	public func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result {
		lock.lock()
		let value = try action(_value)
		lock.unlock()
		return value
	}

	/// Atomically replace the contents of the variable.
	///
	/// - parameters:
	///   - newValue: A new value for the variable.
	///
	/// - returns: The old value.
	@discardableResult
	@inline(__always)
	public func swap(_ newValue: Value) -> Value {
		return modify { (value: inout Value) in
			let oldValue = value
			value = newValue
			return oldValue
		}
	}
}


/// An atomic variable which uses a recursive lock.
internal final class RecursiveAtomic<Value>: AtomicProtocol {
	private let lock: NSRecursiveLock
	private var _value: Value
	private let didSetObserver: ((Value) -> Void)?

	/// Atomically get or set the value of the variable.
	public var value: Value {
		@inline(__always)
		get {
			return modify { $0 }
		}

		@inline(__always)
		set(newValue) {
			modify { $0 = newValue }
		}
	}

	/// Initialize the variable with the given initial value.
	/// 
	/// - parameters:
	///   - value: Initial value for `self`.
	///   - name: An optional name used to create the recursive lock.
	///   - action: An optional closure which would be invoked every time the
	///             value of `self` is mutated.
	internal init(_ value: Value, name: StaticString? = nil, didSet action: ((Value) -> Void)? = nil) {
		_value = value
		lock = NSRecursiveLock()
		lock.name = name.map(String.init(describing:))
		didSetObserver = action
	}

	/// Atomically modifies the variable.
	///
	/// - parameters:
	///   - action: A closure that takes the current value.
	///
	/// - returns: The result of the action.
	@discardableResult
	@inline(__always)
	func modify<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
		lock.lock()
		let returnValue = try action(&_value)
		didSetObserver?(_value)
		lock.unlock()
		return returnValue
	}
	
	/// Atomically perform an arbitrary action using the current value of the
	/// variable.
	///
	/// - parameters:
	///   - action: A closure that takes the current value.
	///
	/// - returns: The result of the action.
	@discardableResult
	@inline(__always)
	func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result {
		lock.lock()
		let returnValue = try action(_value)
		lock.unlock()
		return returnValue
	}

	/// Atomically replace the contents of the variable.
	///
	/// - parameters:
	///   - newValue: A new value for the variable.
	///
	/// - returns: The old value.
	@discardableResult
	@inline(__always)
	func swap(_ newValue: Value) -> Value {
		return modify { (value: inout Value) in
			let oldValue = value
			value = newValue
			return oldValue
		}
	}
}

public protocol AtomicProtocol: class {
	associatedtype Value

	@discardableResult
	func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result

	@discardableResult
	func modify<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result
}
