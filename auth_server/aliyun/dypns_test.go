package aliyun

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

// Example from Aliyun's RPC signature documentation.
func TestSignMatchesAliyunExample(t *testing.T) {
	params := map[string]string{
		"AccessKeyId": "testid", "Action": "DescribeRegions", "Format": "XML",
		"SignatureMethod": "HMAC-SHA1", "SignatureNonce": "3ee8c1b8-83d3-44af-a94f-4e0ad82fd6cf",
		"SignatureVersion": "1.0", "Timestamp": "2016-02-23T12:46:24Z", "Version": "2014-05-26",
	}
	if _, sig := sign("GET", params, "testsecret"); sig != "OLeaidS1JvxuMvnyHOwuJ+uX5qY=" {
		t.Fatalf("signature %s", sig)
	}
	v, err := url.ParseQuery(Sign(params, "testsecret"))
	if err != nil || v.Get("Signature") == "" || v.Get("Action") != "DescribeRegions" {
		t.Fatalf("bad body %v %v", v, err)
	}
}

func fake(t *testing.T, handle func(url.Values) any) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		if r.PostForm.Get("Signature") == "" || r.PostForm.Get("AccessKeyId") != "id" || r.PostForm.Get("Version") != APIVersion {
			t.Errorf("unsigned request %v", r.PostForm)
		}
		_ = json.NewEncoder(w).Encode(handle(r.PostForm))
	}))
	t.Cleanup(srv.Close)
	return &Client{AccessKeyID: "id", AccessKeySecret: "secret", Endpoint: srv.URL}
}

func TestFusion(t *testing.T) {
	c := fake(t, func(v url.Values) any {
		switch v.Get("Action") {
		case "GetFusionAuthToken":
			if v.Get("Platform") == "iOS" && v.Get("BundleId") != "b" || v.Get("Platform") == "Android" && v.Get("PackageSign") != "s" {
				return map[string]any{"Code": "isv.INVALID"}
			}
			return map[string]any{"Code": "OK", "Model": "tok-" + v.Get("SchemeCode")}
		case "VerifyWithFusionAuthToken":
			if v.Get("VerifyToken") == "good" {
				return map[string]any{"Code": "OK", "Model": map[string]string{"PhoneNumber": "13800138000", "VerifyResult": "PASS"}}
			}
			return map[string]any{"Code": "OK", "Model": map[string]string{"VerifyResult": "UNKNOWN"}}
		}
		return map[string]any{"Code": "Unknown"}
	})
	ctx := context.Background()
	if tok, err := c.GetFusionAuthToken(ctx, FusionTokenRequest{SchemeCode: "S", Platform: "Android", PackageName: "p", PackageSign: "s"}); err != nil || tok != "tok-S" {
		t.Fatal(tok, err)
	}
	if tok, err := c.GetFusionAuthToken(ctx, FusionTokenRequest{SchemeCode: "I", Platform: "iOS", BundleID: "b"}); err != nil || tok != "tok-I" {
		t.Fatal(tok, err)
	}
	if _, err := c.GetFusionAuthToken(ctx, FusionTokenRequest{Platform: "web"}); err == nil {
		t.Fatal("web accepted")
	}
	if _, err := c.GetFusionAuthToken(ctx, FusionTokenRequest{Platform: "Android"}); ErrorCode(err) != "isv.INVALID" {
		t.Fatal(err)
	}
	if p, err := c.VerifyWithFusionAuthToken(ctx, "good"); err != nil || p != "13800138000" {
		t.Fatal(p, err)
	}
	if _, err := c.VerifyWithFusionAuthToken(ctx, "bad"); !errors.Is(err, ErrNotPassed) {
		t.Fatal(err)
	}
}

func TestSms(t *testing.T) {
	var sent url.Values
	c := fake(t, func(v url.Values) any {
		switch v.Get("Action") {
		case "SendSmsVerifyCode":
			sent = v
			if v.Get("PhoneNumber") == "1" {
				return map[string]any{"Code": "MOBILE_NUMBER_ILLEGAL"}
			}
			return map[string]any{"Code": "OK", "Model": map[string]string{"BizId": "biz"}}
		case "CheckSmsVerifyCode":
			r := "UNKNOWN"
			if v.Get("VerifyCode") == "123456" {
				r = "PASS"
			}
			return map[string]any{"Code": "OK", "Model": map[string]string{"VerifyResult": r}}
		}
		return nil
	})
	ctx := context.Background()
	biz, err := c.SendSmsVerifyCode(ctx, SmsRequest{Phone: "13800138000", SignName: "S", TemplateCode: "T",
		TemplateParam: map[string]string{"code": "##code##", "min": "5"}})
	if err != nil || biz != "biz" {
		t.Fatal(biz, err)
	}
	if sent.Get("CountryCode") != "86" || sent.Get("CodeLength") != "6" || sent.Get("ValidTime") != "300" ||
		sent.Get("TemplateParam") != `{"code":"##code##","min":"5"}` || sent.Has("SchemeName") {
		t.Fatalf("params %v", sent)
	}
	if _, err := c.SendSmsVerifyCode(ctx, SmsRequest{Phone: "1"}); ErrorCode(err) != "MOBILE_NUMBER_ILLEGAL" {
		t.Fatal(err)
	}
	if ok, err := c.CheckSmsVerifyCode(ctx, "13800138000", "123456", "", ""); err != nil || !ok {
		t.Fatal(ok, err)
	}
	if ok, _ := c.CheckSmsVerifyCode(ctx, "13800138000", "000000", "", ""); ok {
		t.Fatal("wrong code passed")
	}
}
