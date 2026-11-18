package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func findSeed(name string) string {
	candidates := []string{
		filepath.Join("seeds", name),
		filepath.Join(os.Getenv("HOME"), "src/plans/seeds", name),
		filepath.Join("..", "seeds", name),
		filepath.Join("/home/nyc/src/plans/seeds", name),
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return filepath.Join("seeds", name)
}

func main() {
	fmt.Println("=== [TP-PYKINOS-ARENA-001B Task Runner (Go)] ===")

	// 1. Copy HiddenClass.hs
	srcHC := findSeed("TP-PYKINOS-ARENA-001B-HiddenClass.hs")
	dstHC := "packages/pykinos-core/src/Pykinos/Schema/HiddenClass.hs"
	if err := copyFile(srcHC, dstHC); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcHC, dstHC, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstHC)

	// 2. Update pykinos-core.cabal
	cabalPath := "packages/pykinos-core/pykinos-core.cabal"
	cabalBytes, err := os.ReadFile(cabalPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", cabalPath, err)
		os.Exit(1)
	}
	cabalStr := string(cabalBytes)
	if !strings.Contains(cabalStr, "Pykinos.Schema.HiddenClass") {
		cabalStr = strings.Replace(cabalStr, "        Pykinos.Mutable.SwissTable\n", "        Pykinos.Mutable.SwissTable\n        Pykinos.Schema.HiddenClass\n", 1)
		if !strings.Contains(cabalStr, "text >=") {
			cabalStr = strings.Replace(cabalStr, "        containers >= 0.6\n", "        containers >= 0.6,\n        text >= 2.0\n", 1)
			cabalStr = strings.Replace(cabalStr, "        containers >= 0.6\n", "        containers >= 0.6,\n        text >= 2.0\n", 1)
		}
		if err := os.WriteFile(cabalPath, []byte(cabalStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write %s: %v\n", cabalPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Updated %s (exposed Pykinos.Schema.HiddenClass)\n", cabalPath)
	}

	// 3. Update test/Spec.hs with HiddenClass tests
	testSpecPath := "packages/pykinos-core/test/Spec.hs"
	testBytes, err := os.ReadFile(testSpecPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", testSpecPath, err)
		os.Exit(1)
	}
	testStr := string(testBytes)
	if !strings.Contains(testStr, "HiddenClass & Lexicon Tests") {
		if !strings.Contains(testStr, "import Pykinos.Schema.HiddenClass") {
			testStr = strings.Replace(testStr, "import Pykinos.Mutable.SwissTable\n", "import Pykinos.Mutable.SwissTable\nimport Pykinos.Schema.HiddenClass\nimport qualified Data.Text as T\n", 1)
		}
		testSnippet := `
  -- 8. HiddenClass & Lexicon Tests
  let lex = buildLexicon [T.pack "beta", T.pack "alpha", T.pack "gamma"]
  assertBool "alpha fid is 0" (lookupFieldId lex (T.pack "alpha") == Just (FieldId 0))
  assertBool "beta fid is 1" (lookupFieldId lex (T.pack "beta") == Just (FieldId 1))
  assertBool "gamma fid is 2" (lookupFieldId lex (T.pack "gamma") == Just (FieldId 2))
`
		target := "putStrLn \"=== [pykinos-core-test] ALL 30 PROPERTIES AND UNIT CHECKS PASSED ===\""
		replacement := testSnippet + "\n  putStrLn \"=== [pykinos-core-test] ALL 33 PROPERTIES AND UNIT CHECKS PASSED ===\""
		testStr = strings.Replace(testStr, target, replacement, 1)
		if err := os.WriteFile(testSpecPath, []byte(testStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write %s: %v\n", testSpecPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Updated %s (added HiddenClass tests)\n", testSpecPath)
	}

	fmt.Println("=== [TP-PYKINOS-ARENA-001B Task Runner Finished] ===")
}
