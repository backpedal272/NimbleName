package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const defaultPrompt = "Based on the content of this document, suggest a concise descriptive filename (without extension, no spaces, use underscores). Reply with only the filename."

// RawConfig holds raw string values parsed from config.yaml
type RawConfig struct {
	InputFolder  string
	OutputFolder string
	ModelName    string
	BaseURL      string
	Temperature  float64
	TimeoutSec   int
}

// parseSimpleYAML parses a minimal YAML (flat key: value pairs only)
func parseSimpleYAML(filename string) (*RawConfig, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	config := &RawConfig{}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])

		valueRaw := parts[1]

		// Strip inline comments, then trim whitespace and optional surrounding quotes
		if idx := strings.Index(valueRaw, " #"); idx != -1 {
			valueRaw = valueRaw[:idx]
		}
		valueRaw = strings.TrimSpace(valueRaw)
		if len(valueRaw) >= 2 {
			if valueRaw[0] == '"' && valueRaw[len(valueRaw)-1] == '"' ||
				valueRaw[0] == '\'' && valueRaw[len(valueRaw)-1] == '\'' {
				valueRaw = valueRaw[1 : len(valueRaw)-1]
			}
		}
		value := strings.TrimSpace(valueRaw)

		switch key {
		case "input_folder":
			config.InputFolder = value
		case "output_folder":
			config.OutputFolder = value
		case "model_name":
			config.ModelName = value
		case "base_url":
			config.BaseURL = value
		case "temperature":
			f, _ := strconv.ParseFloat(value, 64)
			config.Temperature = f
		case "timeout_seconds":
			i, _ := strconv.Atoi(value)
			config.TimeoutSec = i
		}
	}

	return config, nil
}

// LoadPrompt reads the prompt template from file
func loadPrompt(filename string) (string, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return "", fmt.Errorf("failed to read prompt: %w", err)
	}
	return string(data), nil
}

// renderPDFToImage uses macOS sips to convert PDF page to PNG for vision model.
// idx is used to avoid temp file collisions when two PDFs share the same base name.
func renderPDFToImage(pdfPath string, tempDir string, idx int) (string, error) {
	outputFile := filepath.Join(tempDir, fmt.Sprintf("%d_%s.png", idx, filepath.Base(pdfPath)))
	cmd := exec.Command("sips", "-s", "format", "png", pdfPath, "--out", outputFile)
	err := cmd.Run()
	if err != nil {
		return "", fmt.Errorf("sips failed for %s: %w", pdfPath, err)
	}
	return outputFile, nil
}

// encodeImageToBase64 reads image and returns Base64 data URL
func encodeImageToBase64(filePath string) (string, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", err
	}
	ext := strings.ToLower(filepath.Ext(filePath))
	mimeType := "image/jpeg"
	if ext == ".png" {
		mimeType = "image/png"
	}
	return fmt.Sprintf("data:%s;base64,%s", mimeType, base64.StdEncoding.EncodeToString(data)), nil
}

// queryLLM sends the request to LM Studio's /chat/completions endpoint
func queryLLM(ctx context.Context, cfg *RawConfig, imgBase64 string, prompt string) (string, error) {
	payload := map[string]interface{}{
		"model": cfg.ModelName,
		"messages": []map[string]interface{}{
			{
				"role": "user",
				"content": []map[string]interface{}{
					{
						"type": "text",
						// /no_think disables Qwen3's reasoning mode so the answer
						// lands in content rather than reasoning_content.
						"text": prompt + "\n/no_think",
					},
					{
						"type": "image_url",
						"image_url": map[string]string{
							"url": imgBase64,
						},
					},
				},
			},
		},
		"temperature": cfg.Temperature,
	}

	jsonBody, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("failed to marshal JSON: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", cfg.BaseURL+"/chat/completions", strings.NewReader(string(jsonBody)))
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: time.Duration(cfg.TimeoutSec) * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("LLM API returned status %d: %s", resp.StatusCode, string(body))
	}

	rawBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %w", err)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(rawBody, &result); err != nil {
		return "", fmt.Errorf("failed to decode JSON response: %w", err)
	}

	choices, ok := result["choices"].([]interface{})
	if !ok || len(choices) == 0 {
		return "", fmt.Errorf("no choices in response")
	}

	msg, ok := choices[0].(map[string]interface{})["message"].(map[string]interface{})
	if !ok {
		return "", fmt.Errorf("invalid message format")
	}

	content, _ := msg["content"].(string)
	content = strings.TrimSpace(content)

	if content == "" {
		// reasoning_content is the model's internal thinking — never a valid filename.
		// If content is still empty here it means max_tokens was too low to let the
		// model finish its reasoning phase and write its answer.
		return "", fmt.Errorf("model returned empty content (finish_reason: %v) — consider raising max_tokens", choices[0].(map[string]interface{})["finish_reason"])
	}

	return content, nil
}

