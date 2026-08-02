package handler

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
	"unicode"
)

// validatePasswordStrength 校验密码强度:≥1 字母 + ≥1 数字 + ≥1 特殊字符，且不在常见弱密码黑名单中。
// 长度校验由 binding:"min=8,max=64" 兜底,本函数只校验字符组成。
var (
	pwHasLetter = regexp.MustCompile(`[a-zA-Z]`)
	pwHasDigit  = regexp.MustCompile(`[0-9]`)
)

// commonPasswords 常见弱密码黑名单（小写比较）
var commonPasswords = map[string]bool{
	"password": true, "12345678": true, "123456789": true, "1234567890": true,
	"qwerty123": true, "abc12345": true, "password1": true, "iloveyou1": true,
	"admin123": true, "welcome1": true, "monkey123": true, "dragon123": true,
	"letmein1": true, "sunshine1": true, "princess1": true, "football1": true,
	"passw0rd": true, "p@ssw0rd": true, "changeme1": true, "master123": true,
}

func validatePasswordStrength(pw string) error {
	if !pwHasLetter.MatchString(pw) {
		return errors.New("密码必须包含至少一个字母")
	}
	if !pwHasDigit.MatchString(pw) {
		return errors.New("密码必须包含至少一个数字")
	}
	hasSpecial := false
	for _, r := range pw {
		if unicode.IsPunct(r) || unicode.IsSymbol(r) {
			hasSpecial = true
			break
		}
	}
	if !hasSpecial {
		return errors.New("密码必须包含至少一个特殊字符")
	}
	if commonPasswords[strings.ToLower(pw)] {
		return errors.New("密码过于常见，请更换")
	}
	return nil
}

// validateAvatarURL 校验头像 URL：
//   - 空串放行（支持清空 / 不更新语义）
//   - 同源相对路径放行（path 以 / 开头，如 /api/files/xxx）
//   - 否则必须 http/https schema
//   - 长度上限 256（与 binding:"max=256" 一致）
//
// 群头像 / user 头像 / agent 头像统一形态：客户端上传后 server 返 /api/files/:id
// 相对路径，client 直接落库。同源相对路径无 javascript:/data: 等 XSS 风险。
func validateAvatarURL(s string) error {
	if s == "" {
		return nil
	}
	if len(s) > 256 {
		return errors.New("avatar_url 长度超过 256")
	}
	u, err := url.Parse(s)
	if err != nil {
		return errors.New("avatar_url 格式错误")
	}
	// 同源相对路径放行（path 以 / 开头，无 scheme）
	if u.Scheme == "" && strings.HasPrefix(s, "/") {
		return nil
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return errors.New("avatar_url 必须 http/https 协议或同源相对路径")
	}
	return nil
}
