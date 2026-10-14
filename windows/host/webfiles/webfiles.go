// Package webfiles holds the web app (index.html, src/, styles/, assets/) inside the exe
// and unpacks it to a folder that WebView2 serves under a fixed virtual host.
//
// build.sh copies the files into web/ before every build; web/ is not edited by hand.
package webfiles

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

//go:embed all:web
var embedded embed.FS

// readyMarker is written last, so a folder without it was left half-written.
const readyMarker = ".ready"

// Files returns the web app as a file system rooted at index.html.
func Files() fs.FS {
	sub, err := fs.Sub(embedded, "web")
	if err != nil {
		panic(err)
	}
	return sub
}

// Hash identifies one build of the web files: a new exe unpacks into a new folder.
func Hash(fsys fs.FS) (string, error) {
	var names []string
	err := fs.WalkDir(fsys, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			names = append(names, name)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Strings(names)
	h := sha256.New()
	for _, name := range names {
		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			return "", err
		}
		io.WriteString(h, name)
		h.Write([]byte{0})
		h.Write(data)
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))[:16], nil
}

// Unpack writes fsys to base/<hash> (unless that folder is complete already), removes the
// folders of older builds and returns the folder.
func Unpack(fsys fs.FS, base string) (string, error) {
	hash, err := Hash(fsys)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(base, hash)
	if _, err := os.Stat(filepath.Join(dir, readyMarker)); err == nil {
		removeOthers(base, hash)
		return dir, nil
	}
	if err := os.MkdirAll(base, 0o755); err != nil {
		return "", err
	}
	tmp, err := os.MkdirTemp(base, "tmp-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmp)
	if err := writeAll(fsys, tmp); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, readyMarker), []byte(hash), 0o644); err != nil {
		return "", err
	}
	os.RemoveAll(dir)
	if err := os.Rename(tmp, dir); err != nil {
		return "", err
	}
	removeOthers(base, hash)
	return dir, nil
}

func writeAll(fsys fs.FS, dst string) error {
	return fs.WalkDir(fsys, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if name == "." {
			return nil
		}
		if strings.Contains(name, "..") || path.IsAbs(name) {
			return errors.New("webfiles: bad path " + name)
		}
		target := filepath.Join(dst, filepath.FromSlash(name))
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
}

// removeOthers deletes the folders of other builds. Failures are harmless (a file in use is
// cleaned up on a later start).
func removeOthers(base, keep string) {
	entries, err := os.ReadDir(base)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() && e.Name() != keep {
			os.RemoveAll(filepath.Join(base, e.Name()))
		}
	}
}
