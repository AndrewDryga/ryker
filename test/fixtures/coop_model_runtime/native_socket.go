// This test client uses the actual guard's CONNECT/TLS/WebSocket path. It has
// no provider credentials and never opens a direct provider connection.
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if os.Getenv("CODEX_API_KEY") != "coop-native-codex-v1" {
		return errors.New("unsafe native credential projection")
	}
	proxy, err := url.Parse(os.Getenv("HTTPS_PROXY"))
	if err != nil || proxy.Host == "" {
		return errors.New("native proxy is missing")
	}
	ca, err := os.ReadFile(os.Getenv("SSL_CERT_FILE"))
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		return errors.New("native CA is missing")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.openai.com/v1/responses", nil)
	key := make([]byte, 16)
	if _, err := rand.Read(key); err != nil {
		return err
	}
	challenge := base64.StdEncoding.EncodeToString(key)
	request.Header.Set("Authorization", "Bearer coop-native-codex-v1")
	request.Header.Set("Connection", "Upgrade")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Sec-WebSocket-Version", "13")
	request.Header.Set("Sec-WebSocket-Key", challenge)
	transport := &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}, TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 30 * time.Second}
	response, err := transport.RoundTrip(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	accept := sha1.Sum([]byte(challenge + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	if response.StatusCode != http.StatusSwitchingProtocols || response.Header.Get("Sec-WebSocket-Accept") != base64.StdEncoding.EncodeToString(accept[:]) {
		return fmt.Errorf("native upgrade refused: %d", response.StatusCode)
	}
	socket, ok := response.Body.(io.ReadWriteCloser)
	if !ok {
		return errors.New("native upgrade is not duplex")
	}
	stop := context.AfterFunc(ctx, func() { _ = socket.Close() })
	defer stop()
	if err := writeFrame(socket, 1, []byte(`{"type":"response.create","model":"gpt-6.2-sol","input":"hello"}`)); err != nil {
		return err
	}
	for {
		opcode, payload, err := readFrame(socket)
		if err != nil {
			return err
		}
		switch opcode {
		case 1:
			if strings.Contains(string(payload), "guarded controller reply") {
				fmt.Println("guarded controller reply")
				return nil
			}
		case 8:
			return errors.New("native model socket closed before its response")
		case 9:
			if err := writeFrame(socket, 10, payload); err != nil {
				return err
			}
		case 10:
		default:
			return errors.New("unsupported fixture frame")
		}
	}
}

func writeFrame(writer io.Writer, opcode byte, payload []byte) error {
	if len(payload) > 125 {
		return errors.New("fixture frame is too large")
	}
	mask := make([]byte, 4)
	if _, err := rand.Read(mask); err != nil {
		return err
	}
	frame := append([]byte{0x80 | opcode, 0x80 | byte(len(payload))}, mask...)
	for i, value := range payload {
		frame = append(frame, value^mask[i%4])
	}
	_, err := writer.Write(frame)
	return err
}

func readFrame(reader io.Reader) (byte, []byte, error) {
	var head [2]byte
	if _, err := io.ReadFull(reader, head[:]); err != nil {
		return 0, nil, err
	}
	if head[0]&0x80 == 0 || head[1]&0x80 != 0 {
		return 0, nil, errors.New("invalid server frame")
	}
	size := uint64(head[1] & 0x7f)
	if size == 126 {
		var wide [2]byte
		if _, err := io.ReadFull(reader, wide[:]); err != nil {
			return 0, nil, err
		}
		size = uint64(binary.BigEndian.Uint16(wide[:]))
	}
	if size == 127 {
		var wide [8]byte
		if _, err := io.ReadFull(reader, wide[:]); err != nil {
			return 0, nil, err
		}
		size = binary.BigEndian.Uint64(wide[:])
	}
	if size > 1<<20 {
		return 0, nil, errors.New("fixture response is too large")
	}
	data := make([]byte, int(size))
	_, err := io.ReadFull(reader, data)
	return head[0] & 0x0f, data, err
}
