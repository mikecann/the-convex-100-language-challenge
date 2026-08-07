"Build helpers shared by the test run and by both saved runtime images.

 These are build metadata rather than client code: they load the checked-in
 chunk files, strip the interactive command surface out of a deployment image,
 and save it under a fixed name. They are never loaded into a runtime image.

 The exclamation mark separates chunks in this format, so it never appears in
 this file."

Object subclass: #ConvexBuild
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Build'!


!ConvexBuild class methodsFor: 'loading'!
load: someRelativePaths
	"Fail the whole build on the first file that does not compile cleanly. A
	 partially loaded image must never be saved."
	someRelativePaths do: [ :path |
		[ CodeImporter evaluateFileNamed: '/project/', path ]
			on: Error
			do: [ :error |
				self fail: 'could not load ', path, ': ', (error messageText ifNil: [ error class name ]) ] ]
!
require: someGlobalNames
	someGlobalNames do: [ :name |
		(Smalltalk globals includesKey: name) ifFalse: [
			self fail: 'expected class ', name asString, ' to exist after loading' ] ]
!
refuse: someGlobalNames
	someGlobalNames do: [ :name |
		(Smalltalk globals includesKey: name) ifTrue: [
			self fail: 'class ', name asString, ' is still present in the deployment image' ] ]
! !

!ConvexBuild class methodsFor: 'hardening'!
interactiveHandlerNames
	"Every command handler that can compile or evaluate arbitrary code, load
	 packages, save images or run tests. A saved runtime image keeps only its own
	 entry point, so the Pharo virtual machine plus that image cannot be used as a
	 general Smalltalk evaluator. Subclasses are listed before superclasses
	 because a class cannot be removed while a subclass still refers to it."
	^ #(
		#EvaluateCommandLineHandler
		#STCommandLineHandler
		#SaveCommandLineHandler
		#TestCommandLineHandler
		#MetacelloCommandLineHandler
		#InitializePackagesCommandLineHandler
		#PerformMessageCommandLineHandler
		#ClapCommandLineHandler
		#PrintVersionCommandLineHandler )
!
removeInteractiveHandlers
	self interactiveHandlerNames do: [ :name |
		Smalltalk globals
			at: name
			ifPresent: [ :handlerClass |
				[ handlerClass removeFromSystem ]
					on: Error
					do: [ :error |
						self fail: 'could not remove ', name asString, ': ', (error messageText ifNil: [ 'unknown' ]) ] ] ].
	self refuse: self interactiveHandlerNames
! !

!ConvexBuild class methodsFor: 'saving'!
saveAs: aPathWithoutSuffix
	"Harden first, then snapshot. The saved image is what ships, so anything left
	 in the system dictionary at this point ships with it."
	| result |
	self removeInteractiveHandlers.
	Smalltalk garbageCollect.
	result := Smalltalk saveAs: aPathWithoutSuffix.
	result == true ifTrue: [
		"Pharo answers true in the freshly started deployment image and false in
		 the builder that is still running. Returning here lets the new image fall
		 through to its normal command line dispatch."
		^ self ].
	Smalltalk exitSuccess
!
fail: aMessage
	[ Stdio stderr
		nextPutAll: (ZnUTF8Encoder new encodeString: 'convex build failed: ', aMessage, String lf);
		flush ] on: Error do: [ :ignored | nil ].
	Smalltalk exit: 3
!
report: aMessage
	[ Stdio stderr
		nextPutAll: (ZnUTF8Encoder new encodeString: aMessage, String lf);
		flush ] on: Error do: [ :ignored | nil ]
! !

!ConvexBuild class methodsFor: 'testing'!
runTests
	"Run every checked-in SUnit test and exit non-zero unless all of them pass."
	| suite result summary |
	suite := TestSuite new.
	#( #ConvexJsonTests #ConvexTimestampTests #ConvexWebSocketTests #ConvexHttpTests
	   #ConvexLiveTests #ConvexAdapterTests #ConvexBasicExampleTests ) do: [ :name |
		Smalltalk globals
			at: name
			ifPresent: [ :testClass | suite addTests: testClass buildSuite tests ]
			ifAbsent: [ self fail: 'expected test class ', name asString ] ].
	result := suite run.
	summary := 'tests run: ', result runCount printString,
		' passed: ', result expectedPassCount printString,
		' failed: ', result failureCount printString,
		' errors: ', result errorCount printString.
	self report: summary.
	result failures do: [ :each | self report: 'FAIL ', each printString ].
	result errors do: [ :each | self report: 'ERROR ', each printString ].
	(result failureCount = 0 and: [ result errorCount = 0 ]) ifFalse: [
		self fail: summary ].
	result runCount < 40 ifTrue: [
		self fail: 'expected at least 40 tests, ran ', result runCount printString ].
	^ summary
! !