// sanitizeFilename cleans the model's output for safe filesystem use
func sanitizeFilename(name string, ext string) string {
	// Replace invalid chars for macOS/Windows
	re := regexp.MustCompile(`[\\/:*?"<>|]`)
	sanitized := re.ReplaceAllString(name, " ")

	// Normalize spaces and lowercase
	// sanitized = strings.Join(strings.Fields(sanitized), "_")
	// sanitized = strings.ToLower(sanitized)

	// Limit length to stay under 255-char file path limit
	if len(sanitized) > 100 {
		sanitized = sanitized[:100]
	}

	return strings.TrimSuffix(sanitized, ext) + ext
}

// uniqueDestPath returns a collision-free path, appending _2, _3, … as needed.
func uniqueDestPath(dir, name, ext string) string {
	candidate := filepath.Join(dir, name)
	if _, err := os.Stat(candidate); os.IsNotExist(err) {
		return candidate
	}
	base := strings.TrimSuffix(name, ext)
	for i := 2; ; i++ {
		candidate = filepath.Join(dir, fmt.Sprintf("%s_%d%s", base, i, ext))
		if _, err := os.Stat(candidate); os.IsNotExist(err) {
			return candidate
		}
	}
}

// moveFile renames src to dst, falling back to copy+delete across filesystems.
func moveFile(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}

	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(dst)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(dst)
		return err
	}
	return os.Remove(src)
}

func main() {
	fmt.Println("Starting File Renamer (Qwen-VL + sips)")

	cfg, err := parseSimpleYAML("config.yaml")
	if err != nil {
		fmt.Printf("❌ Config error: %v\n", err)
		os.Exit(1)
	}

	if cfg.InputFolder == "" || cfg.OutputFolder == "" {
		fmt.Println("❌ Input/Output folders missing in config.yaml")
		os.Exit(1)
	}

	prompt, err := loadPrompt("prompt.txt")
	if err != nil || strings.TrimSpace(prompt) == "" {
		fmt.Printf("⚠️  Prompt file not found or empty, using default. (%v)\n", err)
		prompt = defaultPrompt
	}

	tempDir, _ := os.MkdirTemp("", "qwen-vl-*")
	defer os.RemoveAll(tempDir)

	// Ensure output directory exists
	if err := os.MkdirAll(cfg.OutputFolder, 0755); err != nil {
		fmt.Printf("❌ Cannot create output dir: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("📁 Input:  %s\n", cfg.InputFolder)
	fmt.Printf("📁 Output: %s\n", cfg.OutputFolder)

	// Collect target files
	var files []string

	err = filepath.Walk(cfg.InputFolder, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			fmt.Fprintf(os.Stderr, "⚠️  Walk error on %s: %v\n", path, err)
			return filepath.SkipDir
		}

		if info.IsDir() {
			return nil
		}

		ext := strings.ToLower(filepath.Ext(info.Name()))
		switch ext {
		case ".pdf", ".jpg", ".jpeg", ".png":
			files = append(files, path)
		}
		return nil
	})

	if err != nil {
		fmt.Printf("❌ Scan failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("✅ Found %d files.\n\n", len(files))

	for i, srcPath := range files {
		baseName := filepath.Base(srcPath)
		fmt.Printf("[%s] Starting...\n", baseName)

		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.TimeoutSec)*time.Second)

		var imageForModel string

		ext := strings.ToLower(filepath.Ext(baseName))
		if ext == ".pdf" {
			fmt.Println("  🔁 Rendering PDF → PNG via sips...")
			converted, err := renderPDFToImage(srcPath, tempDir, i)
			if err != nil {
				fmt.Printf("    ❌ Render failed: %v\n", err)
				cancel()
				continue
			}
			imageForModel = converted
		} else {
			fmt.Println("  🖼️  Using image directly...")
			imageForModel = srcPath
		}

		fmt.Println("  📤 Encoding to Base64...")
		imgBase64, err := encodeImageToBase64(imageForModel)
		if err != nil {
			fmt.Printf("    ❌ Encoding failed: %v\n", err)
			cancel()
			continue
		}

		fmt.Println("  🤖 Calling Qwen-VL...")
		newName, err := queryLLM(ctx, cfg, imgBase64, prompt)
		cancel()
		if err != nil {
			fmt.Printf("    ❌ LLM failed: %v\n", err)
			continue
		}

		if newName == "" {
			fmt.Println("    ⚠️  Empty name from model, skipping...")
			continue
		}

		safeName := sanitizeFilename(newName, ext)
		destPath := uniqueDestPath(cfg.OutputFolder, safeName, ext)

		fmt.Printf("  → Rename to: %s\n", filepath.Base(destPath))
		if err := moveFile(srcPath, destPath); err != nil {
			fmt.Printf("    ❌ Move failed: %v\n", err)
		} else {
			fmt.Println("  ✅ Success!")
		}
	}

	fmt.Println("\n🎉 Done.")
}
