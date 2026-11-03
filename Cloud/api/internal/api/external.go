// 对象存储和邮件传输适配；处理器经接口注入，测试不触发真实邮件。
package api

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"html/template"
	"io"
	"mime/multipart"
	"net"
	"net/smtp"
	"net/textproto"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
)

// Object is metadata for an encrypted blob or public catalog icon.
type Object struct {
	Key, ContentType string
	ETag             string
	Size             int64
	Modified         time.Time
}

// ObjectStore abstracts R2 via its standard S3 API for isolated integration tests.
type ObjectStore interface {
	Put(context.Context, string, []byte, string) error
	Get(context.Context, string) (io.ReadCloser, Object, error)
	Delete(context.Context, string) error
	List(context.Context, string, string) ([]Object, string, error)
}

// S3Store implements the object-store boundary using the configured R2 S3 endpoint.
type S3Store struct {
	Client *s3.Client
	Bucket string
}

// NewS3 creates an R2 client from validated configuration; credentials must never be logged.
func NewS3(c Config) *S3Store {
	return &S3Store{Client: s3.NewFromConfig(aws.Config{Region: "auto", Credentials: credentials.NewStaticCredentialsProvider(c.R2AccessKey, c.R2SecretKey, "")}, func(o *s3.Options) { o.BaseEndpoint = aws.String(c.R2Endpoint) }), Bucket: c.R2Bucket}
}

// Put writes one object under the supplied key without interpreting encrypted payload bytes.
func (s *S3Store) Put(ctx context.Context, key string, b []byte, mime string) error {
	_, e := s.Client.PutObject(ctx, &s3.PutObjectInput{Bucket: &s.Bucket, Key: &key, Body: bytes.NewReader(b), ContentType: &mime})
	return e
}

// Get opens an object stream; the caller owns closing the returned io.ReadCloser.
func (s *S3Store) Get(ctx context.Context, key string) (io.ReadCloser, Object, error) {
	v, e := s.Client.GetObject(ctx, &s3.GetObjectInput{Bucket: &s.Bucket, Key: &key})
	if e != nil {
		var a smithy.APIError
		if errors.As(e, &a) && (a.ErrorCode() == "NoSuchKey" || a.ErrorCode() == "NotFound") {
			return nil, Object{}, fail(404, "not_found")
		}
		return nil, Object{}, e
	}
	return v.Body, Object{
		Key: key, ETag: aws.ToString(v.ETag), Size: aws.ToInt64(v.ContentLength),
		ContentType: aws.ToString(v.ContentType), Modified: aws.ToTime(v.LastModified),
	}, nil
}

// Delete removes an object key; database references must be coordinated separately.
func (s *S3Store) Delete(ctx context.Context, key string) error {
	_, e := s.Client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &s.Bucket, Key: &key})
	return e
}

// List returns one object page and continuation token; callers must follow the token to exhaust a prefix.
func (s *S3Store) List(ctx context.Context, prefix, cursor string) ([]Object, string, error) {
	in := &s3.ListObjectsV2Input{Bucket: &s.Bucket, Prefix: &prefix}
	if cursor != "" {
		in.ContinuationToken = &cursor
	}
	v, e := s.Client.ListObjectsV2(ctx, in)
	if e != nil {
		return nil, "", e
	}
	out := []Object{}
	for _, o := range v.Contents {
		out = append(out, Object{
			Key: aws.ToString(o.Key), ETag: aws.ToString(o.ETag),
			Size: aws.ToInt64(o.Size), Modified: aws.ToTime(o.LastModified),
		})
	}
	return out, aws.ToString(v.NextContinuationToken), nil
}

// deletePrefix exhausts object-store pagination while deleting a vault-scoped prefix.
func (s *Server) deletePrefix(ctx context.Context, prefix string) error {
	cursor := ""
	for {
		objects, next, e := s.Objects.List(ctx, prefix, cursor)
		if e != nil {
			return e
		}
		for _, o := range objects {
			if e = s.Objects.Delete(ctx, o.Key); e != nil {
				return e
			}
		}
		if next == "" {
			return nil
		}
		if next == cursor {
			return errors.New("object listing made no progress")
		}
		cursor = next
	}
}

// Mailer sends verification mail; production has no mock-code environment switch.
type Mailer interface {
	Send(context.Context, string, string, string, bool) error
}

// SMTPMailer delivers verification mail over authenticated TLS using purpose-specific reply addresses.
type SMTPMailer struct{ Config Config }

