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
	fmt.Println("=== [TP-PYKINOS-ARENA-001A Task Runner (Go)] ===")

	// 1. Copy SwissTable.hs
	srcSwiss := findSeed("TP-PYKINOS-ARENA-001A-SwissTable.hs")
	dstSwiss := "packages/pykinos-core/src/Pykinos/Mutable/SwissTable.hs"
	if err := copyFile(srcSwiss, dstSwiss); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcSwiss, dstSwiss, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstSwiss)

	// 2. Update pykinos-core.cabal
	cabalPath := "packages/pykinos-core/pykinos-core.cabal"
	cabalBytes, err := os.ReadFile(cabalPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", cabalPath, err)
		os.Exit(1)
	}
	cabalStr := string(cabalBytes)
	if !strings.Contains(cabalStr, "Pykinos.Mutable.SwissTable") {
		cabalStr = strings.Replace(cabalStr, "        Pykinos.Tree.FAST\n", "        Pykinos.Tree.FAST\n        Pykinos.Mutable.SwissTable\n", 1)
		if err := os.WriteFile(cabalPath, []byte(cabalStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write %s: %v\n", cabalPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Updated %s (exposed Pykinos.Mutable.SwissTable)\n", cabalPath)
	}

	// 3. Update test/Spec.hs with SwissTable tests
	testSpecPath := "packages/pykinos-core/test/Spec.hs"
	testBytes, err := os.ReadFile(testSpecPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", testSpecPath, err)
		os.Exit(1)
	}
	testStr := string(testBytes)
	if !strings.Contains(testStr, "SwissTable128 Tests") {
		if !strings.Contains(testStr, "import Pykinos.Mutable.SwissTable") {
			testStr = strings.Replace(testStr, "import Pykinos.IntMap.ART\n", "import Pykinos.IntMap.ART\nimport Pykinos.Mutable.SwissTable\nimport Control.Monad.ST (runST)\n", 1)
		}
		testSnippet := `
  -- 7. SwissTable128 Tests (SWAR 128-bit hash-consing)
  let (id0, id1, id0_again) = runST $ do
        tbl <- newSwissTable128 32
        let (kLo1, kHi1) = packNfNode128 1 0 10 20 30
            (kLo2, kHi2) = packNfNode128 2 0 40 50 60
        i0 <- lookupOrInsert128 tbl kLo1 kHi1
        i1 <- lookupOrInsert128 tbl kLo2 kHi2
        i0' <- lookupOrInsert128 tbl kLo1 kHi1
        pure (i0, i1, i0')
  assertBool "id0 is 0" (id0 == 0)
  assertBool "id1 is 1" (id1 == 1)
  assertBool "id0_again matches id0" (id0_again == 0)
`
		target := "putStrLn \"=== [pykinos-core-test] ALL 27 PROPERTIES AND UNIT CHECKS PASSED ===\""
		replacement := testSnippet + "\n  putStrLn \"=== [pykinos-core-test] ALL 30 PROPERTIES AND UNIT CHECKS PASSED ===\""
		testStr = strings.Replace(testStr, target, replacement, 1)
		if err := os.WriteFile(testSpecPath, []byte(testStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write %s: %v\n", testSpecPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Updated %s (added SwissTable tests)\n", testSpecPath)
	}

	fmt.Println("=== [TP-PYKINOS-ARENA-001A Task Runner Finished] ===")
}
