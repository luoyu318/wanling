package storage

import "io"

type Provider interface {
	Save(filename string, reader io.Reader) (path string, err error)
	Read(path string) (io.ReadCloser, error)
	Delete(path string) error

	// SaveThumbnail 以指定存储名保存缩略图字节。
	//
	// 与 [Save] 区别：缩略图由 handler 用 imaging 包生成后已是最终字节
	// （不需要 storage 再处理格式），故直接按传入的 storageName 落盘。
	// storageName 命名约定为 `{原fileID}_thumb.jpg`，由 handler 拼好传入，
	// storage 层不感知缩略图语义（保持 storage 仅做存取的职责单一）。
	SaveThumbnail(storageName string, data []byte) error
}
