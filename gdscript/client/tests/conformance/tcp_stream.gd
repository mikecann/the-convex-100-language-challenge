class_name ConvexTcpStream
extends RefCounted

# One accepted controller connection as an adapter stream.
#
# StreamPeerTCP is non-blocking here, so put_partial_data may take only part
# of a line when the controller stops reading. The output queue keeps the
# unwritten remainder and its byte accounting, which is what turns a stalled
# reader into a bounded, structured adapter failure instead of unbounded
# growth.

var _peer: StreamPeerTCP


func _init(peer: StreamPeerTCP) -> void:
	_peer = peer


func send(bytes: PackedByteArray, _text: String) -> int:
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return -1
	var written: Array = _peer.put_partial_data(bytes)
	if written[0] != OK:
		return -1
	return written[1]


func close() -> void:
	_peer.disconnect_from_host()