var verificationHTMLTemplate = template.Must(template.New("verification-email").Parse(`<!doctype html>
<html lang="{{.Language}}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{.Heading}}</title>
</head>
<body style="margin:0;padding:0;background:#f3f6f8;color:#15232d;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;">
  <div style="display:none;max-height:0;overflow:hidden;opacity:0;">{{.Preheader}}</div>
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background:#f3f6f8;">
    <tr>
      <td align="center" style="padding:40px 16px;">
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:560px;background:#ffffff;border:1px solid #e2e8ec;border-radius:12px;">
          <tr>
            <td style="padding:30px 36px 22px;border-bottom:1px solid #edf1f3;">
              <div style="font-size:20px;line-height:28px;font-weight:700;color:#153d35;">UPasswords</div>
              <div style="padding-top:4px;font-size:13px;line-height:20px;color:#60716f;">{{.Tagline}}</div>
            </td>
          </tr>
          <tr>
            <td style="padding:32px 36px 36px;">
              <h1 style="margin:0 0 12px;font-size:23px;line-height:31px;font-weight:650;color:#17252e;">{{.Heading}}</h1>
              <p style="margin:0 0 24px;font-size:15px;line-height:24px;color:#46565e;">{{.Intro}}</p>
              <div style="margin:0 0 10px;font-size:12px;line-height:18px;font-weight:600;color:#60716f;">{{.CodeLabel}}</div>
              <div style="padding:18px 20px;background:#f4f8f7;border:1px solid #dce9e5;border-radius:8px;text-align:center;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:32px;line-height:40px;font-weight:700;letter-spacing:6px;color:#145b49;">{{.Code}}</div>
              <p style="margin:14px 0 0;font-size:13px;line-height:21px;color:#53636a;">{{.Expiry}}</p>
              <p style="margin:20px 0 0;padding-top:18px;border-top:1px solid #edf1f3;font-size:13px;line-height:21px;color:#53636a;">{{.SecurityNote}}</p>
              <p style="margin:14px 0 0;font-size:13px;line-height:21px;color:#53636a;">{{.IgnoreNote}}</p>
            </td>
          </tr>
        </table>
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:560px;">
          <tr>
            <td align="center" style="padding:20px 12px 0;font-size:12px;line-height:19px;color:#718087;">
              {{.Footer}}<br>
              <a href="mailto:contact@upasswords.com" style="color:#315f55;text-decoration:underline;">contact@upasswords.com</a>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`))

type verificationMailCopy struct {
	Language, Tagline, Preheader, Heading, Intro, CodeLabel string
	Expiry, SecurityNote, IgnoreNote, Footer                string
}

