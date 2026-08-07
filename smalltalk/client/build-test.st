"Load every checked-in source file into a scratch image and run the whole SUnit
 suite. Any load failure, test failure or test error exits non-zero, so the
 Docker test stage cannot pass on compilation alone.

 The exclamation mark separates chunks in this format, so it never appears in
 this file."

[
	ConvexBuild load: #(
		'client/Convex.st'
		'client/tests/conformance/ConvexAdapter.st'
		'examples/basics/main.st'
		'client/tests/ConvexClientTests.st'
		'client/tests/ConvexLiveTests.st'
		'examples/basics/main-test.st' ).
	ConvexBuild require: #(
		#ConvexClient #ConvexJson #ConvexWebSocket #ConvexLiveManager
		#ConvexAdapter #ConvexAdapterCommandLineHandler
		#ConvexBasicExample #ConvexExampleCommandLineHandler ).
	'/out/tests-passed.txt' asFileReference
		writeStreamDo: [ :out | out nextPutAll: ConvexBuild runTests ].
	Smalltalk exitSuccess
] on: Error do: [ :error |
	ConvexBuild fail: 'test stage: ', (error messageText ifNil: [ error class name ]) ]!
