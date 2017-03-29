//
//  Atomic.swift
//  ReactiveSwift
//
//  Created by Justin Spahr-Summers on 2014-06-10.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
	import MachO
#endif

/// Represents a finite state machine that can transit from one state to
/// another.
internal protocol AtomicStateProtocol {
	associatedtype State: RawRepresentable
	
	/// Try to transition from the expected current state to the specified next
	/// state.
	///
	/// - parameters:
	///   - expected: The expected state.
	///
	/// - returns:
	///   `true` if the transition succeeds. `false` otherwise.
	func tryTransition(from expected: State, to next: State) -> Bool
}

/// A simple, generic lock-free finite state machine.
///
/// - warning: `deinitialize` must be called to dispose of the consumed memory.
internal struct UnsafeAtomicState<State: RawRepresentable>: AtomicStateProtocol where State.RawValue == Int32 {
	internal typealias Transition = (expected: State, next: State)
	#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
	private let value: UnsafeMutablePointer<Int32>
	
	/// Create a finite state machine with the specified initial state.
	///
	/// - parameters:
	///   - initial: The desired initial state.
	internal init(_ initial: State) {
		value = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
		value.initialize(to: initial.rawValue)
	}
	
	/// Deinitialize the finite state machine.
	internal func deinitialize() {
		value.deinitialize()
		value.deallocate(capacity: 1)
	}
	
	/// Compare the current state with the specified state.
	///
	/// - parameters:
	///   - expected: The expected state.
	///
	/// - returns:
	///   `true` if the current state matches the expected state. `false`
	///   otherwise.
	internal func `is`(_ expected: State) -> Bool {
		return OSAtomicCompareAndSwap32Barrier(expected.rawValue,
		                                       expected.rawValue,
		                                       value)
	}
	
	/// Try to transition from the expected current state to the specified next
	/// state.
	///
	/// - parameters:
	///   - expected: The expected state.
	///
	/// - returns:
	///   `true` if the transition succeeds. `false` otherwise.
	internal func tryTransition(from expected: State, to next: State) -> Bool {
		return OSAtomicCompareAndSwap32Barrier(expected.rawValue,
		                                       next.rawValue,
		                                       value)
	}
	#else
	private let value: Atomic<Int32>
	
	/// Create a finite state machine with the specified initial state.
	///
	/// - parameters:
	///   - initial: The desired initial state.
	internal init(_ initial: State) {
	value = Atomic(initial.rawValue)
	}
	
	/// Deinitialize the finite state machine.
	internal func deinitialize() {}
	
	/// Compare the current state with the specified state.
	///
	/// - parameters:
	///   - expected: The expected state.
	///
	/// - returns:
	///   `true` if the current state matches the expected state. `false`
	///   otherwise.
	internal func `is`(_ expected: State) -> Bool {
	return value.modify { $0 == expected.rawValue }
	}
	
	/// Try to transition from the expected current state to the specified next
	/// state.
	///
	/// - parameters:
	///   - expected: The expected state.
	///
	/// - returns:
	///   `true` if the transition succeeds. `false` otherwise.
	internal func tryTransition(from expected: State, to next: State) -> Bool {
	return value.modify { value in
	if value == expected.rawValue {
	value = next.rawValue
	return true
	}
	return false
	}
	}
	#endif
}

final class PosixThreadMutex: NSLocking {
	private var mutex = pthread_mutex_t()
	
	init() {
		let result = pthread_mutex_init(&mutex, nil)
		precondition(result == 0, "Failed to initialize mutex with error \(result).")
	}
	
	deinit {
		let result = pthread_mutex_destroy(&mutex)
		precondition(result == 0, "Failed to destroy mutex with error \(result).")
	}
	
	func lock() {
		let result = pthread_mutex_lock(&mutex)
		precondition(result == 0, "Failed to lock \(self) with error \(result).")
	}
	
	func unlock() {
		let result = pthread_mutex_unlock(&mutex)
		precondition(result == 0, "Failed to unlock \(self) with error \(result).")
	}
}

/// An atomic variable.
public final class Atomic<Value>: AtomicProtocol {
	private let lock: PosixThreadMutex
	private var _value: Value
    
	/// Initialize the variable with the given initial value.
	///
	/// - parameters:
	///   - value: Initial value for `self`.
	public init(_ value: Value) {
		_value = value
		lock = PosixThreadMutex()
	}
	
	/// Atomically modifies the variable.
	///
	/// - parameters:
	///   - action: A closure that takes the current value.
	///
    /// - returns: The result of the action.
    @discardableResult
    public func modify<Result>(_ action: (inout Value) throws -> Result, start: (() -> ())? = nil, end: (() -> ())? = nil) rethrows -> Result {
        start?()
        
		lock.lock()
		defer {
            lock.unlock()
            
            end?()
        }
        
		return try action(&_value)
	}
	
	/// Atomically perform an arbitrary action using the current value of the
	/// variable.
	///
	/// - parameters:
	///   - action: A closure that takes the current value.
	///
	/// - returns: The result of the action.
	@discardableResult
	public func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		
		return try action(_value)
	}

	/// Atomically replace the contents of the variable.
	///
	/// - parameters:
	///   - newValue: A new value for the variable.
	///
	/// - returns: The old value.
	@discardableResult
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
	private let didSetQueue: OperationQueue
    
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
		didSetQueue = OperationQueue()
		didSetQueue.maxConcurrentOperationCount = 1
	}
	
	/// Atomically modifies the variable.
	///
	/// - parameters:
	///   - action: A closure that takes the current value.
	///
	/// - returns: The result of the action.
    @discardableResult
    func modify<Result>(_ action: (inout Value) throws -> Result, start: (() -> ())?, end: (() -> ())?) rethrows -> Result {
        lock.lock()
        defer {
            let _value = self._value
            
            if didSetQueue.operationCount >= 1 {
                print("if didSetQueue.operationCount > 1 { \(didSetQueue.operationCount)")
                print("if didSetQueue.operationCount > 1 { \(didSetQueue.operationCount)")
            }
            
            didSetQueue.addOperation {
                start?()
                
                #if DEBUG
                    print("DID_SET_OBSERVER \(_value)")
                #endif
                
                self.didSetObserver?(_value)
                
                end?()
            }
            
            lock.unlock()
        }
        
        return try action(&_value)
	}
	
	/// Atomically perform an arbitrary action using the current value of the
	/// variable.
	///
	/// - parameters:
	///   - action: A closure that takes the current value.
	///
	/// - returns: The result of the action.
	@discardableResult
	func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		
		return try action(_value)
	}
    
}

/// A protocol used to constraint convenience `Atomic` methods and properties.
public protocol AtomicProtocol: class {
	associatedtype Value
	
	@discardableResult
	func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result
	
	@discardableResult
	func modify<Result>(_ action: (inout Value) throws -> Result, start: (() -> ())?, end: (() -> ())?) rethrows -> Result
}

extension AtomicProtocol {
	/// Atomically get or set the value of the variable.
	public var value: Value {
		get {
			return withValue { $0 }
		}
		
		set(newValue) {
			swap(newValue)
		}
	}
    
	/// Atomically replace the contents of the variable.
	///
	/// - parameters:
	///   - newValue: A new value for the variable.
	///
	/// - returns: The old value.
	@discardableResult
    public func swap(_ newValue: Value, start: (() -> ())? = nil, end: (() -> ())? = nil) -> Value {
		return modify({ (value: inout Value) in
			let oldValue = value
			value = newValue
			return oldValue
        }, start: start, end: end)
	}
}
