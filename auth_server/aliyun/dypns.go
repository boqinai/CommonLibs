// Package aliyun is a minimal client for Aliyun 号码认证服务 (dypns,
// API version 2017-05-25): 融合认证 (GetFusionAuthToken,
// VerifyWithFusionAuthToken) and 短信认证 (SendSmsVerifyCode,
// CheckSmsVerifyCode). It has no dependencies beyond the standard library.
//
// Credentials are passed in by the host; this package never reads the
// environment.
package aliyun

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultEndpoint = "https://dypns.aliyuncs.com"
	APIVersion      = "2017-05-25"
)

// ErrNotPassed means a carrier or fusion token did not yield a verified number.
var ErrNotPassed = errors.New("aliyun: verification not passed")

// Client signs dypns RPC requests (signature v1, HMAC-SHA1).
type Client struct {
	AccessKeyID     string
	AccessKeySecret string
	Endpoint        string       // default DefaultEndpoint
	HTTPClient      *http.Client // default 10s timeout
	Now             func() time.Time
}

// APIError is a non-OK dypns response; Code is Aliyun's stable error code
// (e.g. "biz.FREQUENCY", "FREQUENCY_FAIL", "MOBILE_NUMBER_ILLEGAL").
type APIError struct{ Code, Message, RequestID string }

func (e *APIError) Error() string {
	return fmt.Sprintf("aliyun: %s: %s (request %s)", e.Code, e.Message, e.RequestID)
}

// ErrorCode returns the Aliyun error code of err, or "".
func ErrorCode(err error) string {
	var api *APIError
	if errors.As(err, &api) {
		return api.Code
	}
	return ""
}

// FusionTokenRequest configures GetFusionAuthToken. Platform is "Android"
// (PackageName + PackageSign) or "iOS" (BundleID).
type FusionTokenRequest struct {
	SchemeCode      string
	Platform        string
	PackageName     string
	PackageSign     string
	BundleID        string
	DurationSeconds int // default 3600
}

// GetFusionAuthToken returns the SDK init (鉴权) token.
func (c *Client) GetFusionAuthToken(ctx context.Context, r FusionTokenRequest) (string, error) {
	d := r.DurationSeconds
	if d <= 0 {
		d = 3600
	}
	p := map[string]string{"SchemeCode": r.SchemeCode, "Platform": r.Platform, "DurationSeconds": strconv.Itoa(d)}
	switch r.Platform {
	case "Android":
		p["PackageName"], p["PackageSign"] = r.PackageName, r.PackageSign
	case "iOS":
		p["BundleId"] = r.BundleID
	default:
		return "", fmt.Errorf("aliyun: unsupported platform %q", r.Platform)
	}
	var out struct{ Model string }
	if err := c.Call(ctx, "GetFusionAuthToken", p, &out); err != nil {
		return "", err
	}
	if out.Model == "" {
		return "", errors.New("aliyun: empty fusion auth token")
	}
	return out.Model, nil
}

// VerifyWithFusionAuthToken exchanges the SDK's 统一认证Token for the
// verified phone number.
func (c *Client) VerifyWithFusionAuthToken(ctx context.Context, verifyToken string) (string, error) {
	var out struct {
		Model struct{ PhoneNumber, VerifyResult string }
	}
	if err := c.Call(ctx, "VerifyWithFusionAuthToken", map[string]string{"VerifyToken": verifyToken}, &out); err != nil {
		return "", err
	}
	if out.Model.VerifyResult != "PASS" || out.Model.PhoneNumber == "" {
		return "", ErrNotPassed
	}
	return out.Model.PhoneNumber, nil
}

// SmsRequest configures SendSmsVerifyCode. Set TemplateParam["code"] to an
// explicit code to deliver a self-managed code (CheckSmsVerifyCode then
// cannot verify it), or "##code##" to let Aliyun generate one.
type SmsRequest struct {
	Phone         string
	SignName      string
	TemplateCode  string
	TemplateParam map[string]string
	SchemeName    string
	CountryCode   string // default "86"
	CodeLength    int    // default 6
	ValidTime     int    // seconds, default 300
	Interval      int    // seconds, default 60
}

