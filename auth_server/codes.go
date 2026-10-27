package authserver

// Stable HTTP error "code" strings. auth_client's AuthErrorCode uses the
// same values. Do not rename them; SMS and fusion URL paths are a separate
// contract and must stay as they are.
//
// Client-only codes (never produced here): invalid_response, network_failure.
const (
	CodeInvalidRequest           = "invalid_request"
	CodeInvalidCredentialsFormat = "invalid_credentials_format"
	CodePhoneAlreadyRegistered   = "phone_already_registered"
	CodeInvalidCredentials       = "invalid_credentials"
	CodeUnauthorized             = "unauthorized"
	CodeUserNotFound             = "user_not_found"
	CodeMethodNotAllowed         = "method_not_allowed"
	CodeInternalError            = "internal_error"
	CodeProfileNotSupported      = "profile_not_supported"
	CodeInvalidPhone             = "invalid_phone"
	CodeVerificationFailed       = "verification_failed"
	CodeSMSTooFrequent           = "sms_too_frequent"
	CodeSMSDailyLimit            = "sms_daily_limit"
	CodeTooManyRequests          = "too_many_requests"
	CodeSMSUnavailable           = "sms_unavailable"
	CodeVerificationUnavailable  = "verification_unavailable"
	CodeUnsupportedPlatform      = "unsupported_platform"
	CodeInvalidRefreshToken      = "invalid_refresh_token"
)
