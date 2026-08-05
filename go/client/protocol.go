package convex

import "encoding/json"

const initialTimestamp = "AAAAAAAAAAA="

type wireConnect struct {
	Type                 string `json:"type"`
	SessionID            string `json:"sessionId"`
	ConnectionCount      uint32 `json:"connectionCount"`
	LastCloseReason      string `json:"lastCloseReason"`
	MaxObservedTimestamp string `json:"maxObservedTimestamp,omitempty"`
	ClientTS             int64  `json:"clientTs"`
}

type wireModifyQuerySet struct {
	Type          string                  `json:"type"`
	BaseVersion   uint32                  `json:"baseVersion"`
	NewVersion    uint32                  `json:"newVersion"`
	Modifications []wireQueryModification `json:"modifications"`
}

type wireQueryModification struct {
	Type    string            `json:"type"`
	QueryID uint32            `json:"queryId"`
	UDFPath string            `json:"udfPath,omitempty"`
	Args    []json.RawMessage `json:"args,omitempty"`
}

type wireEnvelope struct {
	Type string `json:"type"`
}

type wireStateVersion struct {
	QuerySet uint32 `json:"querySet"`
	Identity uint32 `json:"identity"`
	TS       string `json:"ts"`
}

type wireTransition struct {
	Type          string                  `json:"type"`
	StartVersion  wireStateVersion        `json:"startVersion"`
	EndVersion    wireStateVersion        `json:"endVersion"`
	Modifications []wireStateModification `json:"modifications"`
}

type wireStateModification struct {
	Type         string          `json:"type"`
	QueryID      uint32          `json:"queryId"`
	Value        json.RawMessage `json:"value"`
	ErrorMessage string          `json:"errorMessage"`
	ErrorData    json.RawMessage `json:"errorData"`
	LogLines     []string        `json:"logLines"`
}

type wireServerError struct {
	Type                string  `json:"type"`
	Error               string  `json:"error"`
	BaseVersion         *uint32 `json:"baseVersion"`
	AuthUpdateAttempted *bool   `json:"authUpdateAttempted"`
}

func zeroStateVersion() wireStateVersion {
	return wireStateVersion{QuerySet: 0, Identity: 0, TS: initialTimestamp}
}
