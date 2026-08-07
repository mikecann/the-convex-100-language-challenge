"The canonical example's own regression lives beside the source it protects.

 Convex may send an integral number as 0.0 rather than 0, so the example's
 decoder is the piece most likely to be quietly wrong against a real
 deployment. This exercises the exact class method the example calls.

 The exclamation mark separates chunks in this format, so it never appears in
 this file."

TestCase subclass: #ConvexBasicExampleTests
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Example-Tests'!


!ConvexBasicExampleTests methodsFor: 'tests'!
testAcceptsIntegersAndIntegralDecimals
	self
		assert: (ConvexBasicExample countFrom: (ConvexJson parseString: '{"count":0}') operation: 'test')
		equals: 0.
	self
		assert: (ConvexBasicExample countFrom: (ConvexJson parseString: '{"count":0.0}') operation: 'test')
		equals: 0.
	self
		assert: (ConvexBasicExample countFrom: (ConvexJson parseString: '{"count":1.0}') operation: 'test')
		equals: 1
!
testRejectsFractionalQuotedAndOverflowingCounts
	self
		should: [ ConvexBasicExample countFrom: (ConvexJson parseString: '{"count":1.5}') operation: 'test' ]
		raise: ConvexProtocolError.
	self
		should: [ ConvexBasicExample countFrom: (ConvexJson parseString: '{"count":"1"}') operation: 'test' ]
		raise: ConvexProtocolError.
	self
		should: [ ConvexBasicExample countFrom: (ConvexJson parseString: '{"count":-1}') operation: 'test' ]
		raise: ConvexProtocolError.
	self
		should: [ ConvexBasicExample
			countFrom: (ConvexJson parseString: '{"count":9223372036854775808}')
			operation: 'test' ]
		raise: ConvexProtocolError
!
testRejectsValuesThatAreNotACountObject
	self
		should: [ ConvexBasicExample countFrom: (ConvexJson parseString: '{"total":1}') operation: 'test' ]
		raise: ConvexProtocolError.
	self
		should: [ ConvexBasicExample countFrom: nil operation: 'test' ]
		raise: ConvexProtocolError.
	self
		should: [ ConvexBasicExample countFrom: (ConvexJson parseString: '[1]') operation: 'test' ]
		raise: ConvexProtocolError
! !
