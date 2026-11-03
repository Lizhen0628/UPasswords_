package api

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"net/mail"
	"strings"
	"testing"
	"time"
)

func TestExistingWireEncryptionVector(t *testing.T) {
	s := &Server{Config: Config{KEK: bytes.Repeat([]byte{17}, 32)}}
	raw, err := s.open(sql.NullString{String: "v1.IiIiIiIiIiIiIiIidIVoOrPi8z6LWKtdL8PJs3bruZcY5FbVZfAkIqNMmLYfYsD43SY=", Valid: true})
	if err != nil || string(raw) != "cross-language fixture" {
		t.Fatal("Node AES-GCM fixture incompatible")
	}
}
func TestEmailValidationAndReplyRouting(t *testing.T) {
	for _, v := range []string{"alice@example.com", "user+tag@sub.example.com", "USER@EXAMPLE.COM"} {
		if _, e := email(v); e != nil {
			t.Errorf("valid email rejected: %s", v)
		}
	}
	for _, v := range []string{"user@exampleXcom", "x\\@example.com", "x@example.com\r\nBCC: victim@example.com"} {
		if _, e := email(v); e == nil {
			t.Error("invalid email accepted")
		}
	}
	c := Config{
		SMTPFrom:            "fallback@upasswords.com",
		SMTPRegisterFrom:    "register@upasswords.com",
		SMTPVerifyFrom:      "verify@upasswords.com",
		SMTPRegisterReplyTo: "register@upasswords.com",
		SMTPVerifyReplyTo:   "verify@upasswords.com",
	}
	for _, p := range []string{"register", "login", "sensitive"} {
		msg, err := verificationMessage(c, "user@example.com", "123456", p, false)
		if err != nil {
			t.Fatal(err)
		}
		want := c.SMTPVerifyReplyTo
		wantFrom := c.SMTPVerifyFrom
		if p == "register" {
			want = c.SMTPRegisterReplyTo
			wantFrom = c.SMTPRegisterFrom
		}
		if !strings.Contains(msg, "Reply-To: "+want) || !strings.Contains(msg, "From: "+wantFrom) || mailFrom(c, p) != wantFrom {
			t.Error("incorrect sender or reply address")
		}
	}
}
func TestMaintenanceSchedule(t *testing.T) {
	ts := time.Date(2026, 10, 23, 4, 0, 0, 0, time.UTC)
	if nextMaintenance(ts) != ts.Add(24*time.Hour) {
		t.Fatal("schedule must advance at boundary")
	}
	if nextMaintenance(ts.Add(-time.Minute)) != ts {
		t.Fatal("schedule before boundary")
	}
}