// SendSmsVerifyCode sends a verification SMS and returns Aliyun's BizId.
func (c *Client) SendSmsVerifyCode(ctx context.Context, r SmsRequest) (string, error) {
	param, err := json.Marshal(r.TemplateParam)
	if err != nil {
		return "", err
	}
	p := map[string]string{
		"PhoneNumber":   r.Phone,
		"SignName":      r.SignName,
		"TemplateCode":  r.TemplateCode,
		"TemplateParam": string(param),
		"CountryCode":   or(r.CountryCode, "86"),
		"CodeLength":    strconv.Itoa(orInt(r.CodeLength, 6)),
		"ValidTime":     strconv.Itoa(orInt(r.ValidTime, 300)),
		"Interval":      strconv.Itoa(orInt(r.Interval, 60)),
	}
	if r.SchemeName != "" {
		p["SchemeName"] = r.SchemeName
	}
	var out struct {
		Model struct{ BizId string }
	}
	if err := c.Call(ctx, "SendSmsVerifyCode", p, &out); err != nil {
		return "", err
	}
	return out.Model.BizId, nil
}

// CheckSmsVerifyCode verifies an Aliyun-generated code ("PASS").
func (c *Client) CheckSmsVerifyCode(ctx context.Context, phone, code, schemeName, countryCode string) (bool, error) {
	p := map[string]string{"PhoneNumber": phone, "VerifyCode": code, "CountryCode": or(countryCode, "86")}
	if schemeName != "" {
		p["SchemeName"] = schemeName
	}
	var out struct {
		Model struct{ VerifyResult string }
	}
	if err := c.Call(ctx, "CheckSmsVerifyCode", p, &out); err != nil {
		return false, err
	}
	return out.Model.VerifyResult == "PASS", nil
}

// Call performs any dypns RPC action and decodes the JSON body into out.
func (c *Client) Call(ctx context.Context, action string, params map[string]string, out any) error {
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	q := map[string]string{
		"AccessKeyId":      c.AccessKeyID,
		"Action":           action,
		"Format":           "JSON",
		"SignatureMethod":  "HMAC-SHA1",
		"SignatureNonce":   hex.EncodeToString(nonce),
		"SignatureVersion": "1.0",
		"Timestamp":        now().UTC().Format("2006-01-02T15:04:05Z"),
		"Version":          APIVersion,
	}
	for k, v := range params {
		q[k] = v
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimRight(or(c.Endpoint, DefaultEndpoint), "/")+"/", strings.NewReader(Sign(q, c.AccessKeySecret)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	hc := c.HTTPClient
	if hc == nil {
		hc = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	var head struct{ Code, Message, RequestId string }
	if err := json.Unmarshal(raw, &head); err != nil {
		return fmt.Errorf("aliyun: bad response (HTTP %d): %w", resp.StatusCode, err)
	}
	if head.Code != "OK" {
		return &APIError{Code: head.Code, Message: head.Message, RequestID: head.RequestId}
	}
	return json.Unmarshal(raw, out)
}

// Sign returns the form body (canonical query + Signature) for a POST RPC.
func Sign(params map[string]string, secret string) string {
	canonical, sig := sign("POST", params, secret)
	return canonical + "&Signature=" + percentEncode(sig)
}

func sign(method string, params map[string]string, secret string) (string, string) {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = percentEncode(k) + "=" + percentEncode(params[k])
	}
	canonical := strings.Join(parts, "&")
	mac := hmac.New(sha1.New, []byte(secret+"&"))
	mac.Write([]byte(method + "&" + percentEncode("/") + "&" + percentEncode(canonical)))
	return canonical, base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func percentEncode(s string) string {
	e := url.QueryEscape(s)
	e = strings.ReplaceAll(e, "+", "%20")
	e = strings.ReplaceAll(e, "*", "%2A")
	return strings.ReplaceAll(e, "%7E", "~")
}

func or(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func orInt(v, def int) int {
	if v <= 0 {
		return def
	}
	return v
}
