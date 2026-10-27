package aliyun

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	authserver "github.com/boqinai/CommonLibs/auth_server"
)

// SMSSender delivers authserver.SMSCodes codes through SendSmsVerifyCode
// with an explicit code (TemplateParam {"code":..., "min":...}), so the
// code stays self-managed and CheckSmsVerifyCode is not needed. Works with
// the console's 赠送签名/赠送模板 (template variables ${code} and ${min}).
type SMSSender struct {
	Client       *Client
	SignName     string
	TemplateCode string
	SchemeName   string // optional 方案名称
	CountryCode  string // default "86"
}

func (s *SMSSender) SendCode(ctx context.Context, phone, code string, ttl time.Duration) error {
	mins := int(ttl / time.Minute)
	if mins < 1 {
		mins = 1
	}
	_, err := s.Client.SendSmsVerifyCode(ctx, SmsRequest{
		Phone: phone, SignName: s.SignName, TemplateCode: s.TemplateCode, SchemeName: s.SchemeName,
		CountryCode:   s.CountryCode,
		TemplateParam: map[string]string{"code": code, "min": strconv.Itoa(mins)},
		CodeLength:    len(code), ValidTime: int(ttl / time.Second), Interval: 60,
	})
	return MapSMSError(err)
}

// MapSMSError maps Aliyun error codes to authserver sentinel errors
// (wrapping the original).
func MapSMSError(err error) error {
	code := ErrorCode(err)
	switch {
	case err == nil:
		return nil
	case code == "FREQUENCY_FAIL" || code == "biz.FREQUENCY" || strings.Contains(code, "MINUTE_LIMIT"):
		return errors.Join(authserver.ErrTooFrequent, err)
	case code == "BUSINESS_LIMIT_CONTROL" || strings.Contains(code, "DAY_LIMIT"):
		return errors.Join(authserver.ErrDailyLimit, err)
	case code == "MOBILE_NUMBER_ILLEGAL" || code == "isv.MOBILE_NUMBER_ILLEGAL":
		return errors.Join(authserver.ErrInvalidPhone, err)
	}
	return err
}

// FusionVerifier is an authserver.PhoneVerifier for 融合认证 verify tokens.
type FusionVerifier struct{ Client *Client }

func (f FusionVerifier) VerifyPhone(ctx context.Context, cred authserver.PhoneCredential) (string, error) {
	if cred.Token == "" {
		return "", authserver.ErrVerificationFailed
	}
	phone, err := f.Client.VerifyWithFusionAuthToken(ctx, cred.Token)
	if errors.Is(err, ErrNotPassed) {
		return "", authserver.ErrVerificationFailed
	}
	var api *APIError
	if errors.As(err, &api) && strings.HasPrefix(api.Code, "isv.") {
		// Invalid/expired token reported by Aliyun.
		return "", errors.Join(authserver.ErrVerificationFailed, err)
	}
	return phone, err
}
