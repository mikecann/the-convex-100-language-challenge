package convex

import (
	"encoding/base64"
	"testing"
)

func TestCompareTimestampsUsesLittleEndianNumericOrder(t *testing.T) {
	encode := func(value uint64) string {
		bytes := []byte{
			byte(value), byte(value >> 8), byte(value >> 16), byte(value >> 24),
			byte(value >> 32), byte(value >> 40), byte(value >> 48), byte(value >> 56),
		}
		return base64.StdEncoding.EncodeToString(bytes)
	}

	comparison, err := compareTimestamps(encode(256), encode(255))
	if err != nil {
		t.Fatal(err)
	}
	if comparison != 1 {
		t.Fatalf("comparison = %d, want 1", comparison)
	}
}

func TestCompareTimestampsRejectsMalformedValues(t *testing.T) {
	if _, err := compareTimestamps("bad", initialTimestamp); err == nil {
		t.Fatal("expected malformed timestamp error")
	}
}
