package miniprogram

import "testing"

func TestSignVerify_RoundTrip(t *testing.T) {
	priv, pub, err := GenerateKeypair()
	if err != nil {
		t.Fatalf("GenerateKeypair: %v", err)
	}
	data := []byte("hello-demo-zip-bytes")
	sig, err := Sign(priv, data)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	if err := Verify(pub, data, sig); err != nil {
		t.Fatalf("Verify 正确签名应通过: %v", err)
	}
	tampered := append([]byte{}, data...)
	tampered[0] ^= 0xFF
	if err := Verify(pub, tampered, sig); err == nil {
		t.Errorf("篡改数据验签应失败")
	}
	if err := Verify(pub, data, sig[:len(sig)-2]+"00"); err == nil {
		t.Errorf("坏签名应失败")
	}
	if len(pub) != 64 { // ed25519 公钥 32 字节 = hex 64
		t.Errorf("公钥 hex 长度应 64,实际 %d", len(pub))
	}
	if len(sig) != 128 { // ed25519 签名 64 字节 = hex 128
		t.Errorf("签名 hex 长度应 128,实际 %d", len(sig))
	}
}
