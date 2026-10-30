package aliyun

import (
	"context"
	"errors"
	authserver "github.com/boqinai/CommonLibs/auth_server"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

func TestGetMobile(t *testing.T) {
	calls := 0
	c := fake(t, func(v url.Values) any {
		calls++
		if v.Get("Action") != "GetMobile" || v.Get("AccessToken") == "" || v.Has("VerifyToken") {
			t.Error("wrong token API")
		}
		switch v.Get("AccessToken") {
		case "authorized":
			return map[string]any{"Code": "OK", "GetMobileResultDTO": map[string]string{"Mobile": "13800001111"}}
		case "empty":
			return map[string]any{"Code": "OK", "GetMobileResultDTO": map[string]string{}}
		default:
			return map[string]any{"Code": "RamPermissionDeny", "Message": "rejected"}
		}
	})
	ctx := context.Background()
	if phone, err := c.GetMobile(ctx, "authorized"); err != nil || phone != "13800001111" {
		t.Fatal(phone, err)
	}
	before := calls
	for _, token := range []string{"", "  "} {
		if _, err := c.GetMobile(ctx, token); !errors.Is(err, ErrNotPassed) {
			t.Fatal(err)
		}
	}
	if calls != before {
		t.Fatal("empty tokens must not reach the provider")
	}
	if _, err := c.GetMobile(ctx, "empty"); !errors.Is(err, ErrNotPassed) {
		t.Fatal(err)
	}
	if _, err := c.GetMobile(ctx, "rejected"); ErrorCode(err) != "RamPermissionDeny" {
		t.Fatal("upstream API error not preserved")
	}
	verifier := CarrierVerifier{Client: c}
	if phone, err := verifier.VerifyPhone(ctx, authserver.PhoneCredential{Token: "authorized"}); err != nil || phone != "13800001111" {
		t.Fatal(phone, err)
	}
	if _, err := verifier.VerifyPhone(ctx, authserver.PhoneCredential{Token: "empty"}); !errors.Is(err, authserver.ErrVerificationFailed) {
		t.Fatal(err)
	}
	if _, err := verifier.VerifyPhone(ctx, authserver.PhoneCredential{Token: "rejected"}); ErrorCode(err) != "RamPermissionDeny" {
		t.Fatal(err)
	}
}

func TestCarrierCredentialErrorsAreNotServiceFailures(t *testing.T) {
	for _, code := range []string{"isv.TOKEN_INVALID", "isv.TOKEN_UNAUTHORIZED_USED"} {
		t.Run(code, func(t *testing.T) {
			c := fake(t, func(v url.Values) any { return map[string]any{"Code": code, "Message": "provider detail"} })
			_, err := c.GetMobile(context.Background(), "expired")
			if !errors.Is(err, ErrNotPassed) || ErrorCode(err) != code {
				t.Fatal("credential classification or provider diagnostics lost")
			}
			_, err = (CarrierVerifier{Client: c}).VerifyPhone(context.Background(), authserver.PhoneCredential{Token: "expired"})
			if !errors.Is(err, authserver.ErrVerificationFailed) || strings.Contains(err.Error(), "provider detail") {
				t.Fatal("not a sanitized authentication rejection")
			}
		})
	}
	for _, code := range []string{"isv.RAM_PERMISSION_DENY", "isv.VERIFY_SCHEME_NOT_EXIST", "isv.OUT_OF_SERVICE", "isp.SYSTEM_ERROR"} {
		t.Run(code, func(t *testing.T) {
			c := fake(t, func(v url.Values) any { return map[string]any{"Code": code} })
			_, err := (CarrierVerifier{Client: c}).VerifyPhone(context.Background(), authserver.PhoneCredential{Token: "token"})
			if errors.Is(err, authserver.ErrVerificationFailed) || ErrorCode(err) != code {
				t.Fatal("configuration/service failure must not look like a bad credential")
			}
		})
	}
}

type carrierTransport func(*http.Request) (*http.Response, error)

func (f carrierTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestGetMobileDefaultEndpointDoesNotMutateClient(t *testing.T) {
	c := &Client{AccessKeyID: "id", AccessKeySecret: "key", HTTPClient: &http.Client{Transport: carrierTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Scheme+"://"+r.URL.Host != CarrierEndpoint {
			t.Fatal("wrong carrier endpoint")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"Code":"OK","GetMobileResultDTO":{"Mobile":"13800001111"}}`)), Header: make(http.Header)}, nil
	})}}
	if _, err := c.GetMobile(context.Background(), "token"); err != nil {
		t.Fatal(err)
	}
	if c.Endpoint != "" {
		t.Fatal("shared client was mutated")
	}
}
