package handler

import (
	"strings"
	"testing"
)

func TestValidateAvatarURL(t *testing.T) {
	cases := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{"empty", "", false},
		{"https", "https://example.com/a.png", false},
		{"http", "http://localhost:8080/a.png", false},
		{"relative_with_slash", "/api/files/abc", false},
		{"relative_no_slash", "relative/path", true},
		{"relative_dot", "./path", true},
		{"javascript", "javascript:alert(1)", true},
		{"data", "data:image/png;base64,xxx", true},
		{"ftp", "ftp://example.com", true},
		{"too_long", "https://example.com/" + strings.Repeat("a", 250), true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateAvatarURL(tc.input)
			if (err != nil) != tc.wantErr {
				t.Fatalf("input=%q err=%v wantErr=%v", tc.input, err, tc.wantErr)
			}
		})
	}
}
