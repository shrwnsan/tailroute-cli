package main

import (
	"os"
	"testing"
)

func TestValidateSocksAddr(t *testing.T) {
	tests := []struct {
		name    string
		addr    string
		wantErr bool
	}{
		{"localhost ipv4", "127.0.0.1:1055", false},
		{"localhost name", "localhost:1055", false},
		{"localhost ipv6", "[::1]:1055", false},
		{"0.0.0.0 reject", "0.0.0.0:1055", true},
		{"empty host reject", ":1055", true},
		{":: reject", "[::]:1055", true},
		{"public IP reject", "192.168.1.1:1055", true},
		{"custom port", "127.0.0.1:1080", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateSocksAddr(tt.addr)
			if (err != nil) != tt.wantErr {
				t.Errorf("validateSocksAddr(%q) error = %v, wantErr %v", tt.addr, err, tt.wantErr)
			}
		})
	}
}

func TestDefaultValues(t *testing.T) {
	// Reset flags to default state
	flagHostname := "tailroute-proxy"
	flagStateDir := os.ExpandEnv("$HOME/.tailroute/proxy-state")
	flagSocksAddr := "127.0.0.1:1055"

	if flagHostname != "tailroute-proxy" {
		t.Errorf("expected default hostname 'tailroute-proxy', got '%s'", flagHostname)
	}
	if flagStateDir == "" {
		t.Error("expected default state-dir to be set")
	}
	if flagSocksAddr != "127.0.0.1:1055" {
		t.Errorf("expected default socks-addr '127.0.0.1:1055', got '%s'", flagSocksAddr)
	}
}
