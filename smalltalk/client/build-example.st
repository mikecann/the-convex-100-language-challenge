"Build the saved image whose only entry point is the canonical basic example.
 The conformance adapter, its adapter-only debugDisconnect hook and every test
 class stay out of it.

 The exclamation mark separates chunks in this format, so it never appears in
 this file."

[
	ConvexBuild load: #(
		'client/Convex.st'
		'examples/basics/main.st' ).
	ConvexBuild require: #( #ConvexClient #ConvexBasicExample #ConvexExampleCommandLineHandler ).
	"The adapter, its channels and the adapter-only hook never ship in the image
	 a reader is invited to run."
	ConvexBuild refuse: #( #ConvexAdapter #ConvexAdapterChannel #ConvexAdapterCommandLineHandler ).
	"A bareword `ConvexClient` here would be resolved when this whole chunk is
	 compiled, which happens before the `load:` above ever runs and the class
	 exists - a dynamic lookup by symbol defers that to when this line
	 actually executes, after the class is loaded."
	((Smalltalk globals at: #ConvexClient) includesSelector: #convexAdapterDebugDisconnect) ifTrue: [
		ConvexBuild fail: 'the adapter-only debugDisconnect hook leaked into the example image' ].
	ConvexBuild saveAs: '/out/convex-example'
] on: Error do: [ :error |
	ConvexBuild fail: 'example image: ', (error messageText ifNil: [ error class name ]) ]!
