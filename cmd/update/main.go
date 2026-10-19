package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type SourceEntry struct {
	Version string `json:"version"`
	BuildID string `json:"buildId,omitempty"`
	Hash    string `json:"hash"`
}

type Sources struct {
	CLI SourceEntry `json:"cli"`
	Hub SourceEntry `json:"hub"`
	ACP SourceEntry `json:"acp"`
}

type UpstreamInfo struct {
	Version     string
	BuildID     string
	DownloadURL string
}

var (
	httpClient = &http.Client{Timeout: 30 * time.Second}
	buildIDRe  = regexp.MustCompile(`[0-9]+\.[0-9]+\.[0-9]+-([0-9]+)`)
)

func findSourcesPath() (string, error) {
	candidates := []string{
		"sources.json",
		"../sources.json",
		"../../sources.json",
	}
	for _, c := range candidates {
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
			return filepath.Abs(c)
		}
	}
	// Try git rev-parse --show-toplevel
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err == nil {
		gitRoot := strings.TrimSpace(string(out))
		p := filepath.Join(gitRoot, "sources.json")
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p, nil
		}
	}
	return "", fmt.Errorf("could not locate sources.json")
}

func fetchLatestCLI(ctx context.Context) (*UpstreamInfo, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json", nil)
	if err != nil {
		return nil, err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d fetching CLI manifest", resp.StatusCode)
	}

	var data struct {
		Version string `json:"version"`
		URL     string `json:"url"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}

	matches := buildIDRe.FindStringSubmatch(data.URL)
	if len(matches) < 2 {
		return nil, fmt.Errorf("could not extract buildId from CLI URL: %s", data.URL)
	}

	return &UpstreamInfo{
		Version:     data.Version,
		BuildID:     matches[1],
		DownloadURL: data.URL,
	}, nil
}

func fetchLatestHub(ctx context.Context) (*UpstreamInfo, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-x64-linux.yml", nil)
	if err != nil {
		return nil, err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d fetching Hub manifest", resp.StatusCode)
	}

	var version, buildID string
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "version:") {
			version = strings.TrimSpace(strings.TrimPrefix(line, "version:"))
		}
		if buildID == "" {
			if matches := buildIDRe.FindStringSubmatch(line); len(matches) >= 2 {
				buildID = matches[1]
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if version == "" || buildID == "" {
		return nil, fmt.Errorf("could not parse Hub version/buildID from manifest")
	}

	url := fmt.Sprintf("https://storage.googleapis.com/antigravity-public/antigravity-hub/%s-%s/linux-x64/Antigravity.tar.gz", version, buildID)
	return &UpstreamInfo{
		Version:     version,
		BuildID:     buildID,
		DownloadURL: url,
	}, nil
}

func fetchLatestACP(ctx context.Context) (*UpstreamInfo, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json", nil)
	if err != nil {
		return nil, err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d fetching ACP registry", resp.StatusCode)
	}

	var registry struct {
		Agents []struct {
			ID           string `json:"id"`
			Version      string `json:"version"`
			Distribution struct {
				Binary map[string]struct {
					Archive string `json:"archive"`
				} `json:"binary"`
			} `json:"distribution"`
		} `json:"agents"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&registry); err != nil {
		return nil, err
	}

	for _, agent := range registry.Agents {
		if agent.ID == "antigravity-acp" {
			target, ok := agent.Distribution.Binary["linux-x86_64"]
			if !ok || target.Archive == "" {
				return nil, fmt.Errorf("antigravity-acp has no linux-x86_64 binary entry")
			}
			return &UpstreamInfo{
				Version:     agent.Version,
				DownloadURL: target.Archive,
			}, nil
		}
	}

	return nil, fmt.Errorf("antigravity-acp entry not found in ACP registry")
}

func prefetchHash(ctx context.Context, url string) (string, error) {
	// Try `nix store prefetch-file --json <url>` if available to take advantage of Nix store caching
	if nixPath, err := exec.LookPath("nix"); err == nil {
		cmd := exec.CommandContext(ctx, nixPath, "store", "prefetch-file", url, "--json")
		var out bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err == nil {
			var result struct {
				Hash string `json:"hash"`
			}
			if err := json.Unmarshal(out.Bytes(), &result); err == nil && result.Hash != "" {
				return result.Hash, nil
			}
		}
	}

	// Fallback to streaming HTTP download and calculating SRI sha256
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return "", err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d while downloading %s", resp.StatusCode, url)
	}

	h := sha256.New()
	if _, err := io.Copy(h, resp.Body); err != nil {
		return "", err
	}
	sriHash := "sha256-" + base64.StdEncoding.EncodeToString(h.Sum(nil))
	return sriHash, nil
}

