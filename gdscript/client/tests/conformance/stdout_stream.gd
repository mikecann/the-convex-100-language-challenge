class_name ConvexStdoutStream
extends RefCounted

# Standard output as an adapter stream.
#
# Godot's print() hands one complete line to the engine's stdout and has no
# partial-write concept, so this stream always reports that it accepted every
# byte and the output queue never has to resume a half-written line here. The
# project enables application/run/flush_stdout_on_print, so each NDJSON line
# reaches the controller when it is written instead of waiting in a buffer.


func send(bytes: PackedByteArray, text: String) -> int:
	print(text)
	return bytes.size()


func close() -> void:
	# Standard output belongs to the process, not to this object. There is
	# nothing to release, and closing the real descriptor would silence the
	# diagnostics that follow a failure.
	pass
