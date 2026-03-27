package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	socks5 "github.com/shrwnsan/go-socks5"
	"tailscale.com/tsnet"
)

var (
	version   = "0.5.0-beta.1"
	hostname  string
	stateDir  string
	authKey   string
	ephemeral bool
	socksAddr string
	printVers bool
)

func init() {
	flag.StringVar(&hostname, "hostname", "tailroute-proxy", "tsnet hostname")
	flag.StringVar(&stateDir, "state-dir", os.ExpandEnv("$HOME/.tailroute/proxy-state"), "tsnet state directory")
	flag.StringVar(&authKey, "auth-key", os.Getenv("TS_AUTHKEY"), "Tailscale auth key (or TS_AUTHKEY env)")
	flag.BoolVar(&ephemeral, "ephemeral", true, "Use ephemeral node")
	flag.StringVar(&socksAddr, "socks-addr", "127.0.0.1:1055", "SOCKS5 bind address (localhost only)")
	flag.BoolVar(&printVers, "version", false, "Print version and exit")
}

func main() {
	flag.Parse()

	if printVers {
		fmt.Printf("tailroute-proxy %s\n", version)
		os.Exit(0)
	}

	log.Printf("tailroute-proxy %s", version)

	// Validate socks-addr is localhost only
	if err := validateSocksAddr(socksAddr); err != nil {
		log.Fatalf("Invalid SOCKS5 address: %v", err)
	}

	// Ensure state directory exists
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		log.Fatalf("Failed to create state directory: %v", err)
	}

	// Initialize tsnet server
	server := &tsnet.Server{
		Hostname:  hostname,
		AuthKey:   authKey,
		Ephemeral: ephemeral,
		Dir:       stateDir,
	}

	if err := server.Start(); err != nil {
		log.Fatalf("tsnet server error: %v", err)
	}

	// Wait for tsnet to be running
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	for {
		cl, err := server.LocalClient()
		if err == nil {
			status, statusErr := cl.Status(ctx)
			if statusErr != nil {
				log.Printf("Failed to read tsnet status: %v", statusErr)
			} else {
				log.Printf("tsnet connected, state: %v", status.BackendState)
				if status.AuthURL != "" {
					log.Printf("Authorize this node: %s", status.AuthURL)
				}
			}
			break
		}

		select {
		case <-ctx.Done():
			log.Fatalf("Timeout waiting for tsnet to start")
		case <-time.After(500 * time.Millisecond):
		}
	}

	log.Printf("tsnet server started, hostname: %s, state dir: %s", hostname, stateDir)
	if authKey == "" {
		log.Printf("No TS_AUTHKEY set - will require browser authentication on first run")
	}

	// Create SOCKS5 server with custom dialer that routes through tsnet
	socksServer := socks5.NewServer(
		socks5.WithHandshakeTimeout(0), // disable default 10s deadline that kills long-lived connections (SSH KEX)
		socks5.WithDial(func(ctx context.Context, network, address string) (net.Conn, error) {
			// Route all traffic through tsnet - this is the key!
			return server.Dial(ctx, network, address)
		}),
		socks5.WithAllowNoAuth(true), // localhost only, no auth needed
	)

	// Start SOCKS5 listener
	go func() {
		log.Printf("Starting SOCKS5 proxy on %s", socksAddr)
		if err := socksServer.ListenAndServe("tcp", socksAddr); err != nil {
			log.Printf("SOCKS5 server error: %v", err)
		}
	}()

	log.Printf("SOCKS5 proxy listening on %s", socksAddr)

	// Handle graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)
	<-sigChan

	log.Println("Shutting down gracefully...")

	// Graceful SOCKS5 shutdown (allow in-flight requests to complete)
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	if err := socksServer.Shutdown(shutdownCtx); err != nil {
		log.Printf("SOCKS5 shutdown error: %v", err)
	} else {
		log.Println("SOCKS5 server stopped")
	}

	// Close tsnet server
	if err := server.Close(); err != nil {
		log.Printf("tsnet server close error: %v", err)
	} else {
		log.Println("tsnet server closed")
	}

	log.Println("Shutdown complete")
}

// validateSocksAddr ensures the SOCKS5 bind address is localhost only
func validateSocksAddr(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("invalid address format: %w", err)
	}

	// Allow 127.0.0.1, ::1, localhost
	if host == "127.0.0.1" || host == "localhost" || host == "::1" {
		return nil
	}

	// Check for unspecified address (0.0.0.0 or ::)
	if host == "0.0.0.0" || host == "::" || host == "" {
		return fmt.Errorf("refusing to bind to %s (not localhost)", host)
	}

	return fmt.Errorf("refusing to bind to %s (not localhost)", host)
}
