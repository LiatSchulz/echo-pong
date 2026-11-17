package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type observedListener struct {
	net.Listener
	closed chan struct{}
	once   sync.Once
}

func (l *observedListener) Close() error {
	err := l.Listener.Close()
	l.once.Do(func() { close(l.closed) })
	return err
}

func TestShutdown(t *testing.T) {
	for _, timeout := range []bool{false, true} {
		name := "drains in-flight request"
		if timeout {
			name = "closes connection after deadline"
		}
		t.Run(name, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			observed := &observedListener{Listener: listener, closed: make(chan struct{})}
			started, release := make(chan struct{}), make(chan struct{})
			defer close(release)
			server := newHTTPServer("0", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				close(started)
				<-release
				io.WriteString(w, "finished")
			}))
			defer server.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			deadline := 2 * time.Second
			if timeout {
				deadline = 30 * time.Millisecond
			}
			done := make(chan error, 1)
			go func() { done <- serve(ctx, server, observed, deadline) }()
			response := make(chan error, 1)
			go func() {
				client := &http.Client{Timeout: 3 * time.Second}
				resp, err := client.Get("http://" + listener.Addr().String())
				if err == nil {
					defer resp.Body.Close()
					var body []byte
					body, err = io.ReadAll(resp.Body)
					if err == nil && string(body) != "finished" {
						err = errors.New("incomplete response")
					}
				}
				response <- err
			}()
			select {
			case <-started:
			case <-time.After(3 * time.Second):
				t.Fatal("request never started")
			}
			cancel()
			select {
			case <-observed.closed:
			case <-time.After(time.Second):
				t.Fatal("shutdown did not stop accepting connections")
			}
			if timeout {
				select {
				case err := <-done:
					if !errors.Is(err, context.DeadlineExceeded) {
						t.Fatalf("expected shutdown deadline, got %v", err)
					}
				case <-time.After(time.Second):
					t.Fatal("shutdown exceeded its deadline")
				}
				if err := <-response; err == nil {
					t.Fatal("expected unfinished connection to be closed")
				}
				return
			}
			select {
			case err := <-done:
				t.Fatalf("shutdown returned before handler completed: %v", err)
			default:
			}
			// Complete the request while shutdown is waiting for it.
			release <- struct{}{}
			if err := <-response; err != nil {
				t.Fatalf("request was interrupted: %v", err)
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestHTTPTimeouts(t *testing.T) {
	server := newHTTPServer("8080", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("incomplete request reached handler")
	}))
	if server.ReadHeaderTimeout <= 0 || server.ReadTimeout <= 0 || server.WriteTimeout <= 0 || server.IdleTimeout <= 0 {
		t.Fatal("all HTTP timeouts must be bounded")
	}
	server.ReadHeaderTimeout = 30 * time.Millisecond
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go server.Serve(listener)
	conn, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(time.Second))
	io.WriteString(conn, "GET /health HTTP/1.1\r\nHost: localhost\r\n")
	_, err = io.ReadAll(conn)
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("server failed to close a connection with incomplete headers")
	}
}

func TestEndpointAuthentication(t *testing.T) {
	secret = "test-token"
	t.Cleanup(func() { secret = "" })
	for _, endpoint := range []struct {
		path    string
		handler http.HandlerFunc
		message string
	}{{"/ping", pingHandler, "pong"}, {"/pong", pongHandler, "ping"}} {
		for _, token := range []string{"", "incorrect", secret, "Bearer " + secret} {
			req := httptest.NewRequest(http.MethodGet, endpoint.path, nil)
			req.Header.Set("Authorization", token)
			response := httptest.NewRecorder()
			authMiddleware(endpoint.handler)(response, req)
			want := http.StatusUnauthorized
			if token == secret || token == "Bearer "+secret {
				want = http.StatusOK
				if !strings.Contains(response.Body.String(), `"message":"`+endpoint.message+`"`) {
					t.Fatalf("unexpected response: %s", response.Body.String())
				}
			}
			if response.Code != want {
				t.Fatalf("%s: got status %d, want %d", endpoint.path, response.Code, want)
			}
		}
	}
	response := httptest.NewRecorder()
	healthHandler(response, httptest.NewRequest(http.MethodGet, "/health", nil))
	if response.Code != http.StatusOK {
		t.Fatal("health endpoint must work without authentication")
	}
}