func TestVerificationMailLanguageAndPurpose(t *testing.T) {
	for _, zh := range []bool{false, true} {
		for _, purpose := range []string{"register", "login", "sensitive"} {
			rawMessage, err := verificationMessage(Config{SMTPFrom: "sender@example.com"}, "user@example.com", "123456", purpose, zh)
			if err != nil {
				t.Fatal(err)
			}
			message, err := mail.ReadMessage(strings.NewReader(rawMessage))
			if err != nil {
				t.Fatal(err)
			}
			subject, err := new(mime.WordDecoder).DecodeHeader(message.Header.Get("Subject"))
			if err != nil {
				t.Fatal(err)
			}
			wantSubject := "Your UPasswords sign-in code"
			if purpose == "register" {
				wantSubject = "Verify your UPasswords account"
			} else if purpose == "sensitive" {
				wantSubject = "Confirm a UPasswords security action"
			}
			if zh {
				wantSubject = "你的 UPasswords 登录验证码"
				if purpose == "register" {
					wantSubject = "验证你的 UPasswords 账户"
				} else if purpose == "sensitive" {
					wantSubject = "确认 UPasswords 安全操作"
				}
			}
			mediaType, params, err := mime.ParseMediaType(message.Header.Get("Content-Type"))
			if err != nil {
				t.Fatal(err)
			}
			if mediaType != "multipart/alternative" {
				t.Fatalf("unexpected content type: %s", mediaType)
			}
			parts := multipart.NewReader(message.Body, params["boundary"])
			contents := make(map[string]string)
			for {
				part, err := parts.NextPart()
				if err == io.EOF {
					break
				}
				if err != nil {
					t.Fatal(err)
				}
				partType, _, err := mime.ParseMediaType(part.Header.Get("Content-Type"))
				if err != nil {
					t.Fatal(err)
				}
				if part.Header.Get("Content-Transfer-Encoding") != "base64" {
					t.Fatalf("unexpected transfer encoding: %s", part.Header.Get("Content-Transfer-Encoding"))
				}
				body, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, part))
				if err != nil {
					t.Fatal(err)
				}
				contents[partType] = string(body)
			}
			plain := contents["text/plain"]
			html := contents["text/html"]
			wantExpiry := "10 minutes"
			wantHeading := "Sign in to UPasswords"
			if purpose == "register" {
				wantHeading = "Verify your email address"
			} else if purpose == "sensitive" {
				wantHeading = "Confirm this security action"
			}
			if zh {
				wantExpiry = "10 分钟后失效"
				wantHeading = "登录 UPasswords"
				if purpose == "register" {
					wantHeading = "验证你的邮箱"
				} else if purpose == "sensitive" {
					wantHeading = "确认安全操作"
				}
			}
			if subject != wantSubject || !strings.Contains(plain, "123456") || !strings.Contains(plain, wantExpiry) ||
				!strings.Contains(html, "123456") || !strings.Contains(html, wantExpiry) || !strings.Contains(html, wantHeading) ||
				!strings.Contains(html, "contact@upasswords.com") {
				t.Fatalf("mail content mismatch for zh=%v purpose=%s: %q", zh, purpose, subject)
			}
		}
	}
}

func TestVerificationMailEscapesHTMLCode(t *testing.T) {
	rawMessage, err := verificationMessage(Config{SMTPFrom: "sender@example.com"}, "user@example.com", "<script>alert(1)</script>", "login", false)
	if err != nil {
		t.Fatal(err)
	}
	message, err := mail.ReadMessage(strings.NewReader(rawMessage))
	if err != nil {
		t.Fatal(err)
	}
	_, params, err := mime.ParseMediaType(message.Header.Get("Content-Type"))
	if err != nil {
		t.Fatal(err)
	}
	parts := multipart.NewReader(message.Body, params["boundary"])
	for {
		part, err := parts.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		partType, _, err := mime.ParseMediaType(part.Header.Get("Content-Type"))
		if err != nil {
			t.Fatal(err)
		}
		if partType != "text/html" {
			continue
		}
		body, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, part))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(body), "<script>alert(1)</script>") || !strings.Contains(string(body), "&lt;script&gt;alert(1)&lt;/script&gt;") {
			t.Fatal("HTML body did not escape dynamic code")
		}
		return
	}
	t.Fatal("HTML alternative is missing")
}

func TestCanonicalVersionedRoutes(t *testing.T) {
	s := &Server{Log: slog.New(slog.NewJSONHandler(io.Discard, nil))}
	h := s.Handler()
	for _, path := range []string{"/v1/"} {
		status, body := call(t, h, "GET", path, "", nil)
		if status != 200 || body["version"] != float64(syncProtocolVersion) {
			t.Errorf("capability route %s returned %d", path, status)
		}
		capabilities := body["capabilities"].([]any)
		found := map[string]bool{}
		for _, capability := range capabilities {
			found[capability.(string)] = true
		}
		if !found["vaults.row_sync"] || !found["vaults.conflicts"] || !found["breach.range"] {
			t.Errorf("capability route %s omitted row-sync capabilities: %v", path, capabilities)
		}
	}
	status, body := call(t, h, "GET", "/v2/", "", nil)
	if status != 404 || body["error"] != "not_found" {
		t.Errorf("legacy route returned %d: %v", status, body)
	}
	status, body = call(t, h, "GET", "/v2/vaults", "", nil)
	if status != 404 || body["error"] != "not_found" {
		t.Errorf("legacy protected route returned %d: %v", status, body)
	}
	for _, path := range []string{"/v1/vaults"} {
		status, _ := call(t, h, "GET", path, "", nil)
		if status != 401 {
			t.Errorf("protected route %s returned %d without a token", path, status)
		}
	}
}