func main() {
	checkOnly := flag.Bool("check", false, "Check only; exit 0 if up to date, 1 if updates available")
	flag.Parse()

	sourcesPath, err := findSourcesPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	sourcesBytes, err := os.ReadFile(sourcesPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading %s: %v\n", sourcesPath, err)
		os.Exit(1)
	}

	var current Sources
	if err := json.Unmarshal(sourcesBytes, &current); err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing %s: %v\n", sourcesPath, err)
		os.Exit(1)
	}

	fmt.Println("==> Reading current versions from sources.json...")
	fmt.Printf("    Current CLI: %s (%s)\n", current.CLI.Version, current.CLI.BuildID)
	fmt.Printf("    Current Hub: %s (%s)\n", current.Hub.Version, current.Hub.BuildID)
	fmt.Printf("    Current ACP: %s\n", current.ACP.Version)

	fmt.Println("==> Checking upstream release manifests...")
	ctx := context.Background()

	var (
		wg          sync.WaitGroup
		latestCLI   *UpstreamInfo
		latestHub   *UpstreamInfo
		latestACP   *UpstreamInfo
		cliErr, hubErr, acpErr error
	)

	wg.Add(3)
	go func() {
		defer wg.Done()
		latestCLI, cliErr = fetchLatestCLI(ctx)
	}()
	go func() {
		defer wg.Done()
		latestHub, hubErr = fetchLatestHub(ctx)
	}()
	go func() {
		defer wg.Done()
		latestACP, acpErr = fetchLatestACP(ctx)
	}()
	wg.Wait()

	if cliErr != nil {
		fmt.Fprintf(os.Stderr, "Error fetching CLI upstream: %v\n", cliErr)
		os.Exit(1)
	}
	if hubErr != nil {
		fmt.Fprintf(os.Stderr, "Error fetching Hub upstream: %v\n", hubErr)
		os.Exit(1)
	}
	if acpErr != nil {
		fmt.Fprintf(os.Stderr, "Error fetching ACP upstream: %v\n", acpErr)
		os.Exit(1)
	}

	fmt.Printf("    Upstream CLI: %s (%s)\n", latestCLI.Version, latestCLI.BuildID)
	fmt.Printf("    Upstream Hub: %s (%s)\n", latestHub.Version, latestHub.BuildID)
	fmt.Printf("    Upstream ACP: %s\n", latestACP.Version)

	cliChanged := current.CLI.Version != latestCLI.Version || current.CLI.BuildID != latestCLI.BuildID || current.CLI.Hash == ""
	hubChanged := current.Hub.Version != latestHub.Version || current.Hub.BuildID != latestHub.BuildID || current.Hub.Hash == ""
	acpChanged := current.ACP.Version != latestACP.Version || current.ACP.Hash == ""

	if !cliChanged && !hubChanged && !acpChanged {
		fmt.Println("==> Everything is already up to date. No downloads needed.")
		os.Exit(0)
	}

	if *checkOnly {
		fmt.Println("==> Updates are available.")
		os.Exit(1)
	}

	updated := current

	if cliChanged {
		fmt.Printf("==> Fetching new hash for Antigravity CLI (%s -> %s)...\n", current.CLI.Version, latestCLI.Version)
		hash, err := prefetchHash(ctx, latestCLI.DownloadURL)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to prefetch CLI: %v\n", err)
			os.Exit(1)
		}
		updated.CLI = SourceEntry{
			Version: latestCLI.Version,
			BuildID: latestCLI.BuildID,
			Hash:    hash,
		}
		fmt.Printf("    New CLI hash: %s\n", hash)
	}

	if hubChanged {
		fmt.Printf("==> Fetching new hash for Antigravity Hub (%s -> %s)...\n", current.Hub.Version, latestHub.Version)
		hash, err := prefetchHash(ctx, latestHub.DownloadURL)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to prefetch Hub: %v\n", err)
			os.Exit(1)
		}
		updated.Hub = SourceEntry{
			Version: latestHub.Version,
			BuildID: latestHub.BuildID,
			Hash:    hash,
		}
		fmt.Printf("    New Hub hash: %s\n", hash)
	}

	if acpChanged {
		fmt.Printf("==> Fetching new hash for Antigravity ACP (%s -> %s)...\n", current.ACP.Version, latestACP.Version)
		hash, err := prefetchHash(ctx, latestACP.DownloadURL)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to prefetch ACP: %v\n", err)
			os.Exit(1)
		}
		updated.ACP = SourceEntry{
			Version: latestACP.Version,
			Hash:    hash,
		}
		fmt.Printf("    New ACP hash: %s\n", hash)
	}

	outBytes, err := json.MarshalIndent(updated, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to encode sources.json: %v\n", err)
		os.Exit(1)
	}
	outBytes = append(outBytes, '\n')

	if err := os.WriteFile(sourcesPath, outBytes, 0644); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write %s: %v\n", sourcesPath, err)
		os.Exit(1)
	}

	fmt.Println("==> Successfully updated sources.json:")
	fmt.Print(string(outBytes))
}
