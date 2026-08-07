"Build the saved image whose only entry point is the test-only conformance
 adapter. The example program and every test class stay out of it, and the
 interactive command surface is removed before the snapshot.

 The exclamation mark separates chunks in this format, so it never appears in
 this file."

[
	ConvexBuild load: #(
		'client/Convex.st'
		'client/tests/conformance/ConvexAdapter.st' ).
	ConvexBuild require: #( #ConvexClient #ConvexAdapter #ConvexAdapterCommandLineHandler ).
	"The canonical example never ships inside the adapter image."
	ConvexBuild refuse: #( #ConvexBasicExample #ConvexExampleCommandLineHandler #ConvexJsonTests ).
	ConvexBuild saveAs: '/out/convex-adapter'
] on: Error do: [ :error |
	ConvexBuild fail: 'adapter image: ', (error messageText ifNil: [ error class name ]) ]!
