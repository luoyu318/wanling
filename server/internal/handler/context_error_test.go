package handler

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

func TestIsContextError(t *testing.T) {
	if !IsContextError(context.DeadlineExceeded) {
		t.Error("DeadlineExceeded 应被识别")
	}
	if !IsContextError(context.Canceled) {
		t.Error("Canceled 应被识别")
	}
	if IsContextError(errors.New("other error")) {
		t.Error("普通错误不应被识别")
	}
	// wrap 的 ctx 错误也应被识别(errors.Is 透传)
	if !IsContextError(fmt.Errorf("wrap: %w", context.DeadlineExceeded)) {
		t.Error("wrap 的 ctx 错误应被识别")
	}
}
