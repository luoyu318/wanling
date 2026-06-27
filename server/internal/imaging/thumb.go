// Package imaging 提供图片缩略图生成能力。
//
// 上传图片时同步生成 600px 长边缩略图，供消息列表 / 气泡 / markdown 内嵌图
// 加载（体积远小于原图，解码快，内存占用低）。全屏画廊仍用原图。
package imaging

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	_ "image/gif" // 注册 gif 解码（import 副作用）
	"image/jpeg"
	_ "image/png" // 注册 png 解码
	"io"
	"math"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp" // 注册 webp 解码（输入可能是 webp）
)

// ThumbnailMaxEdge 缩略图长边像素上限。
//
// 取值依据：消息气泡显示宽 200，×3（覆盖高 DPR 屏幕）= 600。再大浪费流量与
// 内存，再小在高分屏上模糊。画廊全屏看大图走原图，不受此限制。
const ThumbnailMaxEdge = 600

// JPEGQuality 缩略图 JPEG 编码质量。
//
// 85 在肉眼几乎无差异与体积之间取平衡（比 95 小约 40%）。聊天缩略图场景
// 足够，主流 IM 同档。
const JPEGQuality = 85

// GenerateThumbnail 从 reader 读取原图，按长边等比缩放到 [ThumbnailMaxEdge]
// 以内，编码为 JPEG 返回。
//
// 返回值：
//   - thumb：缩略图字节（JPEG）
//   - srcW, srcH：原图像素尺寸（供调用方写库 files.width/height）
//
// 处理细节：
//   - 非 jpeg/png/webp/gif 解码失败 → 返回 error，调用方应跳过缩略图（fail-soft）
//   - 原图长边已 ≤ ThumbnailMaxEdge → 仍重编码为 JPEG（统一格式 + 压缩体积），
//     但保持原尺寸（不放大）
//   - 透明通道（PNG/WebP 带 alpha）→ JPEG 不支持透明，先在白底上合成，
//     避免透明区被渲染成黑色
//
// reader 只读一次（内部全量读到 bytes 后操作），调用方无需关心 Seek。
func GenerateThumbnail(reader io.Reader) (thumb []byte, srcW, srcH int, err error) {
	// 1. 全量读取（多次解码需要重置 reader，读成 bytes 最简单可靠）
	srcBytes, err := io.ReadAll(reader)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("读取原图失败: %w", err)
	}

	// 2. 解码。image.Decode 按 content 自动选已注册的 decoder
	//    （jpeg/png/gif/webp 均已 import 副作用注册）
	srcImg, _, err := image.Decode(bytes.NewReader(srcBytes))
	if err != nil {
		return nil, 0, 0, fmt.Errorf("原图解码失败（可能非图片或格式不支持）: %w", err)
	}

	srcBounds := srcImg.Bounds()
	srcW = srcBounds.Dx()
	srcH = srcBounds.Dy()

	// 3. 计算缩放后尺寸：长边不超过 ThumbnailMaxEdge，等比缩放，不放大
	dstW, dstH := scaleSize(srcW, srcH, ThumbnailMaxEdge)

	// 4. 缩放：Catmull-Rom 高质量插值（缩略图质量优于默认 nearest/linear，
	//    主流图片库缩略图档同款）。draw.BiLinear 更快但缩放后略糊。
	var dst *image.RGBA
	if dstW == srcW && dstH == srcH {
		// 原图已够小，无需缩放，直接用原图尺寸重编码
		dst = image.NewRGBA(image.Rect(0, 0, srcW, srcH))
	} else {
		dst = image.NewRGBA(image.Rect(0, 0, dstW, dstH))
	}

	// 先填白底（防透明图合成到透明 RGBA 上，JPEG 编码后透明区变黑）
	draw.Draw(dst, dst.Bounds(), &image.Uniform{C: color.White}, image.Point{}, draw.Src)
	// 原图按等比缩放画到白底上（draw.Over 保留 alpha 合成）
	draw.CatmullRom.Scale(dst, dst.Bounds(), srcImg, srcBounds, draw.Over, nil)

	// 5. JPEG 编码
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: JPEGQuality}); err != nil {
		return nil, 0, 0, fmt.Errorf("缩略图编码失败: %w", err)
	}

	return buf.Bytes(), srcW, srcH, nil
}

// scaleSize 按长边上限等比计算目标尺寸。原图长边已 ≤ maxEdge 时返回原尺寸（不放大）。
func scaleSize(srcW, srcH, maxEdge int) (dstW, dstH int) {
	longer := srcW
	if srcH > srcW {
		longer = srcH
	}
	if longer <= maxEdge {
		return srcW, srcH
	}
	ratio := float64(maxEdge) / float64(longer)
	dstW = int(math.Round(float64(srcW) * ratio))
	dstH = int(math.Round(float64(srcH) * ratio))
	// 防御：缩放后至少 1px
	if dstW < 1 {
		dstW = 1
	}
	if dstH < 1 {
		dstH = 1
	}
	return dstW, dstH
}
