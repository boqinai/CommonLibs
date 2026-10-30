package aliyun

import (
	"context"
	"errors"
	authserver "github.com/boqinai/CommonLibs/auth_server"
	"net/url"
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
