package main

import (
	"encoding/json"
	"testing"
)

func TestRoomStateAcceptsIntegralJSONNumbers(t *testing.T) {
	t.Parallel()
	tests := map[string]integralCount{
		`0`:       0,
		`1.0`:     1,
		`-2.000`:  -2,
		`1e3`:     1000,
		`1000e-3`: 1,
	}
	for encoded, expected := range tests {
		encoded := encoded
		expected := expected
		t.Run(encoded, func(t *testing.T) {
			t.Parallel()
			var state roomState
			if err := json.Unmarshal([]byte(`{"count":`+encoded+`}`), &state); err != nil {
				t.Fatal(err)
			}
			if state.Count != expected {
				t.Fatalf("count = %d, want %d", state.Count, expected)
			}
		})
	}
}

func TestRoomStateRejectsUnsafeCounts(t *testing.T) {
	t.Parallel()
	for _, encoded := range []string{
		`1.5`,
		`1e-1000`,
		`"1"`,
		`9223372036854775808`,
		`-9223372036854775809`,
		`1e309`,
		`NaN`,
	} {
		encoded := encoded
		t.Run(encoded, func(t *testing.T) {
			t.Parallel()
			var state roomState
			if err := json.Unmarshal([]byte(`{"count":`+encoded+`}`), &state); err == nil {
				t.Fatal("expected count decoding to fail")
			}
		})
	}
}

func TestRoomStateRequiresCount(t *testing.T) {
	t.Parallel()
	var state roomState
	if err := json.Unmarshal([]byte(`{}`), &state); err == nil {
		t.Fatal("expected missing count to fail")
	}
}
