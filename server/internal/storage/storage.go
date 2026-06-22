package storage

import "io"

type Provider interface {
	Save(filename string, reader io.Reader) (path string, err error)
	Read(path string) (io.ReadCloser, error)
	Delete(path string) error
}
