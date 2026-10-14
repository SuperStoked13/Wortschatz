package webfiles

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

func TestEmbeddedAppIsComplete(t *testing.T) {
	files := Files()
	for _, name := range []string{"index.html", "src/main.js", "src/router.js", "assets/icon.svg", "styles/tokens.css"} {
		if _, err := fs.Stat(files, name); err != nil {
			t.Errorf("%s is missing from the embedded app: %v", name, err)
		}
	}
	// Every stylesheet and the entry script that index.html links must be embedded.
	index, err := fs.ReadFile(files, "index.html")
	if err != nil {
		t.Fatal(err)
	}
	for _, part := range strings.Split(string(index), `"`) {
		if (strings.HasPrefix(part, "styles/") || strings.HasPrefix(part, "src/") || strings.HasPrefix(part, "assets/")) && !strings.ContainsAny(part, " <>") {
			if _, err := fs.Stat(files, part); err != nil {
				t.Errorf("index.html links %s, which is not embedded", part)
			}
		}
	}
	// Nothing from the Mac folders or the tests.
	fs.WalkDir(files, ".", func(name string, d fs.DirEntry, err error) error {
		if strings.HasSuffix(name, ".DS_Store") || strings.HasPrefix(name, "tests") || strings.HasPrefix(name, "mac") {
			t.Errorf("unexpected file in the embedded app: %s", name)
		}
		return nil
	})
}

func TestUnpackWritesOnceAndReplacesOldBuilds(t *testing.T) {
	base := t.TempDir()
	v1 := fstest.MapFS{
		"index.html":  {Data: []byte("<!doctype html>v1")},
		"src/main.js": {Data: []byte("console.log(1)")},
	}
	dir1, err := Unpack(v1, base)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dir1, "src", "main.js"))
	if err != nil || string(got) != "console.log(1)" {
		t.Fatalf("main.js = %q, %v", got, err)
	}

	// A second start with the same files keeps the folder (and its modification time).
	stamp := filepath.Join(dir1, "index.html")
	before, _ := os.Stat(stamp)
	again, err := Unpack(v1, base)
	if err != nil || again != dir1 {
		t.Fatalf("second unpack: %q, %v", again, err)
	}
	after, _ := os.Stat(stamp)
	if !before.ModTime().Equal(after.ModTime()) {
		t.Error("an unchanged build was written again")
	}

	// A new build gets a new folder and the old one is removed.
	v2 := fstest.MapFS{"index.html": {Data: []byte("<!doctype html>v2")}}
	dir2, err := Unpack(v2, base)
	if err != nil {
		t.Fatal(err)
	}
	if dir2 == dir1 {
		t.Fatal("a changed build reused the old folder")
	}
	if _, err := os.Stat(dir1); !os.IsNotExist(err) {
		t.Error("the old build's folder is still there")
	}
	entries, _ := os.ReadDir(base)
	if len(entries) != 1 {
		t.Errorf("expected one folder in %s, found %d", base, len(entries))
	}
}

func TestUnpackRepairsAHalfWrittenFolder(t *testing.T) {
	base := t.TempDir()
	files := fstest.MapFS{"index.html": {Data: []byte("ok")}}
	hash, err := Hash(files)
	if err != nil {
		t.Fatal(err)
	}
	// A folder without the ready marker, e.g. after a crash during the first start.
	broken := filepath.Join(base, hash)
	os.MkdirAll(broken, 0o755)
	os.WriteFile(filepath.Join(broken, "index.html"), []byte("trunc"), 0o644)

	dir, err := Unpack(files, base)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "index.html"))
	if string(got) != "ok" {
		t.Errorf("index.html = %q, want the complete file", got)
	}
}
