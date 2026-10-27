package aliyun

import (
	"context"
	"errors"
	"net/url"
	"testing"
	"time"

	authserver "github.com/boqinai/CommonLibs/auth_server"
)

func TestSMSSenderAndFusionVerifier(t *testing.T) {
	var got url.Values
	c := fake(t, func(v url.Values) any {
		got = v
		switch v.Get("PhoneNumber") {
		case "13000000001":
			return map[string]any{"Code": "FREQUENCY_FAIL"}
		case "13000000002":
			return map[string]any{"Code": "BUSINESS_LIMIT_CONTROL"}
		case "13000000003":
			return map[string]any{"Code": "MOBILE_NUMBER_ILLEGAL"}
		}
		if v.Get("Action") == "VerifyWithFusionAuthToken" {
			if v.Get("VerifyToken") == "expired" {
				return map[string]any{"Code": "isv.TOKEN_EXPIRED"}
			}
			return map[string]any{"Code": "OK", "Model": map[string]string{"PhoneNumber": "13800138000", "VerifyResult": "PASS"}}
		}
		return map[string]any{"Code": "OK", "Model": map[string]string{"BizId": "b"}}
	})
	s := &SMSSender{Client: c, SignName: "Sign", TemplateCode: "T1"}
	ctx := context.Background()
	if err := s.SendCode(ctx, "13800138000", "482913", 5*time.Minute); err != nil {
		t.Fatal(err)
	}
	if got.Get("TemplateParam") != `{"code":"482913","min":"5"}` || got.Get("ValidTime") != "300" || got.Get("SignName") != "Sign" {
		t.Fatal(got)
	}
	for phone, want := range map[string]error{
		"13000000001": authserver.ErrTooFrequent, "13000000002": authserver.ErrDailyLimit, "13000000003": authserver.ErrInvalidPhone,
	} {
		if err := s.SendCode(ctx, phone, "1", time.Minute); !errors.Is(err, want) {
			t.Fatal(phone, err)
		}
	}
	f := FusionVerifier{Client: c}
	if p, err := f.VerifyPhone(ctx, authserver.PhoneCredential{Token: "ok"}); err != nil || p != "13800138000" {
		t.Fatal(p, err)
	}
	for _, tok := range []string{"", "expired"} {
		if _, err := f.VerifyPhone(ctx, authserver.PhoneCredential{Token: tok}); !errors.Is(err, authserver.ErrVerificationFailed) {
			t.Fatal(tok, err)
		}
	}
}
