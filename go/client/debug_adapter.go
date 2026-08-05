//go:build convexadapter

package convex

import "errors"

// DebugDisconnectForAdapter is compiled only into the conformance adapter. It
// deliberately stays out of normal library builds and forces a reconnect test
// without granting the adapter access to Docker or the host network stack.
func (c *Client) DebugDisconnectForAdapter() error {
	c.mu.RLock()
	manager := c.live
	closed := c.closed
	c.mu.RUnlock()
	if closed {
		return ErrClosed
	}
	if manager == nil {
		return errors.New("Live WebSocket has not been started")
	}
	return manager.debugDisconnect()
}
