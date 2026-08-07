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
!
disableFilesystemStartupPersistence
	"Stock Pharo ships one OmSessionStore already registered (pointed at
	 {localDirectory}/ombu-sessions, on disk beside whatever image is
	 running), used internally by GlobalIdentifierFuelPersistence to persist
	 Fuel's global object identifiers -- entirely orthogonal to Convex.
	 OmSessionStore class>>startUp re-verifies every registered store on
	 every single image boot (`registry do: [ :each | each store ]`), and a
	 fresh boot always counts as a new Smalltalk session
	 (OmSessionStore>>needsReset), so this is not a one-time cost: it runs
	 every time the saved image starts, including every verification run.

	 This deployment image ships on a read-only filesystem with no writable
	 directory anywhere -- by design, matched by the runtime-base self-test
	 a few lines below asserting `/usr`, `/var` and `/tmp` do not exist, and
	 by every verifier invocation in this repository's run script, which
	 mounts none of these images with a writable filesystem. There is no
	 honest directory this store could be pointed at instead. Clearing the
	 registry before the snapshot below, so startUp's registry do: [ ... ]
	 has nothing left to iterate, is the direct fix rather than papering
	 over it with a writable location the image would only pretend to
	 need."
	OmSessionStore instVarNamed: 'registry' put: WeakSet new.
	(OmSessionStore instVarNamed: 'registry') isEmpty ifFalse: [
		self fail: 'could not clear the OmSessionStore registry' ].

	"The command-line entry point itself is the more direct trigger, on
	 every boot of a saved image regardless of the registry above:
	 PharoCommandLineHandler>>runPreferences unconditionally sends
	 `SystemSettingsPersistence resumeSystemSettings`, which asks
	 GlobalIdentifier uniqueInstance for this machine's UUID; the first
	 time that identifier has never been computed (true for every fresh
	 process, since it is not something the object graph carries forward
	 in a form the VM's own session bookkeeping preserves as still valid)
	 it tries to persist a newly generated one via
	 GlobalIdentifierFuelPersistence, hitting the same missing writable
	 directory. Removing the whole class -- the same move
	 removeInteractiveHandlers already makes for the command handlers
	 above -- is honest rather than fragile: runPreferences reaches it
	 only via `Smalltalk at: #SystemSettingsPersistence ifPresent: [...]`,
	 so once the class is gone the call is skipped outright, not merely
	 pre-warmed and hoping a cache survives the snapshot."
	Smalltalk globals
		at: #SystemSettingsPersistence
		ifPresent: [ :settingsPersistence |
			[ settingsPersistence removeFromSystem ]
				on: Error
				do: [ :error |
					self fail: 'could not remove SystemSettingsPersistence: ',
						(error messageText ifNil: [ 'unknown' ]) ] ].
	(Smalltalk globals includesKey: #SystemSettingsPersistence) ifTrue: [
		self fail: 'SystemSettingsPersistence is still present in the deployment image' ]
! !

!ConvexBuild class methodsFor: 'saving'!
saveAs: aPathWithoutSuffix
	"Harden first, then snapshot. The saved image is what ships, so anything left
	 in the system dictionary at this point ships with it."
	| result |
	self removeInteractiveHandlers.
	self disableFilesystemStartupPersistence.
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
