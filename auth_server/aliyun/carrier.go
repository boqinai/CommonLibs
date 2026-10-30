package aliyun

import (
	"context"
	"errors"
	authserver "github.com/boqinai/CommonLibs/auth_server"
	"strings"
)

// CarrierEndpoint is the default PNVS endpoint for standalone GetMobile.
const CarrierEndpoint = "https://dypnsapi.aliyuncs.com"

// GetMobile exchanges the login token produced AFTER the SDK authorization
// page's explicit user consent. Unlike VerifyWithFusionAuthToken, this is the
// standalone carrier API and sends AccessToken, not VerifyToken.
func (c *Client) GetMobile(ctx context.Context, token string) (string, error) {
	if strings.TrimSpace(token) == "" {
		return "", ErrNotPassed
	}
	var out struct{ GetMobileResultDTO struct{ Mobile string } }
	// Keep other methods' legacy endpoint behavior and avoid mutating a
	// shared client while another goroutine performs SMS/fusion requests.
	client := *c
	if client.Endpoint == "" {
		client.Endpoint = CarrierEndpoint
	}
	if err := client.Call(ctx, "GetMobile", map[string]string{"AccessToken": token}, &out); err != nil {
		switch ErrorCode(err) {
		case "isv.TOKEN_INVALID", "isv.TOKEN_UNAUTHORIZED_USED":
			return "", errors.Join(ErrNotPassed, err)
		}
		return "", err
	}
	if out.GetMobileResultDTO.Mobile == "" {
		return "", ErrNotPassed
	}
	return out.GetMobileResultDTO.Mobile, nil
}

// CarrierVerifier adapts the standalone API to a host's PhoneVerifier flow.
// It does not select a provider, create users, issue sessions or load secrets.
type CarrierVerifier struct{ Client *Client }

func (v CarrierVerifier) VerifyPhone(ctx context.Context, credential authserver.PhoneCredential) (string, error) {
	phone, err := v.Client.GetMobile(ctx, credential.Token)
	if errors.Is(err, ErrNotPassed) {
		return "", authserver.ErrVerificationFailed
	}
	return phone, err
}
