//
//  ActionSpec.swift
//  ReactiveSwift
//
//  Created by Justin Spahr-Summers on 2014-12-11.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

import Result
import Nimble
import Quick
import ReactiveSwift

class ActionSpec: QuickSpec {
	override func spec() {
		describe("Action") {
			var action: Action<Int, String, NSError>!
			var enabled: MutableProperty<Bool>!

			var executionCount = 0
			var values: [String] = []
			var errors: [NSError] = []

			var scheduler: TestScheduler!
			let testError = NSError(domain: "ActionSpec", code: 1, userInfo: nil)

			beforeEach {
				executionCount = 0
				values = []
				errors = []
				enabled = MutableProperty(false)

				scheduler = TestScheduler()
				action = Action(enabledIf: enabled) { number in
					return SignalProducer { observer, disposable in
						executionCount += 1

						if number % 2 == 0 {
							observer.send(value: "\(number)")
							observer.send(value: "\(number)\(number)")

							scheduler.schedule {
								observer.sendCompleted()
							}
						} else {
							scheduler.schedule {
								observer.send(error: testError)
							}
						}
					}
				}

				action.values.observeValues { values.append($0) }
				action.errors.observeValues { errors.append($0) }
			}

			it("should be disabled and not executing after initialization") {
				expect(action.isEnabled.value) == false
				expect(action.isExecuting.value) == false
			}

			it("should error if executed while disabled") {
				var receivedError: ActionError<NSError>?
				action.apply(0).startWithFailed {
					receivedError = $0
				}

				expect(receivedError).notTo(beNil())
				if let error = receivedError {
					let expectedError = ActionError<NSError>.disabled
					expect(error == expectedError) == true
				}
			}

			it("should enable and disable based on the given property") {
				enabled.value = true
				expect(action.isEnabled.value) == true
				expect(action.isExecuting.value) == false

				enabled.value = false
				expect(action.isEnabled.value) == false
				expect(action.isExecuting.value) == false
			}

			describe("execution") {
				beforeEach {
					enabled.value = true
				}

				it("should execute successfully") {
					var receivedValue: String?

					action.apply(0)
						.assumeNoErrors()
						.startWithValues {
							receivedValue = $0
						}

					expect(executionCount) == 1
					expect(action.isExecuting.value) == true
					expect(action.isEnabled.value) == false

					expect(receivedValue) == "00"
					expect(values) == [ "0", "00" ]
					expect(errors) == []

					scheduler.run()
					expect(action.isExecuting.value) == false
					expect(action.isEnabled.value) == true

					expect(values) == [ "0", "00" ]
					expect(errors) == []
				}

				it("should execute with an error") {
					var receivedError: ActionError<NSError>?

					action.apply(1).startWithFailed {
						receivedError = $0
					}

					expect(executionCount) == 1
					expect(action.isExecuting.value) == true
					expect(action.isEnabled.value) == false

					scheduler.run()
					expect(action.isExecuting.value) == false
					expect(action.isEnabled.value) == true

					expect(receivedError).notTo(beNil())
					if let error = receivedError {
						let expectedError = ActionError<NSError>.producerFailed(testError)
						expect(error == expectedError) == true
					}

					expect(values) == []
					expect(errors) == [ testError ]
				}
			}
		}

		describe("PropertyAction") {
			it("executes the action with the property's current value") {
				func producer(_ value: Int) -> SignalProducer<Int, NoError> {
					return SignalProducer(value: value)
				}

				let input = MutableProperty(0)
				let action = Action<Void, Int, NoError>(input: input, producer)

				var values: [Int] = []
				action.values.observeValues { values.append($0) }

				input.value = 1
				action.apply().start()
				input.value = 2
				action.apply().start()
				input.value = 3
				action.apply().start()

				expect(values) == [1, 2, 3]
			}

			it("is disabled if the property is nil") {
				let input = MutableProperty<Int?>(1)
				let action = Action<Void, Int, NoError>(input: input) { SignalProducer(value: $0) }

				expect(action.isEnabled.value) == true
				input.value = nil
				expect(action.isEnabled.value) == false
			}
		}
	}
}
