package imaging

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"strings"
	"testing"
)

// encodePNG 把 image.Image 编码为 PNG bytes（测试辅助）。
func encodePNG(t *testing.T, img image.Image) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png encode: %v", err)
	}
	return buf.Bytes()
}

// decodeJPEGDims 解码 JPEG 拿尺寸（测试辅助）。
func decodeJPEGDims(t *testing.T, data []byte) (w, h int) {
	t.Helper()
	img, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("jpeg decode: %v", err)
	}
	b := img.Bounds()
	return b.Dx(), b.Dy()
}

// TestGenerateThumbnail_ScaleDown 横图：长边超 600 → 等比缩到长边 600。
func TestGenerateThumbnail_ScaleDown(t *testing.T) {
	// 1200x800 横图
	src := image.NewRGBA(image.Rect(0, 0, 1200, 800))
	thumb, w, h, err := GenerateThumbnail(bytes.NewReader(encodePNG(t, src)))
	if err != nil {
		t.Fatalf("GenerateThumbnail: %v", err)
	}

	if w != 1200 || h != 800 {
		t.Errorf("原图尺寸 = (%d,%d), want (1200,800)", w, h)
	}
	tw, th := decodeJPEGDims(t, thumb)
	// 长边应 = 600，短边等比 = 400
	if tw != 600 || th != 400 {
		t.Errorf("缩略图尺寸 = (%d,%d), want (600,400)", tw, th)
	}

	// 缩略图应为 JPEG（magic bytes FF D8 FF）
	if !bytes.HasPrefix(thumb, []byte{0xFF, 0xD8, 0xFF}) {
		t.Errorf("缩略图非 JPEG 格式, 前缀字节: % x", thumb[:3])
	}
}

// TestGenerateThumbnail_ScaleDownPortrait 竖图：长边是高 → 缩到高 600。
func TestGenerateThumbnail_ScaleDownPortrait(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 800, 1200))
	thumb, _, _, err := GenerateThumbnail(bytes.NewReader(encodePNG(t, src)))
	if err != nil {
		t.Fatalf("GenerateThumbnail: %v", err)
	}
	tw, th := decodeJPEGDims(t, thumb)
	if tw != 400 || th != 600 {
		t.Errorf("竖图缩略图尺寸 = (%d,%d), want (400,600)", tw, th)
	}
}

// TestGenerateThumbnail_NoUpscale 原图长边已 ≤ 600 → 不放大，保持原尺寸。
func TestGenerateThumbnail_NoUpscale(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 300, 200))
	thumb, w, h, err := GenerateThumbnail(bytes.NewReader(encodePNG(t, src)))
	if err != nil {
		t.Fatalf("GenerateThumbnail: %v", err)
	}
	if w != 300 || h != 200 {
		t.Errorf("原图尺寸 = (%d,%d), want (300,200)", w, h)
	}
	tw, th := decodeJPEGDims(t, thumb)
	if tw != 300 || th != 200 {
		t.Errorf("小图缩略图尺寸 = (%d,%d), want (300,200) 不放大", tw, th)
	}
}

// TestGenerateThumbnail_TransparencyWhiteBg 透明 PNG（带 alpha）→ 缩略图
// 在白底上合成，透明区不应变黑。
//
// 构造一张上半透明黑、下半完全透明的图，缩略图后透明区应是白色而非黑色。
func TestGenerateThumbnail_TransparencyWhiteBg(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 100, 100))
	// 上半：不透明黑
	for y := 0; y < 50; y++ {
		for x := 0; x < 100; x++ {
			src.Set(x, y, color.RGBA{R: 0, G: 0, B: 0, A: 255})
		}
	}
	// 下半：完全透明
	for y := 50; y < 100; y++ {
		for x := 0; x < 100; x++ {
			src.Set(x, y, color.RGBA{R: 0, G: 0, B: 0, A: 0})
		}
	}
	thumb, _, _, err := GenerateThumbnail(bytes.NewReader(encodePNG(t, src)))
	if err != nil {
		t.Fatalf("GenerateThumbnail: %v", err)
	}
	decoded, err := jpeg.Decode(bytes.NewReader(thumb))
	if err != nil {
		t.Fatalf("jpeg decode: %v", err)
	}
	// 透明区（下半）合成后应是白色（255,255,255），不是黑色（0,0,0）
	r, g, b, _ := decoded.At(50, 75).RGBA()
	if r < 60000 || g < 60000 || b < 60000 {
		t.Errorf("透明区未填白底: rgba=(%d,%d,%d), 期望接近白色 (65535,65535,65535)", r, g, b)
	}
	// 不透明黑区（上半）应仍是黑色
	r2, g2, b2, _ := decoded.At(50, 25).RGBA()
	if r2 > 5000 || g2 > 5000 || b2 > 5000 {
		t.Errorf("不透明黑区变色: rgba=(%d,%d,%d), 期望接近黑色 (0,0,0)", r2, g2, b2)
	}
}

// TestGenerateThumbnail_NonImage 非图片内容 → 返回 error（上游据此跳过）。
func TestGenerateThumbnail_NonImage(t *testing.T) {
	_, _, _, err := GenerateThumbnail(bytes.NewReader([]byte("not an image at all")))
	if err == nil {
		t.Fatal("非图片应返回 error，got nil")
	}
	if !strings.Contains(err.Error(), "解码失败") {
		t.Errorf("error 应说明解码失败，got: %v", err)
	}
}

// TestScaleSize 纯函数：等比缩放计算（含不放大、边界 1px）。
func TestScaleSize(t *testing.T) {
	cases := []struct {
		name                              string
		srcW, srcH, maxEdge, wantW, wantH int
	}{
		{"横图缩放", 1200, 800, 600, 600, 400},
		{"竖图缩放", 800, 1200, 600, 400, 600},
		{"方形缩放", 1000, 1000, 600, 600, 600},
		{"不放大-小图", 300, 200, 600, 300, 200},
		{"不放大-刚好", 600, 600, 600, 600, 600},
		{"边界-极小输入", 1, 1, 600, 1, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotW, gotH := scaleSize(tc.srcW, tc.srcH, tc.maxEdge)
			if gotW != tc.wantW || gotH != tc.wantH {
				t.Errorf("scaleSize(%d,%d,%d) = (%d,%d), want (%d,%d)",
					tc.srcW, tc.srcH, tc.maxEdge, gotW, gotH, tc.wantW, tc.wantH)
			}
		})
	}
}