// Send transmits one purpose-scoped verification message; recipient, code and credentials are never log fields.
func (m SMTPMailer) Send(ctx context.Context, to, code, purpose string, zh bool) error {
	c := m.Config
	message, e := verificationMessage(c, to, code, purpose, zh)
	if e != nil {
		return e
	}
	d := net.Dialer{Timeout: 10 * time.Second}
	tlsDial := tls.Dialer{NetDialer: &d, Config: &tls.Config{ServerName: c.SMTPHost, MinVersion: tls.VersionTLS12}}
	conn, e := tlsDial.DialContext(ctx, "tcp", net.JoinHostPort(c.SMTPHost, c.SMTPPort))
	if e != nil {
		return e
	}
	defer conn.Close()
	deadline := time.Now().Add(15 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	if e = conn.SetDeadline(deadline); e != nil {
		return e
	}
	client, e := smtp.NewClient(conn, c.SMTPHost)
	if e != nil {
		return e
	}
	defer client.Close()
	if e = client.Auth(smtp.PlainAuth("", c.SMTPUser, c.SMTPPassword, c.SMTPHost)); e != nil {
		return e
	}
	if e = client.Mail(mailFrom(c, purpose)); e != nil {
		return e
	}
	if e = client.Rcpt(to); e != nil {
		return e
	}
	w, e := client.Data()
	if e != nil {
		return e
	}
	if _, e = io.WriteString(w, message); e != nil {
		return e
	}
	if e = w.Close(); e != nil {
		return e
	}
	return client.Quit()
}

// verificationMessage builds a localized multipart email with plain-text and HTML alternatives.
func verificationMessage(c Config, to, code, purpose string, zh bool) (string, error) {
	subject, copy := verificationMailContent(purpose, zh)
	htmlBody, err := renderVerificationHTML(copy, code)
	if err != nil {
		return "", err
	}
	textBody := renderVerificationText(copy, code)

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writeMailPart(writer, "text/plain; charset=UTF-8", textBody); err != nil {
		return "", err
	}
	if err := writeMailPart(writer, "text/html; charset=UTF-8", htmlBody); err != nil {
		return "", err
	}
	boundary := writer.Boundary()
	if err := writer.Close(); err != nil {
		return "", err
	}

	// All dynamic addresses come from strict validation/config; forbid header injection as a second boundary.
	clean := func(v string) string { return strings.NewReplacer("\r", "", "\n", "").Replace(v) }
	return fmt.Sprintf("From: %s\r\nReply-To: %s\r\nTo: %s\r\nSubject: =?UTF-8?B?%s?=\r\nDate: %s\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"%s\"\r\n\r\n%s", clean(mailFrom(c, purpose)), clean(mailReplyTo(c, purpose)), clean(to), base64.StdEncoding.EncodeToString([]byte(subject)), time.Now().Format(time.RFC1123Z), boundary, body.String()), nil
}

func verificationMailContent(purpose string, zh bool) (string, verificationMailCopy) {
	copy := verificationMailCopy{
		Language:     "en",
		Tagline:      "Secure access to your digital life",
		CodeLabel:    "YOUR ONE-TIME CODE",
		Expiry:       "This code expires in 10 minutes.",
		SecurityNote: "For your protection, never share this code with anyone. UPasswords support will never ask you for it.",
		IgnoreNote:   "If you did not request this email, you can safely ignore it. No changes will be made to your account.",
		Footer:       "UPasswords helps you manage account access with confidence.",
	}

	switch purpose {
	case "register":
		copy.Preheader = "Complete your UPasswords account registration."
		copy.Heading = "Verify your email address"
		copy.Intro = "Enter this one-time code to verify your email and complete your UPasswords registration."
		if zh {
			copy = chineseVerificationMailCopy("完成 UPasswords 账户注册。", "验证你的邮箱", "输入此验证码以验证邮箱并完成 UPasswords 账户注册。", "账户注册验证码")
			return "验证你的 UPasswords 账户", copy
		}
		return "Verify your UPasswords account", copy
	case "sensitive":
		copy.Preheader = "Confirm a security action on your UPasswords account."
		copy.Heading = "Confirm this security action"
		copy.Intro = "Enter this one-time code to authorize the security-sensitive action requested for your account."
		if zh {
			copy = chineseVerificationMailCopy("确认 UPasswords 账户的一项安全操作。", "确认安全操作", "输入此验证码以授权你发起的账户敏感操作。", "安全操作验证码")
			return "确认 UPasswords 安全操作", copy
		}
		return "Confirm a UPasswords security action", copy
	default:
		copy.Preheader = "Your secure sign-in code for UPasswords."
		copy.Heading = "Sign in to UPasswords"
		copy.Intro = "Enter this one-time code to securely sign in to your UPasswords account."
		if zh {
			copy = chineseVerificationMailCopy("你的 UPasswords 安全登录验证码。", "登录 UPasswords", "输入此验证码以安全登录你的 UPasswords 账户。", "登录验证码")
			return "你的 UPasswords 登录验证码", copy
		}
		return "Your UPasswords sign-in code", copy
	}
}

func chineseVerificationMailCopy(preheader, heading, intro, codeLabel string) verificationMailCopy {
	return verificationMailCopy{
		Language:     "zh-CN",
		Tagline:      "安全管理密码，安心访问数字生活",
		Preheader:    preheader,
		Heading:      heading,
		Intro:        intro,
		CodeLabel:    codeLabel,
		Expiry:       "此验证码将在 10 分钟后失效。",
		SecurityNote: "为保障账户安全，请勿向任何人透露此验证码。UPasswords 客服不会向你索取验证码。",
		IgnoreNote:   "如果你没有发起此操作，请忽略本邮件。你的账户不会因此发生更改。",
		Footer:       "UPasswords 助你安心管理账户访问与密码。",
	}
}

func renderVerificationText(copy verificationMailCopy, code string) string {
	return fmt.Sprintf("UPasswords\n%s\n\n%s\n\n%s\n\n%s\n%s\n\n%s\n\n%s\n\n%s\ncontact@upasswords.com\n", copy.Tagline, copy.Heading, copy.Intro, copy.CodeLabel, code, copy.Expiry, copy.SecurityNote, copy.IgnoreNote+"\n"+copy.Footer)
}

func renderVerificationHTML(copy verificationMailCopy, code string) (string, error) {
	var body bytes.Buffer
	data := struct {
		verificationMailCopy
		Code string
	}{verificationMailCopy: copy, Code: code}
	if err := verificationHTMLTemplate.Execute(&body, data); err != nil {
		return "", err
	}
	return body.String(), nil
}

func writeMailPart(writer *multipart.Writer, contentType, content string) error {
	header := make(textproto.MIMEHeader)
	header.Set("Content-Type", contentType)
	header.Set("Content-Transfer-Encoding", "base64")
	part, err := writer.CreatePart(header)
	if err != nil {
		return err
	}
	encoder := base64.NewEncoder(base64.StdEncoding, part)
	if _, err = io.WriteString(encoder, content); err != nil {
		return err
	}
	return encoder.Close()
}

// mailFrom routes registration mail and other verification mail from their configured addresses.
func mailFrom(c Config, purpose string) string {
	if purpose == "register" && c.SMTPRegisterFrom != "" {
		return c.SMTPRegisterFrom
	}
	if purpose != "register" && c.SMTPVerifyFrom != "" {
		return c.SMTPVerifyFrom
	}
	return c.SMTPFrom
}

// mailReplyTo routes replies by registration or verification purpose.
func mailReplyTo(c Config, purpose string) string {
	if purpose == "register" && c.SMTPRegisterReplyTo != "" {
		return c.SMTPRegisterReplyTo
	}
	if c.SMTPVerifyReplyTo != "" {
		return c.SMTPVerifyReplyTo
	}
	return c.SMTPReplyTo
}
